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

-- Diagnostics. Quarto supplies `quarto.log`; plain pandoc does not, and this
-- filter is meant to work under both — `is_html_output` and `build_texinputs`
-- each carry an explicit plain-pandoc fallback. Diagnostics did not: every
-- `quarto.log.*` call site was unguarded, so under `pandoc --lua-filter` the
-- *first warning of any kind* aborted the filter with "attempt to index a nil
-- value (global 'quarto')" — including the warning that was trying to explain
-- a mistake in the user's own document.
--
-- Resolved per call rather than once at load time, because a host may install
-- the global after the chunk is loaded.
local function logger(level, prefix)
  return function(message)
    local sink = quarto and quarto.log and quarto.log[level]
    if sink then return sink(message) end
    io.stderr:write(prefix, ' (tikz.lua): ', tostring(message), '\n')
  end
end

local log = {
  warning = logger('warning', 'WARNING'),
  error = logger('error', 'ERROR'),
}

-- Add text to the host document's header. Two callers need this — the
-- latex-passthrough preamble and the TikZJax asset tags — and each used to
-- carry its own copy of the same fallback warning. `what` names the payload
-- so the message can say which one could not be hoisted.
local function include_in_header(text, what)
  if quarto and quarto.doc and quarto.doc.include_text then
    quarto.doc.include_text('in-header', text)
    return true
  end
  log.warning(
    "tikz: cannot add " .. what .. " to the document header automatically — " ..
    "quarto.doc.include_text unavailable. Add the following to your " ..
    "include-in-header manually:\n" .. text
  )
  return false
end

-- Whether `cmd` names something we could run, answered by searching PATH
-- ourselves and memoized for the render.
--
-- The check is worth keeping rather than folding into the first
-- `pandoc.pipe` failure, because it fails *fast*: on a machine that has TeX
-- but not Inkscape, a project with fifty diagrams should report a missing
-- converter fifty times without running LaTeX fifty times first.
--
-- What it replaces is `io.popen("command -v " .. cmd .. " 2>/dev/null")`,
-- which had three problems:
--
--   * It interpolated a metadata-controlled string into a shell command, so
--     `tex-engine` could name a pipeline rather than a program. Everywhere
--     else the filter runs external programs through `pandoc.pipe`, which
--     execs directly with no shell in between.
--   * `command -v` is a POSIX shell builtin. Under `cmd.exe` it is not a
--     command at all, so the probe always came back empty and *every*
--     Windows render reported "pdflatex not found on PATH" — despite the
--     Windows handling in `cachedir` and `build_texinputs`.
--   * It spawned a subprocess per diagram to answer a question whose answer
--     cannot change during a render.
local function readable(path)
  local fh = io.open(path, 'rb')
  if not fh then return false end
  fh:close()
  return true
end

