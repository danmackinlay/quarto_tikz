--[[
tikz.lua - A Lua filter to process TikZ code blocks and generate figures.

Based on the style of 'quarto_diagram/diagram.lua', adapted for TikZ diagrams.
]]

PANDOC_VERSION:must_be_at_least '3.0'

local pandoc = require 'pandoc'
local system = require 'pandoc.system'
local utils  = require 'pandoc.utils'

local stringify = utils.stringify
local with_temporary_directory = system.with_temporary_directory
local with_working_directory = system.with_working_directory

-- Functions to read and write files
local function read_file (filepath)
  local fh = io.open(filepath, 'rb')
  if not fh then return nil end
  local contents = fh:read('a')
  fh:close()
  return contents
end

local function write_file (filepath, content)
  -- Refuse a nil payload rather than letting `fh:write` raise. Writing
  -- nothing is always the wrong thing to do and the traceback it produced
  -- aborted the whole render (#30).
  if content == nil then return false end
  local fh = io.open(filepath, 'wb')
  if not fh then return false end
  fh:write(content)
  fh:close()
  return true
end

-- Function to check if a command exists
local function check_dependency(cmd)
  local handle = io.popen("command -v " .. cmd .. " 2>/dev/null")
  local result = handle:read("*a")
  handle:close()
  return result ~= ""
end

-- Returns a filter-specific directory in which cache files can be stored, or nil if not available.
local function cachedir ()
  local cache_home = os.getenv 'XDG_CACHE_HOME'
  if not cache_home or cache_home == '' then
    local user_home = system.os == 'windows'
      and os.getenv 'USERPROFILE'
      or os.getenv 'HOME'

    if not user_home or user_home == '' then
      return nil
    end
    cache_home = pandoc.path.join { user_home, '.cache' }
  end

  -- Create filter cache directory
  local cache_dir = pandoc.path.join { cache_home, 'tikz-diagram-filter' }
  pandoc.system.make_directory(cache_dir, true)
  return cache_dir
end

local image_cache = nil  -- Path holding the image cache, or `nil` if the cache is not used.
local tikzjax_assets_injected = false  -- Guards once-per-document injection of TikZJax JS/CSS.
local passthrough_header_seen = {}  -- Text already hoisted into the preamble by the latex-passthrough renderer.

-- Function to parse properties from code comments
local function properties_from_code (code, comment_start)
  local props = {}
  local pattern = comment_start:gsub('%p', '%%%1') .. '| ?' ..
    '([-_%w]+): ([^\n]*)\n'
  for key, value in code:gmatch(pattern) do
    if key == 'fig-attr' then
      -- Handle nested attributes for fig-attr
      local attr_value = ''
      local subpattern = comment_start:gsub('%p', '%%%1') .. '|   ([^\n]+)\n'
      for subvalue in code:gmatch(subpattern) do
        attr_value = attr_value .. subvalue .. '\n'
      end
      -- Parse the YAML-like subattributes
      local parsed = pandoc.read(attr_value, 'yaml').blocks
      if #parsed > 0 then
        props[key] = pandoc.utils.block_to_lua(parsed[1])
      end
    else
      props[key] = value
    end
  end
  return props
end

-- The rendering pipelines. Both are total: either can serve any output format
-- it supports, and neither needs to know about the other. Whether a block is
-- handed to the host LaTeX document instead of being rendered at all is a
-- separate axis — see `latex-passthrough` below.
local KNOWN_RENDERERS = { latex = true, tikzjax = true }

-- Coerce an option that may arrive as a YAML boolean (from document metadata)
-- or as a string (a `%%|` directive is always text) into a Lua boolean.
-- Returns nil for "unset" and for anything unrecognized, so the caller can
-- tell the two apart from an explicit `false`.
local function truthy(value)
  if value == nil then return nil end
  if type(value) == 'boolean' then return value end
  local s = stringify(value):lower():match('^%s*(.-)%s*$')
  if s == 'true' or s == 'yes' or s == '1' then return true end
  if s == 'false' or s == 'no' or s == '0' then return false end
  return nil
end

-- Validate a renderer name, translating the one that used to exist. `where`
-- names the source for the warning ("tikz.renderer", "%%| renderer:").
local function normalize_renderer(value, where)
  if value == nil then return nil end
  local name = stringify(value)
  if KNOWN_RENDERERS[name] then return name end
  if name == 'latex-passthrough' then
    quarto.log.warning(
      "tikz: " .. where .. " no longer takes 'latex-passthrough'. It is now a " ..
      "separate option, because it decides whether a block is rendered at all " ..
      "rather than how: set `latex-passthrough: true` and leave `renderer` " ..
      "saying how the block should be drawn on non-LaTeX outputs. Ignoring it."
    )
    return nil
  end
  quarto.log.warning(
    "tikz: unknown " .. where .. " '" .. name .. "' — falling back to 'latex'. " ..
    "Supported values: latex, tikzjax."
  )
  return nil
end

-- Function to process code block attributes and options
local function diagram_options(cb)
  -- The `%%| key: value` comment directives are the canonical, current
  -- syntax (and match Quarto's cell-options convention). Code-block fence
  -- attributes (`{.tikz filename=…}`) are the deprecated pre-1.0 form. When
  -- a key is given both ways, the %%| directive wins; we only let a fence
  -- attribute through if the %%| form didn't set that key, and we warn on
  -- any genuine conflict so the silent override becomes visible.
  local attribs = properties_from_code(cb.text, '%%')
  for key, value in pairs(cb.attributes) do
    if attribs[key] == nil then
      attribs[key] = value
    elseif attribs[key] ~= value then
      quarto.log.warning(
        "tikz: '" .. key .. "' is set both as a code-block fence " ..
        "attribute (" .. tostring(value) .. ") and via the canonical " ..
        "%%| " .. key .. ": directive (" .. tostring(attribs[key]) ..
        "). The %%| directive wins; the fence attribute is ignored. " ..
        "Remove one to silence this warning."
      )
    end
  end

  local alt
  local caption
  local fig_attr = attribs['fig-attr'] or { id = cb.identifier }
  local filename
  local image_attr = {}
  local user_opt = {}

  for attr_name, value in pairs(attribs) do
    if attr_name == 'alt' then
      alt = value
    elseif attr_name == 'caption' then
      -- Read caption attribute as Markdown
      caption = pandoc.read(value, 'markdown').blocks
    elseif attr_name == 'filename' then
      filename = value
    elseif attr_name == 'additionalPackages' then
      user_opt['additional-packages'] = value
    elseif attr_name == 'header-includes' then
      user_opt['header-includes'] = value
    elseif attr_name == 'renderer' then
      user_opt['renderer'] = value
    elseif attr_name == 'latex-passthrough' then
      -- Named explicitly so it does not fall through to the `latex-` prefix
      -- rule below and end up as an image attribute.
      user_opt['latex-passthrough'] = value
    elseif attr_name == 'label' then
      fig_attr.id = value
    elseif attr_name == 'name' then
      fig_attr.name = value
    elseif attr_name == 'fig-attr' then
      -- Already handled
    else
      -- Check for prefixed attributes
      local prefix, key = attr_name:match '^(%a+)%-(%a[-%w]*)$'
      if prefix == 'fig' then
        fig_attr[key] = value
      elseif prefix == 'image' or prefix == 'img' then
        image_attr[key] = value
      elseif prefix == 'opt' then
        user_opt[key] = value
      else
        -- Use as image attribute
        image_attr[attr_name] = value
      end
    end
  end

  return {
    ['alt'] = alt or {},
    ['caption'] = caption,
    ['fig-attr'] = fig_attr,
    ['filename'] = filename,
    ['image-attr'] = image_attr,
    ['opt'] = user_opt,
  }
end

-- Map an output format (svg|pdf) to the corresponding MIME type.
local function mime_for_format(format)
  if format == 'pdf' then return 'application/pdf' end
  return 'image/svg+xml'
end

-- Construct a cache filename of the form `<label>.<short-hash>.<format>`.
-- Including the basename makes a directory listing diagnosable (you can
-- tell which diagram produced which file at a glance), while the short
-- hash preserves cache-key uniqueness across code/option changes.
--
-- When the caller-supplied basename is the auto-generated SHA1 of the
-- block's code (40 hex chars), we use a short literal label instead;
-- repeating the full content hash inside the filename adds no diagnostic
-- value and bloats the listing.
--
-- The key is built from a canonical encoding of the options rather than from
-- `stringify(options)` directly, for two reasons.
--
-- Order. `pairs()` iteration order is unspecified by the Lua spec. It is
-- stable for a given build, so this looks fine until the day Quarto ships a
-- pandoc whose Lua hashes keys differently — at which point every cached file
-- in every project is orphaned at once. For the in-tree cache pattern the
-- README recommends, that means a build host without TeX starts failing during
-- an unrelated dependency upgrade, with no local repro. (#21)
--
-- Ambiguity. `stringify` on a table emits its *values*, concatenated with no
-- delimiter and no keys at all. So `{a = 'x', b = ''}` and `{a = '', b = 'x'}`
-- hash alike, as do `{a = 'p', b = 'q'}` and `{a = 'pq', b = ''}` — different
-- options, one cache entry, and whichever block is rendered first wins. That
-- one is a wrong image rather than a missing one.
--
-- Sorting fixes the first; length-prefixing each key and value fixes the
-- second, including for values that themselves contain the delimiters. The
-- code is length-prefixed too, so a block whose text happens to end in what
-- another block's options encode to cannot collide with it.
local function canonical_options(options)
  local keys = {}
  for k in pairs(options) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    local ks, vs = tostring(k), stringify(options[k])
    parts[#parts + 1] = #ks .. ':' .. ks .. '=' .. #vs .. ':' .. vs
  end
  return table.concat(parts, ',')
end

local function cache_filename(basename, hash, options, format)
  local cache_key = pandoc.sha1(
    #hash .. ':' .. hash .. canonical_options(options)
  )
  local short = cache_key:sub(1, 8)
  local label = basename or 'tikz'
  if #label == 40 and label:match('^[0-9a-f]+$') then
    label = 'tikz'
  end
  return label .. '.' .. short .. '.' .. format
end

-- Function to get cached image
local function get_cached_image (basename, hash, options, format)
  if not image_cache then
    return nil
  end
  local imgpath = pandoc.path.join {
    image_cache, cache_filename(basename, hash, options, format),
  }
  local imgdata = read_file(imgpath)
  if imgdata then
    return imgdata, mime_for_format(format)
  end
  return nil
end

-- Function to cache image
local function cache_image (basename, hash, options, imgdata, format)
  -- Do nothing if caching is disabled or not possible.
  if not image_cache then
    return
  end
  local imgpath = pandoc.path.join {
    image_cache, cache_filename(basename, hash, options, format),
  }
  write_file(imgpath, imgdata)
end

-- Preamble text hoisted by the latex-passthrough renderer, kept in three
-- ordered buckets and flushed once at the end of the document walk. Emitting
-- in bucket order rather than block-encounter order guarantees that a
-- `\usepackage{pgfplots}` from one block precedes a `\usepgfplotslibrary{…}`
-- hoisted out of another, and makes the preamble stable under block
-- reordering.
local PASSTHROUGH_PACKAGES, PASSTHROUGH_LIBRARIES, PASSTHROUGH_HEADERS = 1, 2, 3
local passthrough_preamble = { {}, {}, {} }
local passthrough_header_seen = {}  -- Text already queued, so we emit it once.

-- Queue `text` for the host document's preamble, at most once per render.
-- Deduplication is by exact text, which is what makes it safe to hoist the
-- same `\usetikzlibrary{arrows}` or `%%| additionalPackages:` line out of a
-- dozen blocks: identical strings collapse to one, and anything that differs
-- is emitted in full rather than being cleverly merged.
local function hoist(bucket, text)
  if not text or text == '' then return end
  if passthrough_header_seen[text] then return end
  passthrough_header_seen[text] = true
  local b = passthrough_preamble[bucket]
  b[#b + 1] = text
end

-- Emit everything queued above into the host preamble. Called once, after the
-- document walk, so bucket order is what reaches the `.tex`.
local function flush_passthrough_preamble()
  local parts = {}
  for _, bucket in ipairs(passthrough_preamble) do
    for _, text in ipairs(bucket) do parts[#parts + 1] = text end
  end
  if #parts == 0 then return end
  local text = table.concat(parts, '\n')
  if quarto and quarto.doc and quarto.doc.include_text then
    quarto.doc.include_text('in-header', text)
  else
    quarto.log.warning(
      "tikz: cannot hoist preamble text automatically — " ..
      "quarto.doc.include_text unavailable. Add the following to your " ..
      "include-in-header manually:\n" .. text
    )
  end
end

-- Treat an empty attribute (pandoc gives an unlabelled block `identifier = ''`)
-- as absent, so it can fall through to the next naming candidate.
local function blank_to_nil(s)
  if s == nil or s == '' then return nil end
  return s
end

-- Split a string into lines, dropping the trailing empty element that a
-- final newline would otherwise produce.
local function split_lines(s)
  local lines = {}
  for line in (s .. '\n'):gmatch('([^\n]*)\n') do
    lines[#lines + 1] = line
  end
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

-- The block text as it matters to the *compiler*, with the `%%|` directives
-- removed. Used for the cache key and for the generated basename, never for
-- what is actually compiled.
--
-- `%%|` lines are TeX comments, so dropping them cannot change a rendered
-- byte, and every directive that does influence compilation — additionalPackages,
-- header-includes, renderer, opt-* — is folded into the options half of the key
-- separately by `diagram_options`. What is left in them is presentation:
-- caption, alt, label, name, fig-attr, filename. Hashing those meant that
-- captioning a diagram, or migrating a block from the deprecated
-- `{.tikz filename='x'}` fence attribute to the canonical `%%| filename: x`,
-- silently re-keyed a cache entry whose image had not changed — invisible
-- locally, fatal on a TeX-less build host rendering from a committed cache. (#28)
--
-- A directive sharing a line with code truncates that line rather than removing
-- it; a line left blank by the removal is dropped, so an indented directive and
-- an absent one agree.
local function hashable_code(code)
  local out = {}
  for _, line in ipairs(split_lines(code)) do
    local kept = line:gsub('%%%%|.*$', '')
    if kept == line or not kept:match('^%s*$') then
      out[#out + 1] = kept
    end
  end
  return table.concat(out, '\n')
end

-- The library loaders we know how to hoist. All are idempotent — PGF records
-- "already loaded" globally — which is what lets us *copy* one into the
-- preamble and leave the body copy in place as a no-op.
local LOADER_MACROS = {
  'usetikzlibrary', 'usepgfplotslibrary', 'usepgflibrary', 'usetikzmarklibrary',
}

-- Preamble-only macros we recognise but never relocate: `\usegdlibrary` has
-- ordering requirements we can't reason about, and a `\usepackage` in a
-- passthrough body is an authoring mistake with its own LaTeX error. Both get
-- a warning pointing at `%%| additionalPackages:`.
local WARN_ONLY_MACROS = { 'usegdlibrary', 'usepackage' }

-- Return the code portion of a TeX line, dropping any comment. A `%` escaped
-- as `\%` is a literal percent sign and does not start one. Used only to
-- decide what to scan; the original line is what gets emitted.
local function code_part(line)
  local i = 1
  while true do
    local p = line:find('%%', i)
    if not p then return line end
    local backslashes, j = 0, p - 1
    while j >= 1 and line:sub(j, j) == '\\' do
      backslashes = backslashes + 1
      j = j - 1
    end
    if backslashes % 2 == 0 then return line:sub(1, p - 1) end
    i = p + 1
  end
end

-- Match a line that is *exactly* one library-loading call and nothing else,
-- returning the macro name and its argument. The argument is matched with
-- `%b{}` rather than a non-greedy `(.-)}`: the latter backtracks to the last
-- brace on the line, so `\usetikzlibrary{arrows}\begin{tikzpicture}` would
-- match with `arrows}\begin{tikzpicture` as its "argument".
local function match_loader_line(line)
  local c = code_part(line)
  for _, macro in ipairs(LOADER_MACROS) do
    local arg = c:match('^%s*\\' .. macro .. '%s*(%b{})%s*$')
      or c:match('^%s*\\' .. macro .. '%s*(%b[])%s*$')
    if arg then return macro, arg:sub(2, -2) end
  end
  return nil
end

-- Split a loader argument into individual library names, so a dozen blocks
-- opening with `\usetikzlibrary{arrows, arrows.meta}` collapse to two preamble
-- lines instead of a dozen identical ones. Splitting is only a deduplication
-- nicety, so we decline it whenever the argument contains a group — cutting on
-- a comma inside `.style={draw,fill=blue!20}` would fabricate nonsense.
local function split_libs(arg)
  if arg:find('[{}]') then return { arg } end
  local names = {}
  for raw in arg:gmatch('[^,]+') do
    local name = raw:match('^%s*(.-)%s*$')
    if name ~= '' then names[#names + 1] = name end
  end
  return names
end

-- Find every call to one of `macros` in `line` (comments already stripped),
-- in source order, with the position and balanced argument of each.
local function scan_loader_calls(line, macros)
  local found = {}
  for _, macro in ipairs(macros) do
    local init = 1
    while true do
      local s, e = line:find('\\' .. macro, init, true)
      if not s then break end
      init = e + 1
      -- Reject a longer control sequence (`\usepackages`, say).
      if not line:sub(e + 1, e + 1):match('%a') then
        local p = e + 1
        while line:sub(p, p) == ' ' do p = p + 1 end
        local arg = line:match('^(%b{})', p) or line:match('^(%b[])', p)
        found[#found + 1] = {
          pos = s,
          macro = macro,
          arg = arg and arg:sub(2, -2) or nil,
        }
      end
    end
  end
  table.sort(found, function(a, b) return a.pos < b.pos end)
  return found
end

-- Positions at which a `tikzpicture` environment opens (+1) or closes (-1).
local function picture_markers(line)
  local marks = {}
  for pattern, delta in pairs({ ['\\begin%s*{tikzpicture}'] = 1,
                                ['\\end%s*{tikzpicture}'] = -1 }) do
    local init = 1
    while true do
      local s, e = line:find(pattern, init)
      if not s then break end
      marks[#marks + 1] = { pos = s, delta = delta }
      init = e + 1
    end
  end
  return marks
end

-- Prepare a block body for passthrough: hoist the library loads into the host
-- preamble and drop the `%%|` option directives (they are filter input, not
-- LaTeX). Returns the preamble lines, the remaining body, and any warnings.
--
-- Two passes, because how a load is written decides what we may do with it:
--
--   1. A line that is *exactly* one loader call is **moved** — hoisted and
--      removed from the body. This is the overwhelmingly common shape and it
--      keeps the shipped `.tex` tidy.
--   2. A loader call sharing its line with other code cannot be excised
--      without risking the drawing, so it is **copied**: the preamble gets a
--      load, the body keeps its own. That is safe because PGF's loaders are
--      idempotent — the preamble load wins and the body copy becomes a no-op.
--
-- Copying matters rather than being merely tidy. `\usetikzlibrary` is legal in
-- the document body, but a captioned block is emitted inside a `figure`
-- environment, and PGF records "library loaded" *globally* while the library
-- file's own definitions are local. Loading inside that group therefore leaves
-- the definitions behind at `\end{figure}` while suppressing every later load
-- of the same library — so a *different, later* block fails, with an error
-- naming PGF math rather than library loading.
--
-- What we still refuse to touch: a loader inside a `tikzpicture` (it may be
-- literal content in a diagram *about* TikZ, and inventing a library name is a
-- hard error), one whose argument won't brace-balance, and `\usepackage` /
-- `\usegdlibrary`. Those only produce a warning.
local function prepare_passthrough_body(code)
  local preamble, body, warns = {}, {}, {}

  for _, line in ipairs(split_lines(code)) do
    local macro, arg = match_loader_line(line)
    if macro then
      for _, name in ipairs(split_libs(arg)) do
        preamble[#preamble + 1] = '\\' .. macro .. '{' .. name .. '}'
      end
    elseif not line:match('^%s*%%%%|') then
      body[#body + 1] = line
    end
  end

  -- Trim the blank lines the removals leave at either end, so the emitted
  -- LaTeX starts at the picture.
  while body[1] and body[1]:match('^%s*$') do table.remove(body, 1) end
  while body[#body] and body[#body]:match('^%s*$') do table.remove(body) end

  local depth = 0
  for _, line in ipairs(body) do
    local c = code_part(line)
    local marks = picture_markers(c)
    local function depth_at(pos)
      local d = depth
      for _, m in ipairs(marks) do
        if m.pos < pos then d = d + m.delta end
      end
      return d
    end
    for _, call in ipairs(scan_loader_calls(c, LOADER_MACROS)) do
      if depth_at(call.pos) > 0 then
        warns[#warns + 1] = '\\' .. call.macro ..
          " inside a tikzpicture is left alone; move it to its own line if it " ..
          "is meant to load a library: " .. line
      elseif not call.arg then
        warns[#warns + 1] = '\\' .. call.macro ..
          " has no brace-balanced argument, so it cannot be hoisted: " .. line
      else
        for _, name in ipairs(split_libs(call.arg)) do
          preamble[#preamble + 1] = '\\' .. call.macro .. '{' .. name .. '}'
        end
      end
    end
    for _, call in ipairs(scan_loader_calls(c, WARN_ONLY_MACROS)) do
      warns[#warns + 1] = '\\' .. call.macro ..
        " is preamble-only and is never relocated; put it in " ..
        "`%%| additionalPackages:` instead: " .. line
    end
    for _, m in ipairs(marks) do depth = depth + m.delta end
  end

  return preamble, table.concat(body, '\n'), warns
end

-- LaTeX passthrough: hand the TikZ source to the host document as raw LaTeX
-- instead of compiling it to a PDF and embedding the result. The diagram is
-- then typeset by the same LaTeX run as the surrounding text, which matches
-- fonts and sizing for free, keeps the source editable in the shipped
-- `.tex`, and produces no figure files at all.
--
-- Everything the standalone wrapper used to supply has to reach the host
-- preamble instead: `\usepackage{tikz}` (the host document class does not
-- load it), the block's `additionalPackages` / `header-includes`, and the
-- `\usetikzlibrary` calls written in the body.
local function embed_latex_passthrough(code, user_opts, basename)
  hoist(PASSTHROUGH_PACKAGES, '\\usepackage{tikz}')
  hoist(PASSTHROUGH_PACKAGES, stringify(user_opts['additional-packages'] or ''))
  hoist(PASSTHROUGH_HEADERS, stringify(user_opts['header-includes'] or ''))
  local preamble, body, warns = prepare_passthrough_body(code)
  for _, text in ipairs(preamble) do
    hoist(PASSTHROUGH_LIBRARIES, text)
  end
  if #warns > 0 then
    quarto.log.warning(
      "tikz: renderer 'latex-passthrough', block '" .. tostring(basename) ..
      "': the following could not be hoisted into the preamble. A library " ..
      "loaded in the body of a captioned block is scoped to its `figure` " ..
      "environment, and because PGF records the load globally, later blocks " ..
      "silently lose the library.\n  - " .. table.concat(warns, '\n  - ')
    )
  end
  return pandoc.RawBlock('latex', body)
end

-- Inject TikZJax assets (link + script tags) into the document head exactly
-- once per render. Subsequent calls are no-ops.
local function inject_tikzjax_assets(conf)
  if tikzjax_assets_injected then return end
  tikzjax_assets_injected = true
  local url = conf.tikzjax_url
  local html = string.format(
    '<link rel="stylesheet" href="%s/fonts.css">\n' ..
    '<script src="%s/tikzjax.js"></script>',
    url, url
  )
  if quarto and quarto.doc and quarto.doc.include_text then
    quarto.doc.include_text('in-header', html)
  else
    quarto.log.warning(
      "tikz: cannot inject TikZJax assets automatically — " ..
      "quarto.doc.include_text unavailable. Add the following to your " ..
      "include-in-header manually:\n" .. html
    )
  end
end

-- Build a `<script type="text/tikz">` block for client-side rendering by
-- TikZJax. The user's tikzpicture is wrapped in \begin{document}…\end{document}
-- (TikZJax provides \documentclass{standalone} itself), with any
-- additionalPackages / header-includes prepended so the same `.tikz` source
-- works under either renderer.
local function embed_tikzjax(code, user_opts, conf)
  inject_tikzjax_assets(conf)
  local prelude_parts = {}
  local additional = stringify(user_opts['additional-packages'] or '')
  if additional ~= '' then
    table.insert(prelude_parts, additional)
  end
  local headers = stringify(user_opts['header-includes'] or '')
  if headers ~= '' then
    table.insert(prelude_parts, headers)
  end
  local prelude = table.concat(prelude_parts, '\n')
  local body = (prelude ~= '' and (prelude .. '\n') or '') ..
    '\\begin{document}\n' .. code .. '\n\\end{document}'
  return pandoc.RawBlock('html',
    '<script type="text/tikz">\n' .. body .. '\n</script>')
end

-- Compile TikZ code to either SVG (default) or PDF (passthrough, used when
-- the Quarto output format is PDF).
--
-- Returns `imgdata, mimetype` on success and `nil, message` on failure. It
-- deliberately does not use `error()` for expected failures — a missing TeX
-- engine, a LaTeX run that did not produce a file. Under Quarto, `error()`
-- inside a filter is intercepted: the message is logged but execution
-- *continues to the next statement*, and a surrounding `pcall` reports
-- success. Verified on Quarto 1.10.18 with an eight-line filter:
--
--     error('boom')                      --> logs "ERROR (…) boom", continues
--     pcall(function() error('boom') end) --> true, nil
--
-- So every `error()` here used to be a log-and-carry-on that left the rest of
-- the pipeline running against a file that was never produced: one missing
-- engine emitted four errors, then handed `nil` to the cache writer, whose
-- genuine runtime error (`fh:write(nil)`) *did* propagate and took the entire
-- render down. Returning failures makes the control flow independent of the
-- host's error semantics, which is what we want regardless of which way
-- Quarto jumps in future. (#30)
local function compile_tikz_to_svg(code, user_opts, conf, basename)  -- Added conf and basename parameters
  -- Ensure required dependencies are available
  if not check_dependency(conf.tex_engine) then
    return nil, conf.tex_engine .. " not found on PATH. Install it, or set " ..
      "tikz.tex-engine to a TeX engine you do have (pdflatex, lualatex, " ..
      "xelatex, …)."
  end
  -- The svg converter is only needed when we actually convert to SVG. For
  -- PDF output we embed the intermediate PDF directly and nothing here is
  -- invoked. When a custom svg-command is set, dependency-check the
  -- command's executable; otherwise the configured svg-engine.
  if conf.output_format ~= 'pdf' then
    local svg_cmd = conf.svg_command and conf.svg_command[1] or conf.svg_engine
    if not check_dependency(svg_cmd) then
      return nil, svg_cmd .. " not found. Please install it (the configured svg converter) to convert TeX output to SVG."
    end
  end

  local function process_in_dir(dir)
    return with_working_directory(dir, function()
      -- Define file names:
      -- Use the provided basename or default to "tikz-image"
      local base_filename = basename or "tikz-image"
      local tikz_file = base_filename .. ".tex"
      local pdf_file = base_filename .. ".pdf"
      local svg_file = base_filename .. ".svg"
      local dvi_file = base_filename .. ".dvi"

      -- Build the LaTeX document. Use the user's template if they supplied
      -- one via tikz.tex-template; otherwise fall back to the bundled
      -- standalone template.
      local tikz_template = pandoc.template.compile(
        conf.tex_template_content or [[
\documentclass[tikz]{standalone}
% \usepackage{tikz} % already loaded by the documentclass
$additional-packages$
$for(header-includes)$
$it$
$endfor$
\begin{document}
$body$
\end{document}
      ]])
      local meta = {
        ['header-includes'] = { pandoc.RawInline(
          'latex',
          stringify(user_opts['header-includes'] or '')
        ) },
        ['additional-packages'] = { pandoc.RawInline(
          'latex',
          stringify(user_opts['additional-packages'] or '')
        ) },
      }
      local tex_code = pandoc.write(
        pandoc.Pandoc({ pandoc.RawBlock('latex', code) }, meta),
        'latex',
        { template = tikz_template }
      )
      write_file(tikz_file, tex_code)

      -- Execute the LaTeX compiler with TEXINPUTS so blocks can \input or
      -- \usepackage shared files from the qmd directory or the extension dir.
      -- with_environment replaces the entire env, so we merge our override
      -- onto a copy of the current env to preserve PATH and friends.
      local env = pandoc.system.environment()
      env.TEXINPUTS = conf.texinputs
      -- dvisvgm consumes a DVI file, so ask the TeX engine for DVI output
      -- in that case. Every other path (inkscape, pdftocairo, custom
      -- svg-command, PDF passthrough) consumes the default PDF output.
      local latex_args = { '-interaction=nonstopmode' }
      if conf.svg_engine == 'dvisvgm' then
        table.insert(latex_args, '-output-format=dvi')
      end
      table.insert(latex_args, tikz_file)
      local success, latex_result = pcall(function()
        return pandoc.system.with_environment(env, function()
          return pandoc.pipe(conf.tex_engine, latex_args, '')
        end)
      end)
      if not success then
        local log_file = base_filename .. ".log"
        local log_content = read_file(log_file) or ""
        return nil, "Error compiling TikZ figure '" .. base_filename .. "':\n" ..
          tostring(latex_result) .. "\nLaTeX Log:\n" .. log_content ..
          "\nTikZ Code:\n" .. code
      end

      -- For PDF output, embed the intermediate PDF directly — no SVG
      -- conversion needed. This skips the Inkscape rasterization round-trip
      -- and preserves vector fidelity / fonts in the rendered PDF.
      if conf.output_format == 'pdf' then
        local imgdata = read_file(pdf_file)
        if not imgdata then
          return nil, "Failed to read generated PDF file for TikZ figure '" ..
            base_filename .. "'.\nTikZ Code:\n" .. code
        end
        return imgdata, 'application/pdf'
      end

      -- Convert TeX output to SVG. If the user supplied a custom command
      -- via `svg-command`, that takes precedence; otherwise dispatch on
      -- the configured svg-engine.
      local convert_cmd = conf.svg_engine
      local convert_args
      if conf.svg_command then
        -- Substitute {input}/{output} placeholders. Element 1 is the
        -- executable; remaining elements are its args.
        convert_cmd = conf.svg_command[1]
        convert_args = {}
        for i = 2, #conf.svg_command do
          local arg = conf.svg_command[i]
            :gsub('{input}', pdf_file)
            :gsub('{output}', svg_file)
          convert_args[#convert_args + 1] = arg
        end
      elseif conf.svg_engine == 'dvisvgm' then
        -- dvisvgm reads DVI directly. --font-format=woff embeds fonts as
        -- WOFF (instead of converting glyphs to paths), which keeps text
        -- selectable / styleable in the rendered SVG. Note: dvisvgm must
        -- be the TeX-Live-integrated build (e.g. via tlmgr); standalone
        -- packages can fail to find the PostScript prologue files.
        convert_args = {
          '--font-format=woff',
          '-o', svg_file,
          dvi_file,
        }
      elseif conf.svg_engine == 'pdftocairo' then
        -- pdftocairo (poppler-utils) reads PDF and is widely available;
        -- a good lightweight alternative to Inkscape for systems where
        -- Inkscape isn't installed.
        convert_args = {
          '-svg',
          pdf_file,
          svg_file,
        }
      else
        -- Inkscape default. Note: --pages=N (Inkscape 1.2+) is omitted
        -- because the standalone class always produces a single-page PDF,
        -- and dropping it preserves compatibility with Inkscape 1.0/1.1
        -- (issue #4).
        convert_args = {
          '--export-area-drawing',
          '--export-type=svg',
          '--export-plain-svg',
          '--export-margin=0',
          '--export-filename=' .. svg_file,
          pdf_file,
        }
      end
      local success_convert, convert_result = pcall(
        pandoc.pipe, convert_cmd, convert_args, ''
      )
      if not success_convert then
        return nil, "Error converting to SVG (command: " .. convert_cmd ..
          ") for TikZ figure '" .. base_filename .. "':\n" ..
          tostring(convert_result) .. "\nTikZ Code:\n" .. code
      end

      -- Read the SVG file
      local imgdata = read_file(svg_file)
      if not imgdata then
        return nil, "Failed to read generated SVG file for TikZ figure '" ..
          base_filename .. "'.\nTikZ Code:\n" .. code
      end
      return imgdata, 'image/svg+xml'
    end)
  end

  if conf.save_tex then
    local dir = conf.tex_dir
    -- Use the basename or hash to create a subdirectory
    local subdir_name = basename or pandoc.sha1(code)
    local diagram_dir = pandoc.path.join { dir, subdir_name }
    pandoc.system.make_directory(diagram_dir, true)
    return process_in_dir(diagram_dir)
  else
    return with_temporary_directory("tikz", function(tmpdir)
      return process_in_dir(tmpdir)
    end)
  end
end

-- Function to process code blocks and generate figures
local function code_to_figure(conf)
  return function(block)
    if block.t ~= 'CodeBlock' then
      return nil
    end

    -- Check if it's a TikZ code block
    if not block.classes:includes('tikz') then
      return nil
    end

    -- Get options from code block
    local dgr_opt = diagram_options(block)

    -- Fold doc-level options that influence compilation into the cache key,
    -- so editing the template / switching the tex or svg engine / changing
    -- the output format invalidates cached entries.
    if conf.tex_template_content then
      dgr_opt.opt['tex-template-hash'] = pandoc.sha1(conf.tex_template_content)
    end
    dgr_opt.opt['tex-engine'] = conf.tex_engine
    dgr_opt.opt['svg-engine'] = conf.svg_engine
    if conf.svg_command then
      dgr_opt.opt['svg-command'] = table.concat(conf.svg_command, ' ')
    end

    -- Resolve the two independent axes.
    --
    -- `renderer` says *how* a block is drawn when we have to draw it: 'latex'
    -- (the pdflatex/inkscape chain configured above) or 'tikzjax' (a
    -- <script type="text/tikz"> rendered in the reader's browser). Both are
    -- per-block overridable with %%| renderer: ….
    local renderer = normalize_renderer(dgr_opt.opt['renderer'], '%%| renderer:')
      or conf.renderer or 'latex'

    -- `latex-passthrough` says *whether* to draw it at all: under LaTeX output
    -- the host document can typeset the picture itself, so we hand over the
    -- source instead of rendering anything. It is deliberately not a renderer
    -- value — it applies to exactly one output family, and on every other
    -- format `renderer` above already says what should happen, with no
    -- fallback policy for this filter to invent.
    local passthrough = dgr_opt.opt['latex-passthrough']
    if passthrough ~= nil then
      local parsed = truthy(passthrough)
      if parsed == nil then
        quarto.log.warning(
          "tikz: %%| latex-passthrough: expects true or false, got '" ..
          stringify(passthrough) .. "'. Ignoring it."
        )
      end
      passthrough = parsed
    end
    if passthrough == nil then passthrough = conf.latex_passthrough end
    -- Keep it out of the cache key: when passthrough is in force nothing is
    -- cached, and when it isn't the flag has no bearing on the rendered image.
    dgr_opt.opt['latex-passthrough'] = nil

    -- Fold the renderer into the cache key only when non-default, so existing
    -- latex-pipeline cache entries (written without a 'renderer' key) stay
    -- valid.
    if renderer ~= 'latex' then
      dgr_opt.opt['renderer'] = renderer
    end

    -- LaTeX passthrough: emit the TikZ source itself, letting the host
    -- document typeset it. Gated on the output really being LaTeX, so the
    -- SVG/HTML paths are untouched and a document can carry the flag
    -- project-wide while still building HTML with whatever `renderer` says.
    --
    -- Checked before the renderers, because it decides *whether* to render:
    -- a `renderer: tikzjax` document with passthrough on must hand its source
    -- to a LaTeX build, not fall into tikzjax's drop-for-non-HTML rule.
    if passthrough and conf.output_format == 'pdf' then
      local raw = embed_latex_passthrough(
        block.text, dgr_opt.opt,
        dgr_opt.filename or blank_to_nil(dgr_opt['fig-attr'].id) or '<unnamed>'
      )
      -- A captioned block still becomes a pandoc.Figure, exactly as on the
      -- other two paths, so `%%| caption:` and `fig-attr` behave the same
      -- whichever renderer is in force; pandoc wraps it in a `figure`
      -- environment with a `\caption`. An uncaptioned block is emitted bare,
      -- with no float and no centring, leaving placement to the caller.
      return dgr_opt.caption and
          pandoc.Figure(
            { raw },
            dgr_opt.caption,
            dgr_opt['fig-attr']
          ) or
          raw
    end

    -- TikZJax path: emit a <script type="text/tikz"> block for the reader's
    -- browser to render. Only meaningful for HTML-based output (html,
    -- revealjs, etc.); for anything else, warn and drop the block.
    if renderer == 'tikzjax' then
      local is_html_output =
        (quarto and quarto.doc and quarto.doc.is_format
          and quarto.doc.is_format('html:js'))
        or (FORMAT and FORMAT:match('^html'))
      if not is_html_output then
        quarto.log.warning(
          "tikz: renderer 'tikzjax' only renders to HTML; dropping block " ..
          "for format '" .. tostring(FORMAT) .. "'. " ..
          "Set renderer: latex (or remove the override) to render this " ..
          "block under non-HTML output."
        )
        return {}  -- remove the block from the output entirely
      end
      local raw = embed_tikzjax(block.text, dgr_opt.opt, conf)
      -- Figure content takes a list of Blocks; RawBlock plugs in directly
      -- (unlike the LaTeX path's Image, which is an Inline that needs Plain).
      return dgr_opt.caption and
          pandoc.Figure(
            { raw },
            dgr_opt.caption,
            dgr_opt['fig-attr']
          ) or
          raw
    end

    -- Get basename for file naming
    local basename = dgr_opt.filename or pandoc.sha1(hashable_code(block.text))

    -- Check if image is cached
    local hash = hashable_code(block.text)
    local imgdata, imgtype = nil, nil
    local out_format = conf.output_format
    if conf.cache then
      imgdata, imgtype = get_cached_image(basename, hash, dgr_opt.opt, out_format)
    end

    if not imgdata or not imgtype then
      -- No cached image; compile TikZ code. Two failure channels, because
      -- they mean different things and only one of them is under our
      -- control:
      --
      --   * `compile_tikz_to_svg` returns `nil, message` for an expected
      --     failure — a missing engine, a LaTeX run that produced no file.
      --   * `pcall` still guards against a genuine runtime error in the
      --     filter itself, which (unlike `error()`, see the note on
      --     compile_tikz_to_svg) really does propagate under Quarto.
      --
      -- Either way one diagram must not take down the render: log it once,
      -- leave the block as its source, and let the rest of the document
      -- through. On a build host without TeX that turns a failed publish
      -- into a cosmetic gap. (#30)
      local ok, result, extra = pcall(function()
        return compile_tikz_to_svg(block.text, dgr_opt.opt, conf, basename) -- Pass conf and basename
      end)
      local failure
      if not ok then
        failure = tostring(result)
      elseif not result then
        failure = extra or "no image data was produced"
      end
      if failure then
        quarto.log.error(
          "tikz: could not render figure '" .. basename .. "', leaving the " ..
          "block unrendered.\n" .. failure
        )
        return nil -- Return the original block unchanged
      end
      -- pcall returns (true, returned_values...) on success; result is the
      -- imgdata, extra is the MIME string returned by compile_tikz_to_svg.
      imgdata, imgtype = result, extra or mime_for_format(out_format)

      -- Cache the image
      cache_image(basename, hash, dgr_opt.opt, imgdata, out_format)
    end

    -- Use the block's filename attribute or create a new name by hashing the image content.
    local fname = basename .. '.' .. out_format

    -- Store the data in the mediabag:
    pandoc.mediabag.insert(fname, imgtype, imgdata)

    -- Create the image object.
    local image = pandoc.Image(dgr_opt.alt, fname, "", dgr_opt['image-attr'])

    -- Create a figure if the diagram has a caption; otherwise return just the image.
    return dgr_opt.caption and
        pandoc.Figure(
          pandoc.Plain { image },
          dgr_opt.caption,
          dgr_opt['fig-attr']
        ) or
        pandoc.Plain { image }
  end
end

-- Resolve a (possibly relative) path to an absolute path. Necessary because
-- pdflatex is launched from a temporary working directory, so any TEXINPUTS
-- entries that started life as relative paths against the qmd's cwd would
-- otherwise resolve to nothing.
local function absolutize(p)
  if not p or p == '' then return nil end
  if pandoc.path.is_absolute(p) then return p end
  local cwd = os.getenv('PWD') or os.getenv('CD') or '.'
  return pandoc.path.normalize(pandoc.path.join { cwd, p })
end

-- Build TEXINPUTS so TikZ blocks can \input shared files from the qmd
-- directory and from the extension's own directory, while preserving any
-- existing TEXINPUTS and the system default search path.
local function build_texinputs()
  -- Path separator: ':' on Unix, ';' on Windows.
  local sep = (pandoc.system.os == 'windows') and ';' or ':'

  -- Directory of the source qmd. Prefer quarto.doc.input_file; fall back
  -- to PANDOC_STATE.input_files[1] for older Quarto / plain-pandoc use.
  local source_file = (quarto and quarto.doc and quarto.doc.input_file)
    or (PANDOC_STATE and PANDOC_STATE.input_files and PANDOC_STATE.input_files[1])
  local source_dir = source_file
    and pandoc.path.directory(absolutize(source_file))
    or nil

  -- Directory of this filter script (so the extension can ship shared
  -- .tex/.sty files alongside tikz.lua).
  local ext_dir = PANDOC_SCRIPT_FILE
    and pandoc.path.directory(absolutize(PANDOC_SCRIPT_FILE))
    or nil

  -- Preserve any pre-existing TEXINPUTS from the user's environment.
  local existing = os.getenv('TEXINPUTS')

  local parts = {}
  if source_dir then parts[#parts + 1] = source_dir end
  if ext_dir and ext_dir ~= source_dir then parts[#parts + 1] = ext_dir end
  if existing and existing ~= '' then parts[#parts + 1] = existing end
  -- Trailing separator => include system defaults.
  return table.concat(parts, sep) .. sep
end

-- Function to configure the filter based on document metadata. Reads
-- top-level `tikz:` config and produces a normalized `conf` table that the
-- per-block code path consumes.
local function configure (meta)
  local conf = meta.tikz or {}
  meta.tikz = nil  -- Remove tikz metadata to avoid processing it further

  -- cache for image files
  if conf.cache == true then
    image_cache = conf['cache-dir']
      and stringify(conf['cache-dir'])
      or cachedir()
    if image_cache then
      pandoc.system.make_directory(image_cache, true)
    end
  else
    image_cache = nil
  end

  -- Handle save-tex option
  local save_tex = conf['save-tex'] or false
  local tex_dir = nil
  if save_tex then
    if image_cache then
      -- Both cache and save-tex are enabled; raise a warning and disable save-tex
      quarto.log.warning("Both 'cache' and 'save-tex' are enabled. Disabling 'save-tex' since caching is active.")
      save_tex = false
    else
      tex_dir = conf['tex-dir']
      if tex_dir then
        tex_dir = pandoc.utils.stringify(tex_dir)
      else
        -- Use a default directory, e.g., 'tikz-tex'
        tex_dir = 'tikz-tex'
      end
      pandoc.system.make_directory(tex_dir, true)
    end
  end

  -- Custom LaTeX standalone template. Read once at filter setup so we don't
  -- pay file I/O per diagram, and so the path resolves against the qmd's
  -- cwd before with_working_directory changes it.
  local tex_template_content = nil
  local tex_template = conf['tex-template']
  if tex_template then
    local tex_template_path = absolutize(pandoc.utils.stringify(tex_template))
    tex_template_content = read_file(tex_template_path)
    if not tex_template_content then
      quarto.log.error(
        "tikz: tex-template not found: " .. tostring(tex_template_path) ..
        " — falling back to the default template."
      )
    end
  end

  -- TeX engine. Defaults to pdflatex (the historical behaviour). Users who
  -- need lualatex/xelatex (e.g. for fontspec, complex Unicode scripts) can
  -- opt in. Anything matching an executable on PATH is accepted.
  local tex_engine = conf['tex-engine']
  tex_engine = tex_engine and pandoc.utils.stringify(tex_engine) or 'pdflatex'

  -- SVG engine. Choices:
  --   inkscape   — default. Consumes the PDF produced by pdflatex.
  --   pdftocairo — poppler-utils. Lightweight alternative to inkscape;
  --                also consumes the PDF.
  --   dvisvgm    — consumes a DVI (we ask pdflatex for -output-format=dvi
  --                in that case). Embeds fonts as WOFF so text in the
  --                rendered SVG stays selectable.
  local svg_engine = conf['svg-engine']
  svg_engine = svg_engine and pandoc.utils.stringify(svg_engine) or 'inkscape'
  local supported = { inkscape = true, dvisvgm = true, pdftocairo = true }
  if not supported[svg_engine] then
    quarto.log.warning(
      "tikz: unknown svg-engine '" .. svg_engine ..
      "' — falling back to inkscape. Supported values: inkscape, dvisvgm, pdftocairo."
    )
    svg_engine = 'inkscape'
  end

  -- Custom svg-command escape hatch. Lets users wire any external converter
  -- (pdf2svg, pymupdf script, mutool, …) without us having to bless each by
  -- name. Two YAML forms are accepted:
  --   svg-command: "mytool {input} {output}"           # whitespace-tokenized
  --   svg-command: [mytool, "{input}", "{output}"]     # explicit list (preferred
  --                                                    # if any path may have spaces)
  -- {input} expands to the intermediate PDF path; {output} to the target
  -- SVG path. When set, this takes precedence over svg-engine.
  local svg_command = nil
  local svg_command_raw = conf['svg-command']
  if svg_command_raw then
    local parts = {}
    if pandoc.utils.type(svg_command_raw) == 'List' then
      for _, item in ipairs(svg_command_raw) do
        parts[#parts + 1] = pandoc.utils.stringify(item)
      end
    else
      local s = pandoc.utils.stringify(svg_command_raw)
      for word in s:gmatch('%S+') do
        parts[#parts + 1] = word
      end
    end
    if #parts > 0 then
      svg_command = parts
    else
      quarto.log.warning("tikz: svg-command is empty; ignoring.")
    end
  end

  -- Output format: 'pdf' when the Quarto output format is PDF, otherwise
  -- 'svg'. Drives whether we run the SVG engine or embed the PDF directly.
  local out_format = 'svg'
  if quarto and quarto.doc and quarto.doc.isFormat and quarto.doc.isFormat('pdf') then
    out_format = 'pdf'
  end

  -- Rendering pipeline. 'latex' (default) runs the server-side TeX +
  -- svg-engine chain configured above; 'tikzjax' emits a
  -- <script type="text/tikz"> for client-side WebAssembly rendering in the
  -- reader's browser. Per-block %%| renderer: … overrides.
  local renderer = normalize_renderer(conf.renderer, 'tikz.renderer') or 'latex'

  -- Hand TikZ source to the host document instead of rendering it, whenever
  -- the output format is LaTeX. Orthogonal to `renderer`, which still governs
  -- every other output format. Per-block %%| latex-passthrough: … overrides.
  local latex_passthrough = truthy(conf['latex-passthrough'])
  if latex_passthrough == nil and conf['latex-passthrough'] ~= nil then
    quarto.log.warning(
      "tikz: latex-passthrough expects true or false, got '" ..
      stringify(conf['latex-passthrough']) .. "'. Treating it as false."
    )
  end
  latex_passthrough = latex_passthrough or false

  -- Base URL serving tikzjax.js and fonts.css. Defaults to the canonical
  -- tikzjax.com CDN; users can self-host or pin a fork (e.g. drgrice1's).
  local tikzjax_url = conf['tikzjax-url']
    and stringify(conf['tikzjax-url'])
    or 'https://tikzjax.com/v1'
  -- Strip a trailing slash so concatenation with /fonts.css and /tikzjax.js
  -- produces a single separator regardless of how the user wrote the URL.
  tikzjax_url = tikzjax_url:gsub('/+$', '')

  return {
    cache = image_cache and true,
    image_cache = image_cache,
    save_tex = save_tex,
    tex_dir = tex_dir,
    texinputs = build_texinputs(),
    tex_template_content = tex_template_content,
    tex_engine = tex_engine,
    svg_engine = svg_engine,
    svg_command = svg_command,
    output_format = out_format,
    renderer = renderer,
    latex_passthrough = latex_passthrough,
    tikzjax_url = tikzjax_url,
  }
end

-- Pure helpers, exercised by the suites under tests/. Exported as a global
-- rather than as a key on the returned table: Quarto only accepts integer keys
-- there and silently drops the whole filter if it finds anything else.
TIKZ_TEST = {
  canonical_options = canonical_options,
  compile_tikz_to_svg = compile_tikz_to_svg,
  write_file = write_file,
  hashable_code = hashable_code,
  code_part = code_part,
  match_loader_line = match_loader_line,
  split_libs = split_libs,
  prepare_passthrough_body = prepare_passthrough_body,
}

return {
  {
    Pandoc = function(doc)
      local conf = configure(doc.meta)
      local result = doc:walk {
        CodeBlock = code_to_figure(conf),
      }
      -- Emit the latex-passthrough preamble once the whole document has been
      -- seen, so its ordering is ours rather than the blocks' encounter order.
      flush_passthrough_preamble()
      return result
    end
  },
}