local function find_executable(cmd)
  -- A name containing a separator is a path, not something to look up. Same
  -- rule a shell applies, and both separators are accepted because Windows
  -- takes either.
  if cmd:find('[/\\]') then return readable(cmd) end

  -- On Windows an executable is found by appending one of PATHEXT; on
  -- everything else the name is used as written.
  local suffixes = { '' }
  if pandoc.system.os == 'windows' then
    local pathext = os.getenv('PATHEXT') or '.COM;.EXE;.BAT;.CMD'
    for ext in pathext:gmatch('[^;]+') do
      suffixes[#suffixes + 1] = ext:lower()
    end
  end

  local sep = pandoc.path.search_path_separator
  for dir in (os.getenv('PATH') or ''):gmatch('[^' .. sep .. ']+') do
    for _, suffix in ipairs(suffixes) do
      if readable(pandoc.path.join { dir, cmd .. suffix }) then return true end
    end
  end
  return false
end

local executable_seen = {}

local function check_dependency(cmd)
  if executable_seen[cmd] == nil then
    executable_seen[cmd] = find_executable(cmd)
  end
  return executable_seen[cmd]
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

local tikzjax_assets_injected = false  -- Guards once-per-document injection of TikZJax JS/CSS.

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

-- One pass over a block's lines, answering both questions the filter asks
-- about `%%|` directives: what did the user set, and what is left once the
-- directives are gone. Returns the directives as a key -> value table, and the
-- code with every directive stripped.
--
-- That second value is what the compiler is handed, what the cache key is
-- taken over, and what the generated basename hashes. Dropping directives
-- before any of those is what keeps a presentation edit out of the cache key:
-- `%%|` lines are TeX comments, so removing them cannot change a rendered
-- byte, while every directive that does influence compilation is folded into
-- the options half of the key separately. (#28)
--
-- Stripping follows one rule: a directive truncates its line, and a line left
-- blank by the truncation is dropped, so an indented directive and an absent
-- one leave the same code behind.
--
-- Recognising a directive is deliberately separate from stripping one. A line
-- carrying `%%|` is always stripped, whether or not what follows parses as a
-- key — which is what stops the sub-lines of a stale nested block reappearing
-- as stray options.
--
-- A value is trimmed, and an empty one means unset.
local function split_directives(code)
  local props, kept = {}, {}
  for _, line in ipairs(split_lines(code)) do
    local before, directive = line:match('^(.-)%%%%|(.*)$')
    if not before then
      kept[#kept + 1] = line
    else
      local key, value = directive:match('^ ?([-_%w]+):%s*(.-)%s*$')
      if key and value ~= '' then props[key] = value end
      if not before:match('^%s*$') then kept[#kept + 1] = before end
    end
  end
  return props, table.concat(kept, '\n')
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

-- How a rendered SVG reaches an HTML page: as an `<img src=…>` reference
-- (the default) or as inline markup.
local KNOWN_EMBEDS = { img = true, inline = true }

-- PDF/DVI → SVG converters we know how to drive. `tikz.svg-command` is the
-- escape hatch for anything else; see `convert_command`.
local KNOWN_SVG_ENGINES = { inkscape = true, dvisvgm = true, pdftocairo = true }

-- Validate an option against its known values. Returns the value when it is
-- recognized and nil otherwise, so an unusable setting falls through to the
-- caller's next source: block directive → document metadata → built-in
-- default. `where` names the source for the message ("tikz.renderer",
-- "%%| embed:").
--
-- The message deliberately does not name the value it is falling back *to*.
-- It used to — "falling back to 'latex'", "falling back to 'img'" — but the
-- fallback belongs to the caller's chain, not to this function. With
-- `tikz: {renderer: tikzjax}` in the front-matter and a block-level
-- `%%| renderer: bogus`, the user was told they got latex and actually got
-- tikzjax.
local function normalize_enum(value, known, where, supported)
  if value == nil then return nil end
  local name = stringify(value)
  if known[name] then return name end
  -- What happens next depends on where the value came from: a `%%|`
  -- directive falls through to the document-level setting, a document-level
  -- setting to the built-in default. Naming a specific value here is what
  -- made the old message wrong — it said "falling back to 'latex'" even when
  -- the document had asked for tikzjax.
  local consequence = where:match('^tikz%.')
    and "the built-in default is used"
    or "the document-level setting applies (or the default, if there is none)"
  log.warning(
    "tikz: unknown " .. where .. " '" .. name .. "' — ignoring it, so " ..
    consequence .. ". Supported values: " .. supported .. "."
  )
  return nil
end

-- Renderer names, plus the migration for the one that used to be spelled
-- as a renderer and is now its own option.
local function normalize_renderer(value, where)
  if value ~= nil and stringify(value) == 'latex-passthrough' then
    log.warning(
      "tikz: " .. where .. " no longer takes 'latex-passthrough'. It is now a " ..
      "separate option, because it decides whether a block is rendered at all " ..
      "rather than how: set `latex-passthrough: true` and leave `renderer` " ..
      "saying how the block should be drawn on non-LaTeX outputs. Ignoring it."
    )
    return nil
  end
  return normalize_enum(value, KNOWN_RENDERERS, where, 'latex, tikzjax')
end

local function normalize_embed(value, where)
  return normalize_enum(value, KNOWN_EMBEDS, where, 'img, inline')
end

-- Per-block options, mapping the directive name a user writes to the key the
-- renderers read. Every one of these must be listed: the catch-all at the end
-- of the loop below turns an unrecognized attribute into an *image*
-- attribute, so anything omitted here silently becomes `<img embed="inline">`
-- rather than an option. Two of the entries used to be `elseif` branches
-- whose only content was a comment saying exactly that.
local BLOCK_OPTIONS = {
  additionalPackages = 'additional-packages',
  ['header-includes'] = 'header-includes',
  renderer = 'renderer',
  embed = 'embed',
  ['latex-passthrough'] = 'latex-passthrough',
}

-- Route a block's options to the things that consume them. `attribs` is the
-- directive table from `split_directives`, which this mutates by merging the
-- fence attributes in — it is built fresh per block, so there is nothing to
-- alias.
--
-- The `%%| key: value` comment directives are the canonical, current syntax
-- (and match Quarto's cell-options convention). Code-block fence attributes
-- (`{.tikz filename=…}`) are the deprecated pre-1.0 form. When a key is given
-- both ways, the %%| directive wins; we only let a fence attribute through if
-- the %%| form didn't set that key, and we warn on any genuine conflict so the
-- silent override becomes visible.
local function diagram_options(cb, attribs)
  for key, value in pairs(cb.attributes) do
    if attribs[key] == nil then
      attribs[key] = value
    elseif attribs[key] ~= value then
      log.warning(
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
  local fig_attr = { id = cb.identifier }
  local filename
  local image_attr = {}
  local user_opt = {}

  for attr_name, value in pairs(attribs) do
    local opt_key = BLOCK_OPTIONS[attr_name]
    if opt_key then
      user_opt[opt_key] = value
    elseif attr_name == 'alt' then
      alt = value
    elseif attr_name == 'caption' then
      -- Read caption attribute as Markdown
      caption = pandoc.read(value, 'markdown').blocks
    elseif attr_name == 'filename' then
      filename = value
    elseif attr_name == 'label' then
      fig_attr.id = value
    elseif attr_name == 'name' then
      fig_attr.name = value
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

-- Where a given diagram's cached file lives, or nil when caching is off.
--
-- `dir` is passed in rather than read from an upvalue: the cache directory
-- used to live in a module-level `image_cache` *and* be copied into `conf`,
-- so there were two places to look and only one of them was ever read.
local function cache_path(dir, basename, hash, options, format)
  if not dir then return nil end
  return pandoc.path.join {
    dir, cache_filename(basename, hash, options, format),
  }
end

local function get_cached_image(dir, basename, hash, options, format)
  local path = cache_path(dir, basename, hash, options, format)
  local imgdata = path and read_file(path)
  if imgdata then
    return imgdata, mime_for_format(format)
  end
  return nil
end

local function cache_image(dir, basename, hash, options, imgdata, format)
  local path = cache_path(dir, basename, hash, options, format)
  if path then write_file(path, imgdata) end
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
  include_in_header(table.concat(parts, '\n'), 'the latex-passthrough preamble')
end

-- Treat an empty attribute (pandoc gives an unlabelled block `identifier = ''`)
-- as absent, so it can fall through to the next naming candidate.
local function blank_to_nil(s)
  if s == nil or s == '' then return nil end
  return s
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
-- preamble. The `%%|` option directives are already gone — `split_directives`
-- removes them before any renderer sees the code, so this no longer carries
-- its own third opinion about what one looks like. Returns the preamble lines,
-- the remaining body, and any warnings.
--
-- Two passes, because how a load is written decides what we may do with it:
--
--   1. A line that is *exactly* one loader call, outside any `tikzpicture`,
--      is **moved** — hoisted and removed from the body. This is the
--      overwhelmingly common shape and it keeps the shipped `.tex` tidy.
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
--
-- Pass 1 tracks `tikzpicture` depth for exactly that reason. It used to run
-- before any depth was known, so an own-line loader *inside* a picture was
-- silently moved — the one case the paragraph above promises to leave alone,
-- and the one where moving it is most likely to be wrong:
--
--     \node {
--     \usetikzlibrary{arrows}
--     };
--
-- is literal content on its own line. Deleting it changes the drawing and
-- adds a preamble line nobody asked for. Pass 2 already refused the same
-- construct when it shared a line with other code; the two passes now agree.
local function prepare_passthrough_body(code)
  local preamble, body, warns = {}, {}, {}

  local outer_depth = 0
  for _, line in ipairs(split_lines(code)) do
    local macro, arg = match_loader_line(line)
    if macro and outer_depth == 0 then
      for _, name in ipairs(split_libs(arg)) do
        preamble[#preamble + 1] = '\\' .. macro .. '{' .. name .. '}'
      end
    else
      -- Kept, including a loader inside a picture: pass 2 sees it and warns.
      body[#body + 1] = line
    end
    for _, m in ipairs(picture_markers(code_part(line))) do
      outer_depth = outer_depth + m.delta
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
          " inside a tikzpicture is left alone; move it above " ..
          "\\begin{tikzpicture} if it is meant to load a library: " .. line
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

-- The two option values every renderer prepends to its LaTeX. Stringified
-- because a `%%|` directive always arrives as text while document metadata
-- arrives as Inlines, and absent because "unset" and "empty" mean the same
-- thing here.
local function preamble_parts(user_opts)
  return stringify(user_opts['additional-packages'] or ''),
    stringify(user_opts['header-includes'] or '')
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
  local additional, headers = preamble_parts(user_opts)
  hoist(PASSTHROUGH_PACKAGES, '\\usepackage{tikz}')
  hoist(PASSTHROUGH_PACKAGES, additional)
  hoist(PASSTHROUGH_HEADERS, headers)
  local preamble, body, warns = prepare_passthrough_body(code)
  for _, text in ipairs(preamble) do
    hoist(PASSTHROUGH_LIBRARIES, text)
  end
  if #warns > 0 then
    log.warning(
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
  include_in_header(html, 'the TikZJax assets')
end

-- Build a `<script type="text/tikz">` block for client-side rendering by
-- TikZJax. The user's tikzpicture is wrapped in \begin{document}…\end{document}
-- (TikZJax provides \documentclass{standalone} itself), with any
-- additionalPackages / header-includes prepended so the same `.tikz` source
-- works under either renderer.
local function embed_tikzjax(code, user_opts, conf)
  inject_tikzjax_assets(conf)
  local additional, headers = preamble_parts(user_opts)
  local prelude_parts = {}
  if additional ~= '' then table.insert(prelude_parts, additional) end
  if headers ~= '' then table.insert(prelude_parts, headers) end
  local prelude = table.concat(prelude_parts, '\n')
  local body = (prelude ~= '' and (prelude .. '\n') or '') ..
    '\\begin{document}\n' .. code .. '\n\\end{document}'
  return pandoc.RawBlock('html',
    '<script type="text/tikz">\n' .. body .. '\n</script>')
end

-- True when the output really is an HTML-family format (html, revealjs, …),
-- as opposed to merely "not PDF" — docx also renders through the SVG path but
-- needs a real image file.
local function is_html_output()
  return (quarto and quarto.doc and quarto.doc.is_format
           and quarto.doc.is_format('html:js'))
    or (FORMAT and FORMAT:match('^html') ~= nil)
end

-- Counter giving each inlined SVG on a page its own namespace. A counter
-- rather than the cache key, because two *identical* diagrams share a key and
-- would then share ids as well.
local inline_svg_seq = 0

-- Escape a string for use as a Lua pattern / as a gsub replacement.
local function pat_escape(s) return (s:gsub('(%W)', '%%%1')) end
local function rep_escape(s) return (s:gsub('%%', '%%%%')) end

-- Rewrite an SVG so it can be dropped into an HTML page beside others.
--
-- Inside an `<img>` an SVG is its own document: its ids, CSS classes and
-- `@font-face` families are sandboxed. Inlined, they are page-global, and
-- every converter we support emits names that repeat from diagram to diagram.
-- Verified in a browser, two diagrams per page:
--
--   * pdftocairo — worst. `<use xlink:href="#glyph-0-0">` resolves to the
--     *first* diagram's glyph definitions, so a picture reading "Hello" alone
--     renders as "W X αα" beside another. `url(#clip-0)` misbinds the same way.
--   * dvisvgm — `text.f0` is redefined per diagram, so labels take a later
--     diagram's font and size: 24.8px where 9.96px was meant.
--   * dvisvgm also declares `@font-face{font-family:cmmi10}` in every diagram
--     with a *different* embedded subset each time. Chrome happens to fall
--     back across same-family faces, so this one does not currently show —
--     but nothing guarantees that, and namespacing it is free.
--
-- So all three name kinds are suffixed with a per-diagram nonce, and every
-- reference form is rewritten in step: `url(#…)`, `href="#…"` and
-- `xlink:href="#…"` (cairo uses two of the three).
local function namespace_svg(svg, nonce, alt)
  -- An inlined SVG is an element, not a document: drop the XML prolog,
  -- any DOCTYPE, and the generator comments that precede the root tag.
  local root = svg:find('<svg', 1, true)
  if not root then return nil end
  svg = svg:sub(root)

  local function rename(names, rewrites)
    for name in pairs(names) do
      -- `from` is spliced into a pattern by an inner gsub, so it has to survive
      -- being a *replacement* first: pat_escape('glyph-0-0') is 'glyph%-0%-0',
      -- and a bare '%-' in a replacement string is an error.
      local from = rep_escape(pat_escape(name))
      local to = rep_escape(rep_escape(name .. '-' .. nonce))
      for _, r in ipairs(rewrites) do
        svg = svg:gsub(r[1]:gsub('@', from), (r[2]:gsub('@', to)))
      end
    end
  end

  -- ids, and the three ways one SVG refers to another element. The patterns
  -- are anchored on the closing quote or paren, so an id that is a prefix of
  -- another (`clip-0` inside `clip-01`) cannot be partially rewritten.
  local ids = {}
  for q, name in svg:gmatch('id%s*=%s*(["\'])(.-)%1') do
    if name ~= '' then ids[name] = true end
  end
  rename(ids, {
    { '(id%s*=%s*["\'])@(["\'])',   '%1@%2' },
    { 'url%(#@%)',                  'url(#@)' },
    { '(href%s*=%s*["\'])#@(["\'])', '%1#@%2' },
  })

  -- CSS class names: the `class='f0'` attribute and the `.f0 {` selector.
  -- Only single-class attributes are matched; no converter we support emits
  -- multiple classes on one element.
  local classes = {}
  for name in svg:gmatch('class%s*=%s*["\']([%w_%-]+)["\']') do classes[name] = true end
  rename(classes, {
    { '(class%s*=%s*["\'])@(["\'])', '%1@%2' },
    { '(%.)@(%s*{)',                 '%1@%2' },
  })

  -- `@font-face` families, and both ways a family is referenced.
  local families = {}
  for name in svg:gmatch('@font%-face%s*{%s*font%-family%s*:%s*([%w_%-]+)') do
    families[name] = true
  end
  rename(families, {
    { '(font%-family%s*:%s*)@([;}])',       '%1@%2' },
    { '(font%-family%s*=%s*["\'])@(["\'])', '%1@%2' },
  })

  -- Give the page a styling hook, and the accessibility tree a name. `<title>`
  -- rather than `role="img"` + `aria-label`, which would hide the very text
  -- that inlining exists to expose.
  local head, rest = svg:match('^(<svg[^>]*>)(.*)$')
  if head then
    -- Added after the renaming pass, so the hook is a stable page-wide
    -- selector rather than another namespaced name. A class already on the
    -- root has been namespaced like any other by this point; keep it and
    -- append, rather than replacing what the converter put there.
    local existing = head:match('class%s*=%s*["\']([^"\']*)["\']')
    if existing then
      -- Pattern built by concatenation, so only pat_escape here; the
      -- replacement half still needs rep_escape.
      head = head:gsub('(class%s*=%s*["\'])' .. pat_escape(existing),
                       '%1' .. rep_escape(existing) .. ' tikz-svg', 1)
    else
      head = head:gsub('^<svg', '<svg class="tikz-svg"', 1)
    end
    local title = alt and stringify(alt) or ''
    if title ~= '' then
      title = title:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
      head = head .. '<title>' .. title .. '</title>'
    end
    svg = head .. rest
  end
  return svg
end

-- What the TeX run has to leave behind for the SVG converter to read.
--
-- Only `dvisvgm` consumes a DVI, and only when it is the converter that will
-- actually run. `svg-command` takes precedence over `svg-engine` at
-- conversion time, and its `{input}` is documented as the intermediate PDF,
-- so a custom command always gets a PDF. Deciding this from `svg_engine`
-- alone was the bug: `svg-engine: dvisvgm` together with `svg-command:` asked
-- the TeX engine for DVI and then handed the converter an `{input}` naming a
-- PDF that was never written, failing with a missing-file error that named
-- neither cause.
local function intermediate_format(svg_engine, svg_command)
  if svg_command then return 'pdf' end
  if svg_engine == 'dvisvgm' then return 'dvi' end
  return 'pdf'
end

-- The bundled standalone template, used unless `tikz.tex-template` supplies
-- one. The documentclass loads TikZ, so the block only has to add whatever
-- the user asked for.
local DEFAULT_TEX_TEMPLATE = [[
\documentclass[tikz]{standalone}
% \usepackage{tikz} % already loaded by the documentclass
$additional-packages$
$for(header-includes)$
$it$
$endfor$
\begin{document}
$body$
\end{document}
]]

-- Render one block into a complete standalone LaTeX document.
local function build_tex_document(code, user_opts, template_content)
  local template = pandoc.template.compile(template_content or DEFAULT_TEX_TEMPLATE)
  local additional, headers = preamble_parts(user_opts)
  local meta = {
    ['header-includes'] = { pandoc.RawInline('latex', headers) },
    ['additional-packages'] = { pandoc.RawInline('latex', additional) },
  }
  return pandoc.write(
    pandoc.Pandoc({ pandoc.RawBlock('latex', code) }, meta),
    'latex',
    { template = template }
  )
end

-- The converter to run, and its arguments, for one diagram's intermediate
-- files. Split out so the dispatch can be read — and tested — without a TeX
-- installation; it is also where `svg-command` overriding `svg-engine` is
-- decided, which is the pairing that used to disagree with the DVI request.
--
-- `files` carries the paths the TeX run produced or is expected to produce:
-- `pdf`, `dvi`, `svg`.
local function convert_command(conf, files)
  if conf.svg_command then
    -- Element 1 is the executable; the rest are its arguments, with
    -- {input}/{output} substituted. rep_escape because these are gsub
    -- *replacements*: a '%' in a user-supplied `filename` would otherwise be
    -- read as a capture reference.
    local args = {}
    for i = 2, #conf.svg_command do
      args[#args + 1] = conf.svg_command[i]
        :gsub('{input}', rep_escape(files.pdf))
        :gsub('{output}', rep_escape(files.svg))
    end
    return conf.svg_command[1], args
  end

  if conf.svg_engine == 'dvisvgm' then
    -- dvisvgm reads DVI directly. --font-format=woff embeds fonts as WOFF
    -- (instead of converting glyphs to paths), which keeps text selectable /
    -- styleable in the rendered SVG — the thing `embed: inline` exists to
    -- expose. Note: dvisvgm must be the TeX-Live-integrated build (e.g. via
    -- tlmgr); standalone packages can fail to find the PostScript prologue
    -- files.
    return 'dvisvgm', { '--font-format=woff', '-o', files.svg, files.dvi }
  end

  if conf.svg_engine == 'pdftocairo' then
    -- pdftocairo (poppler-utils) reads PDF and is widely available; a good
    -- lightweight alternative to Inkscape where Inkscape isn't installed.
    return 'pdftocairo', { '-svg', files.pdf, files.svg }
  end

  -- Inkscape default. Note: --pages=N (Inkscape 1.2+) is omitted because the
  -- standalone class always produces a single-page PDF, and dropping it
  -- preserves compatibility with Inkscape 1.0/1.1 (issue #4).
  return 'inkscape', {
    '--export-area-drawing',
    '--export-type=svg',
    '--export-plain-svg',
    '--export-margin=0',
    '--export-filename=' .. files.svg,
    files.pdf,
  }
end

-- How every renderer finishes: a captioned block becomes a `pandoc.Figure`
-- so that `%%| caption:` and `fig-attr` behave identically whichever renderer
-- drew it, and an uncaptioned one is emitted bare — no float, no centring,
-- placement left to the caller.
--
-- The only thing that differed between the four copies of this was whether
-- the content was already a Block. Three renderers produce a `RawBlock`,
-- which `Figure` takes directly; the `<img>` path produces an `Image`, which
-- is an Inline and needs a `Plain` around it. That is now handled here rather
-- than restated at each return.
local function as_figure(content, dgr_opt)
  local block = content.t == 'Image' and pandoc.Plain { content } or content
  if not dgr_opt.caption then return block end
  return pandoc.Figure({ block }, dgr_opt.caption, dgr_opt['fig-attr'])
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
local function compile_tikz_to_svg(code, user_opts, conf, basename)
  -- Ensure required dependencies are available
  if not check_dependency(conf.tex_engine) then
    return nil, conf.tex_engine .. " not found. Install it, or set " ..
      "tikz.tex-engine to a TeX engine you do have (pdflatex, lualatex, " ..
      "xelatex, …)."
  end
  -- The svg converter is only needed when we actually convert to SVG. For
  -- PDF output we embed the intermediate PDF directly and nothing here is
  -- invoked.
  local base_filename = basename or "tikz-image"
  local files = {
    tex = base_filename .. ".tex",
    pdf = base_filename .. ".pdf",
    svg = base_filename .. ".svg",
    dvi = base_filename .. ".dvi",
    log = base_filename .. ".log",
  }
  local convert_cmd, convert_args = convert_command(conf, files)
  if conf.image_format ~= 'pdf' and not check_dependency(convert_cmd) then
    return nil, convert_cmd .. " not found. Install it (it is the configured " ..
      "SVG converter), or set tikz.svg-engine / tikz.svg-command to one you " ..
      "do have."
  end

  local function process_in_dir(dir)
    return with_working_directory(dir, function()
      write_file(
        files.tex,
        build_tex_document(code, user_opts, conf.tex_template_content)
      )

      -- Execute the LaTeX compiler with TEXINPUTS so blocks can \input or
      -- \usepackage shared files from the qmd directory or the extension dir.
      -- with_environment replaces the entire env, so we merge our override
      -- onto a copy of the current env to preserve PATH and friends.
      local env = pandoc.system.environment()
      env.TEXINPUTS = conf.texinputs
      -- Ask for DVI only when the converter we are actually going to run
      -- consumes one; every other path reads the default PDF output. See
      -- `intermediate_format`.
      local latex_args = { '-interaction=nonstopmode' }
      if conf.intermediate == 'dvi' then
        table.insert(latex_args, '-output-format=dvi')
      end
      table.insert(latex_args, files.tex)
      local success, latex_result = pcall(function()
        return pandoc.system.with_environment(env, function()
          return pandoc.pipe(conf.tex_engine, latex_args, '')
        end)
      end)
      if not success then
        return nil, "Error compiling TikZ figure '" .. base_filename .. "':\n" ..
          tostring(latex_result) .. "\nLaTeX Log:\n" ..
          (read_file(files.log) or "") .. "\nTikZ Code:\n" .. code
      end

      -- For PDF output, embed the intermediate PDF directly — no SVG
      -- conversion needed. This skips the Inkscape rasterization round-trip
      -- and preserves vector fidelity / fonts in the rendered PDF.
      if conf.image_format == 'pdf' then
        local imgdata = read_file(files.pdf)
        if not imgdata then
          return nil, "Failed to read generated PDF file for TikZ figure '" ..
            base_filename .. "'.\nTikZ Code:\n" .. code
        end
        return imgdata, 'application/pdf'
      end

      -- Convert TeX output to SVG with the command chosen above.
      local success_convert, convert_result = pcall(
        pandoc.pipe, convert_cmd, convert_args, ''
      )
      if not success_convert then
        return nil, "Error converting to SVG (command: " .. convert_cmd ..
          ") for TikZ figure '" .. base_filename .. "':\n" ..
          tostring(convert_result) .. "\nTikZ Code:\n" .. code
      end

      -- Read the SVG file
      local imgdata = read_file(files.svg)
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

-- Resolve the three orthogonal per-block axes, and derive the cache key.
--
-- The axes are independent by construction:
--
--   * `renderer`           — *how* a block is drawn when we have to draw it:
--                            'latex' (the TeX + svg-engine chain) or
--                            'tikzjax' (a <script type="text/tikz"> the
--                            reader's browser renders).
--   * `latex-passthrough`  — *whether* to draw it at all. Under LaTeX output
--                            the host document can typeset the picture
--                            itself, so we hand over the source. Deliberately
--                            not a renderer value: it applies to exactly one
--                            output family, and on every other format
--                            `renderer` already says what should happen.
--   * `embed`              — how a rendered SVG reaches an HTML page. Changes
--                            the delivery, never the bytes.
--
-- `key_opts` is a *separate table*, not `user_opt` with keys deleted from it.
-- That distinction is the whole point of this function. The old code mutated
-- one table that served as both compiler options and cache-key material, so
-- every axis had to remember to erase its own raw directive text before the
-- key was taken. `embed` and `latex-passthrough` remembered; `renderer` did
-- not, and a no-op `%%| renderer: latex` therefore produced a second cache
-- entry for a byte-identical image — as did any value that had already been
-- warned about and discarded. That is the #28 failure again: a presentation
-- level edit orphaning a committed cache entry, invisible on a machine with
-- TeX and fatal on a build host without one.
--
-- Building the key from the *resolved* values instead makes that class of bug
-- unreachable: a raw directive can only reach the key by being copied there.
local function resolve_axes(user_opt, conf)
  local renderer = normalize_renderer(user_opt['renderer'], '%%| renderer:')
    or conf.renderer or 'latex'

  local passthrough = user_opt['latex-passthrough']
  if passthrough ~= nil then
    local parsed = truthy(passthrough)
    if parsed == nil then
      log.warning(
        "tikz: %%| latex-passthrough: expects true or false, got '" ..
        stringify(passthrough) .. "'. Ignoring it."
      )
    end
    passthrough = parsed
  end
  if passthrough == nil then passthrough = conf.latex_passthrough end

  local embed = normalize_embed(user_opt['embed'], '%%| embed:')
    or conf.embed or 'img'

  -- Everything that influences the rendered bytes, and nothing else.
  local key_opts = {}
  for k, v in pairs(user_opt) do key_opts[k] = v end
  -- The three axes are re-added below as resolved values, or not at all.
  key_opts['renderer'] = nil
  key_opts['embed'] = nil
  key_opts['latex-passthrough'] = nil
  -- `renderer` only when non-default, so cache entries written before it
  -- existed as a key stay valid. `embed` and `latex-passthrough` never: the
  -- first changes only the delivery of bytes already rendered, and under the
  -- second nothing is cached at all.
  if renderer ~= 'latex' then key_opts['renderer'] = renderer end
  -- Doc-level settings that do change the bytes, so that editing the template
  -- or switching engines invalidates what they produced.
  if conf.tex_template_content then
    key_opts['tex-template-hash'] = pandoc.sha1(conf.tex_template_content)
  end
  key_opts['tex-engine'] = conf.tex_engine
  key_opts['svg-engine'] = conf.svg_engine
  if conf.svg_command then
    key_opts['svg-command'] = table.concat(conf.svg_command, ' ')
  end

  return renderer, passthrough, embed, key_opts
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

    -- Parse the block once. `code` is the text with every `%%|` directive
    -- stripped: what the renderers compile, and — as `hash` below — what the
    -- cache key and the generated basename are taken over.
    local directives, code = split_directives(block.text)
    local dgr_opt = diagram_options(block, directives)
    local renderer, passthrough, embed, key_opts = resolve_axes(dgr_opt.opt, conf)
    -- The other half of the split: what the renderers read. Only
    -- `additional-packages` and `header-includes` are consulted, so the
    -- resolved axes are deliberately absent — they steer the dispatch below,
    -- not the LaTeX that comes out of it.
    local compile_opts = dgr_opt.opt

    -- LaTeX passthrough: emit the TikZ source itself, letting the host
    -- document typeset it. Gated on the output really being LaTeX, so the
    -- SVG/HTML paths are untouched and a document can carry the flag
    -- project-wide while still building HTML with whatever `renderer` says.
    --
    -- Checked before the renderers, because it decides *whether* to render:
    -- a `renderer: tikzjax` document with passthrough on must hand its source
    -- to a LaTeX build, not fall into tikzjax's drop-for-non-HTML rule.
    if passthrough and conf.host_is_latex then
      local raw = embed_latex_passthrough(
        code, compile_opts,
        dgr_opt.filename or blank_to_nil(dgr_opt['fig-attr'].id) or '<unnamed>'
      )
      return as_figure(raw, dgr_opt)
    end

    -- TikZJax path: emit a <script type="text/tikz"> block for the reader's
    -- browser to render. Only meaningful for HTML-based output (html,
    -- revealjs, etc.); for anything else, warn and drop the block.
    if renderer == 'tikzjax' then
      if not is_html_output() then
        log.warning(
          "tikz: renderer 'tikzjax' only renders to HTML; dropping block " ..
          "for format '" .. tostring(FORMAT) .. "'. " ..
          "Set renderer: latex (or remove the override) to render this " ..
          "block under non-HTML output."
        )
        return {}  -- remove the block from the output entirely
      end
      return as_figure(embed_tikzjax(code, compile_opts, conf), dgr_opt)
    end

    -- The stripped code is the basis for both the generated basename and the
    -- cache key, so the two cannot drift apart.
    local hash = code
    local basename = dgr_opt.filename or pandoc.sha1(hash)

    -- Check if image is cached
    local imgdata, imgtype = nil, nil
    local image_format = conf.image_format
    imgdata, imgtype = get_cached_image(
      conf.image_cache, basename, hash, key_opts, image_format)

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
        return compile_tikz_to_svg(code, compile_opts, conf, basename)
      end)
      local failure
      if not ok then
        failure = tostring(result)
      elseif not result then
        failure = extra or "no image data was produced"
      end
      if failure then
        log.error(
          "tikz: could not render figure '" .. basename .. "', leaving the " ..
          "block unrendered.\n" .. failure
        )
        return nil -- Return the original block unchanged
      end
      -- pcall returns (true, returned_values...) on success; result is the
      -- imgdata, extra is the MIME string returned by compile_tikz_to_svg.
      imgdata, imgtype = result, extra or mime_for_format(image_format)

      -- Cache the image
      cache_image(conf.image_cache, basename, hash, key_opts, imgdata, image_format)
    end

    -- Inline embedding: hand the SVG to the page as markup instead of
    -- referencing a file. A browser renders an `<img>`-referenced SVG in
    -- secure static mode — the document inside is walled off, so its labels
    -- are unselectable, invisible to find-in-page and to screen readers, and
    -- unreachable by the page's CSS. Inlining is what makes `svg-engine:
    -- dvisvgm` worth choosing: its real `<text>` elements only pay off here.
    --
    -- Restricted to HTML output. `image_format` is 'svg' for everything that
    -- is not LaTeX, docx included, and docx needs a genuine image file. (#27)
    if embed == 'inline' and image_format == 'svg' and is_html_output() then
      inline_svg_seq = inline_svg_seq + 1
      local markup = namespace_svg(imgdata, 'tikz' .. inline_svg_seq, dgr_opt.alt)
      if markup then
        return as_figure(pandoc.RawBlock('html', markup), dgr_opt)
      end
      log.warning(
        "tikz: could not inline figure '" .. basename .. "' (no <svg> root " ..
        "in the converter's output); falling back to an <img> reference."
      )
    end

    -- Use the block's filename attribute or create a new name by hashing the image content.
    local fname = basename .. '.' .. image_format

    -- Store the data in the mediabag:
    pandoc.mediabag.insert(fname, imgtype, imgdata)

    return as_figure(
      pandoc.Image(dgr_opt.alt, fname, "", dgr_opt['image-attr']), dgr_opt)
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

-- Reading one document-level option. Metadata values arrive as Inlines or as
-- MetaBool, never as plain Lua strings, so every one of these needed the
-- same `x and stringify(x) or default` dance — repeated five times, with the
-- subtlety that an *explicitly empty* value and an absent one are different
-- things to some callers.
local function meta_string(conf, name, default)
  local value = conf[name]
  if value == nil then return default end
  return stringify(value)
end

-- …and one that must be drawn from a fixed set. `normalize_enum` already
-- does this for the per-block axes; this is the document-level half, which
-- differs only in wanting the default substituted rather than nil returned.
local function meta_enum(conf, name, known, default, supported)
  local value = meta_string(conf, name, nil)
  if value == nil then return default end
  return normalize_enum(value, known, 'tikz.' .. name, supported) or default
end

-- Function to configure the filter based on document metadata. Reads
-- top-level `tikz:` config and produces a normalized `conf` table that the
-- per-block code path consumes.
local function configure (meta)
  local conf = meta.tikz or {}
  meta.tikz = nil  -- Remove tikz metadata to avoid processing it further

  -- cache for image files
  local image_cache = nil
  if conf.cache == true then
    image_cache = conf['cache-dir']
      and stringify(conf['cache-dir'])
      or cachedir()
    if image_cache then
      pandoc.system.make_directory(image_cache, true)
    end
  end

  -- Handle save-tex option
  local save_tex = conf['save-tex'] or false
  local tex_dir = nil
  if save_tex then
    if image_cache then
      -- Both cache and save-tex are enabled; raise a warning and disable save-tex
      log.warning("Both 'cache' and 'save-tex' are enabled. Disabling 'save-tex' since caching is active.")
      save_tex = false
    else
      tex_dir = meta_string(conf, 'tex-dir', 'tikz-tex')
      pandoc.system.make_directory(tex_dir, true)
    end
  end

  -- Custom LaTeX standalone template. Read once at filter setup so we don't
  -- pay file I/O per diagram, and so the path resolves against the qmd's
  -- cwd before with_working_directory changes it.
  local tex_template_content = nil
  local tex_template = meta_string(conf, 'tex-template', nil)
  if tex_template then
    local tex_template_path = absolutize(tex_template)
    tex_template_content = read_file(tex_template_path)
    if not tex_template_content then
      log.error(
        "tikz: tex-template not found: " .. tostring(tex_template_path) ..
        " — falling back to the default template."
      )
    end
  end

  -- TeX engine. Defaults to pdflatex (the historical behaviour). Users who
  -- need lualatex/xelatex (e.g. for fontspec, complex Unicode scripts) can
  -- opt in. Anything matching an executable on PATH is accepted.
  local tex_engine = meta_string(conf, 'tex-engine', 'pdflatex')

  -- SVG engine. Choices:
  --   inkscape   — default. Consumes the PDF produced by pdflatex.
  --   pdftocairo — poppler-utils. Lightweight alternative to inkscape;
  --                also consumes the PDF.
  --   dvisvgm    — consumes a DVI (we ask pdflatex for -output-format=dvi
  --                in that case). Embeds fonts as WOFF so text in the
  --                rendered SVG stays selectable.
  local svg_engine = meta_enum(conf, 'svg-engine', KNOWN_SVG_ENGINES,
    'inkscape', 'inkscape, dvisvgm, pdftocairo')

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
        parts[#parts + 1] = stringify(item)
      end
    else
      local s = stringify(svg_command_raw)
      for word in s:gmatch('%S+') do
        parts[#parts + 1] = word
      end
    end
    if #parts > 0 then
      svg_command = parts
    else
      log.warning("tikz: svg-command is empty; ignoring.")
    end
  end

  local intermediate = intermediate_format(svg_engine, svg_command)
  -- Setting both is a configuration mistake rather than a layered override,
  -- so say which one is being ignored instead of silently picking.
  if svg_command and conf['svg-engine'] then
    log.warning(
      "tikz: both svg-command and svg-engine are set; svg-command wins and " ..
      "svg-engine '" .. svg_engine .. "' is ignored." ..
      (svg_engine == 'dvisvgm'
        and " In particular the TeX run still produces a PDF, which is what " ..
            "{input} names — dvisvgm's DVI input is not available to a custom " ..
            "command. Remove one of the two settings."
        or " Remove one of the two settings to silence this warning.")
    )
  end

  -- Is the host document LaTeX? True for `format: pdf`, `beamer` and
  -- `format: latex` alike (verified: `is_format('pdf')` answers yes to all
  -- three), which is what `latex-passthrough` needs to know.
  local host_is_latex = (quarto and quarto.doc and quarto.doc.is_format
    and quarto.doc.is_format('pdf')) or false

  -- What we produce for that host: the intermediate PDF embedded directly
  -- under LaTeX, an SVG everywhere else. Doubles as the file extension.
  --
  -- Two questions, one variable, until now. `output_format == 'pdf'` was
  -- read in three places to mean "embed the PDF", "skip the SVG converter"
  -- and "the host is LaTeX, so passthrough applies" — three different
  -- questions that happen to share an answer. Naming them separately costs
  -- one field and stops the next reader having to work out which sense is
  -- meant at each site.
  local image_format = host_is_latex and 'pdf' or 'svg'

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
    log.warning(
      "tikz: latex-passthrough expects true or false, got '" ..
      stringify(conf['latex-passthrough']) .. "'. Treating it as false."
    )
  end
  latex_passthrough = latex_passthrough or false

  -- Delivery of the rendered SVG under HTML output: 'img' (default) keeps the
  -- historical `<img src=…>` reference; 'inline' emits the SVG as markup.
  local embed = normalize_embed(conf.embed, 'tikz.embed') or 'img'

  -- Base URL serving tikzjax.js and fonts.css. Defaults to the canonical
  -- tikzjax.com CDN; users can self-host or pin a fork (e.g. drgrice1's).
  local tikzjax_url = meta_string(conf, 'tikzjax-url', 'https://tikzjax.com/v1')
  -- Strip a trailing slash so concatenation with /fonts.css and /tikzjax.js
  -- produces a single separator regardless of how the user wrote the URL.
  tikzjax_url = tikzjax_url:gsub('/+$', '')

  return {
    image_cache = image_cache,
    save_tex = save_tex,
    tex_dir = tex_dir,
    texinputs = build_texinputs(),
    tex_template_content = tex_template_content,
    tex_engine = tex_engine,
    svg_engine = svg_engine,
    svg_command = svg_command,
    intermediate = intermediate,
    host_is_latex = host_is_latex,
    image_format = image_format,
    renderer = renderer,
    latex_passthrough = latex_passthrough,
    embed = embed,
    tikzjax_url = tikzjax_url,
  }
end

-- Helpers exercised by the suites under tests/. Mostly pure; the two that are
-- not (`compile_tikz_to_svg`, `write_file`) are here because their *failure*
-- paths are what the tests care about, and those are reached before any I/O.
--
-- Exported as a global rather than as a key on the returned table: Quarto
-- only accepts integer keys there and silently drops the whole filter if it
-- finds anything else.
TIKZ_TEST = {
  canonical_options = canonical_options,
  namespace_svg = namespace_svg,
  compile_tikz_to_svg = compile_tikz_to_svg,
  write_file = write_file,
  split_directives = split_directives,
  diagram_options = diagram_options,
  code_part = code_part,
  match_loader_line = match_loader_line,
  meta_string = meta_string,
  meta_enum = meta_enum,
  convert_command = convert_command,
  build_tex_document = build_tex_document,
  as_figure = as_figure,
  cache_filename = cache_filename,
  intermediate_format = intermediate_format,
  check_dependency = check_dependency,
  find_executable = find_executable,
  resolve_axes = resolve_axes,
  normalize_renderer = normalize_renderer,
  normalize_embed = normalize_embed,
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
