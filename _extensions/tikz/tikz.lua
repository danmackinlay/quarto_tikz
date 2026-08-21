--[[
tikz.lua - A Lua filter to process TikZ code blocks and generate figures.

Based on the style of 'quarto_diagram/diagram.lua', adapted for TikZ diagrams.
]]

PANDOC_VERSION:must_be_at_least '3.0'

-- `pandoc` is a global in a filter; these are the members used often enough
-- to be worth a short name.
local stringify = pandoc.utils.stringify
local with_temporary_directory = pandoc.system.with_temporary_directory
local with_working_directory = pandoc.system.with_working_directory

-- Functions to read and write files
local function read_file (filepath)
  local fh = io.open(filepath, 'rb')
  if not fh then return nil end
  local contents = fh:read('a')
  fh:close()
  return contents
end

local function write_file (filepath, content)
  -- Refuse a nil payload rather than letting `fh:write` raise: that traceback
  -- is a genuine runtime error and would abort the whole render.
  if content == nil then return false end
  local fh = io.open(filepath, 'wb')
  if not fh then return false end
  fh:write(content)
  fh:close()
  return true
end

-- Diagnostics. Quarto supplies `quarto.log`; plain pandoc does not, and this
-- filter must work under both, so every call site goes through here. The sink
-- is resolved per call rather than once at load time, because a host may
-- install the global after the chunk is loaded.
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

-- Whether `cmd` names something we could run: PATH is searched here rather
-- than by asking a shell, because `cmd` is metadata-controlled and must never
-- be interpolated into a shell command, and because `command -v` does not
-- exist under `cmd.exe`. Memoized for the render — no document can change
-- what is on PATH.
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
    local user_home = pandoc.system.os == 'windows'
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

-- State belonging to one document, cleared at the top of the walk, so a host
-- that filters two documents in one process does not carry the first
-- document's guards into the second. (`executable_seen` above is deliberately
-- not here: what is on PATH outlives any one document.)
local doc_state
local function reset_document_state()
  doc_state = {
    tikzjax_assets_injected = false,  -- Once-per-document TikZJax JS/CSS.
    -- Preamble text hoisted by latex-passthrough, in three ordered buckets and
    -- flushed once at the end of the walk. Bucket order rather than encounter
    -- order guarantees a `\usepackage{pgfplots}` from one block precedes a
    -- `\usepgfplotslibrary{…}` hoisted out of another.
    passthrough_preamble = { {}, {}, {} },
    passthrough_header_seen = {},     -- Text already queued, so we emit it once.
    inline_svg_seq = 0,               -- Namespaces each inlined SVG on the page.
  }
end
reset_document_state()

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
-- taken over, and what the generated basename hashes — so a presentation edit
-- stays out of the key. `%%|` lines are TeX comments and cannot change a
-- rendered byte; the directives that do influence compilation are folded into
-- the options half of the key separately.
--
-- Three rules hold the whole parser together:
--   * A directive truncates its line, and a line left blank by the truncation
--     is dropped, so an indented directive and an absent one leave the same
--     code behind.
--   * A line carrying `%%|` is stripped whether or not what follows parses as
--     a key, so the sub-lines of a stale nested block cannot reappear as
--     stray options.
--   * A value is trimmed, and an empty one means unset.
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

-- Every option the filter accepts, declared once and read through one reader,
-- so that a value means the same thing wherever it was written.
--
-- Fields:
--   type    'string' | 'bool' | 'enum' | 'list'
--   values  for enums, in the order the diagnostic should list them — the
--           diagnostic reads this table, so it cannot drift from the set it
--           describes.
--   scope   'doc' (the `tikz:` metadata block), 'block' (a `%%|` directive),
--           or 'both'. Lets a directive naming a document-level option say so
--           instead of falling through to the image-attribute catch-all.
--   alias   an additional accepted spelling.
--   retired a value that used to be accepted, mapped to the explanation.
local OPTIONS = {
  ['cache']       = { type = 'bool',   scope = 'doc', default = false },
  ['cache-dir']   = { type = 'string', scope = 'doc' },
  ['save-tex']    = { type = 'bool',   scope = 'doc', default = false },
  ['tex-dir']     = { type = 'string', scope = 'doc', default = 'tikz-tex' },
  ['tex-template'] = { type = 'string', scope = 'doc' },
  -- Anything naming an executable on PATH is accepted: pdflatex (the
  -- historical default), lualatex and xelatex for fontspec or complex
  -- Unicode scripts, or any other TeX engine.
  ['tex-engine']  = { type = 'string', scope = 'doc', default = 'pdflatex' },
  -- inkscape and pdftocairo consume the PDF the TeX run produces; dvisvgm
  -- consumes a DVI (which is why `pipeline_for` has to ask for one) and
  -- embeds fonts as WOFF, keeping text in the rendered SVG selectable.
  ['svg-engine']  = { type = 'enum',   scope = 'doc', default = 'inkscape',
                      values = { 'inkscape', 'dvisvgm', 'pdftocairo' } },
  -- Escape hatch for wiring any external converter (pdf2svg, a pymupdf
  -- script, mutool, …) without us blessing each by name. Two YAML forms:
  --   svg-command: "mytool {input} {output}"        whitespace-tokenized
  --   svg-command: [mytool, "{input}", "{output}"]  preferred if a path may
  --                                                 contain spaces
  -- `{input}` expands to the intermediate PDF, `{output}` to the target SVG.
  -- Takes precedence over svg-engine; see `convert_command`.
  ['svg-command'] = { type = 'list',   scope = 'doc',
                      -- Without both placeholders the command would run with
                      -- no PDF to read and write nothing we could find.
                      validate = function(parts)
                        local joined = table.concat(parts, ' ')
                        for _, ph in ipairs { '{input}', '{output}' } do
                          if not joined:find(ph, 1, true) then
                            return "it never mentions " .. ph
                          end
                        end
                      end },
  -- Base URL serving tikzjax.js and fonts.css: the canonical CDN by default,
  -- overridden to self-host or to pin a fork.
  ['tikzjax-url'] = { type = 'string', scope = 'doc',
                      default = 'https://tikzjax.com/v1' },
  -- How a block is drawn when we have to draw it. Both pipelines are total:
  -- either can serve any output format it supports.
  ['renderer']    = { type = 'enum',   scope = 'both', default = 'latex',
                      values = { 'latex', 'tikzjax' },
                      retired = { ['latex-passthrough'] =
                        "It is now a separate option, because it decides whether a " ..
                        "block is rendered at all rather than how: set " ..
                        "`latex-passthrough: true` and leave `renderer` saying how the " ..
                        "block should be drawn on non-LaTeX outputs." } },
  -- How a rendered SVG reaches an HTML page: as an `<img src=…>` reference,
  -- or as inline markup. Changes the delivery, never the bytes.
  ['embed']       = { type = 'enum',   scope = 'both', default = 'img',
                      values = { 'img', 'inline' } },
  -- Whether to draw the block at all: under LaTeX output the host document
  -- can typeset the picture itself, so we hand over the source.
  ['latex-passthrough'] = { type = 'bool', scope = 'both', default = false },
  ['additional-packages'] = { type = 'string', scope = 'block',
                              alias = 'additionalPackages' },
  ['header-includes']     = { type = 'string', scope = 'block' },
}

-- Every spelling that names an option, mapped to its canonical name.
-- `additionalPackages` is the lone camelCase survivor in an otherwise
-- kebab-case vocabulary; both spellings are accepted so that the natural one
-- does not fall through to the image-attribute catch-all.
local OPTION_NAMES = {}
for name, spec in pairs(OPTIONS) do
  OPTION_NAMES[name] = name
  if spec.alias then OPTION_NAMES[spec.alias] = name end
end

-- Coerce and validate one value against its schema entry. Returns nil when the
-- value is absent or unusable, so the caller's chain — block directive, then
-- document metadata, then the built-in default — carries on to the next source.
--
-- `where` names the source for diagnostics ('%%| renderer:', 'tikz.renderer').
-- The message deliberately does not name the value being fallen back *to*:
-- only the caller's chain knows which source answers next, so naming it here
-- would report a value the user did not get.
local function read_option(name, value, where)
  local spec = OPTIONS[name]
  if spec == nil or value == nil then return nil end

  -- What happens after a rejected value depends on where it came from: a
  -- directive falls through to the document setting, a document setting to
  -- the built-in default.
  local consequence = where:match('^tikz%.')
    and "the built-in default is used"
    or "the document-level setting applies (or the default, if there is none)"

  if spec.type == 'bool' then
    local parsed = truthy(value)
    if parsed == nil then
      log.warning(
        "tikz: " .. where .. " expects true or false, got '" ..
        stringify(value) .. "' — ignoring it, so " .. consequence .. "."
      )
    end
    return parsed
  end

  if spec.type == 'list' then
    local parts = {}
    if pandoc.utils.type(value) == 'List' then
      for _, item in ipairs(value) do parts[#parts + 1] = stringify(item) end
    else
      for word in stringify(value):gmatch('%S+') do parts[#parts + 1] = word end
    end
    if #parts == 0 then
      log.warning("tikz: " .. where .. " is empty — ignoring it, so " ..
        consequence .. ".")
      return nil
    end
    local problem = spec.validate and spec.validate(parts)
    if problem then
      log.warning("tikz: " .. where .. " is unusable — " .. problem ..
        ". Ignoring it, so " .. consequence .. ".")
      return nil
    end
    return parts
  end

  local s = stringify(value)

  if spec.type == 'enum' then
    for _, known in ipairs(spec.values) do
      if s == known then return s end
    end
    local retired = spec.retired and spec.retired[s]
    if retired then
      log.warning("tikz: " .. where .. " no longer takes '" .. s .. "'. " ..
        retired .. " Ignoring it.")
    else
      log.warning(
        "tikz: unknown " .. where .. " '" .. s .. "' — ignoring it, so " ..
        consequence .. ". Supported values: " ..
        table.concat(spec.values, ', ') .. "."
      )
    end
    return nil
  end

  return s
end

-- Resolve one option through its whole chain: the block directive, then the
-- document-level value (already read and defaulted into `conf`), then the
-- built-in default.
local function resolve_option(name, user_opt, conf)
  local value = read_option(name, user_opt[name], '%%| ' .. name .. ':')
  if value ~= nil then return value end
  if conf[name] ~= nil then return conf[name] end
  return OPTIONS[name].default
end

-- Route a block's options to the things that consume them. `attribs` is the
-- directive table from `split_directives`, which this mutates by merging the
-- fence attributes in — it is built fresh per block, so there is nothing to
-- alias.
--
-- The `%%| key: value` directives are the canonical syntax (and match
-- Quarto's cell-options convention); fence attributes (`{.tikz filename=…}`)
-- are the deprecated pre-1.0 form. Set both ways, the directive wins and the
-- conflict is warned about rather than silently resolved.
local function diagram_options(cb, attribs)
  -- Which keys the user wrote as `%%|` directives, captured before the fence
  -- attributes are merged in. Only these are held to the option vocabulary: a
  -- fence attribute is *allowed* to be an arbitrary image attribute, which is
  -- what the catch-all at the end of the routing loop is for.
  local from_directive = {}
  for key in pairs(attribs) do from_directive[key] = true end

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
    local opt_name = OPTION_NAMES[attr_name]
    if opt_name and OPTIONS[opt_name].scope ~= 'doc' then
      user_opt[opt_name] = value
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
      elseif from_directive[attr_name] then
        -- Nothing recognised the name and the user wrote it as a directive.
        -- A fence attribute may legitimately be any image attribute, so it
        -- keeps falling through silently; a directive may not. Without this,
        -- `%%| capton: x` became `<img capton="x">` and `%%| cache: true`
        -- looked like it had been honoured.
        if opt_name then
          log.warning(
            "tikz: '" .. attr_name .. "' is a document-level option — set it " ..
            "under `tikz:` in the front matter or in _quarto.yml, not as a " ..
            "%%| directive. Ignoring it."
          )
        else
          log.warning(
            "tikz: unknown %%| directive '" .. attr_name .. "' — passing it " ..
            "through as an image attribute. Check the spelling, or write it " ..
            "as `%%| image-" .. attr_name .. ":` if an image attribute is " ..
            "what you meant."
          )
          image_attr[attr_name] = value
        end
      else
        -- A fence attribute nothing else claimed: an image attribute.
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

-- Encode an option table so it can be hashed. Two properties are load-bearing,
-- and a naive `stringify(options)` has neither:
--
--   * Sorted keys. `pairs()` order is unspecified by the Lua spec — stable for
--     any one build, so a pandoc upgrade that hashed keys differently would
--     orphan every cached file in every project at once.
--   * Length-prefixed keys *and* values, so `{a = 'x', b = ''}` cannot encode
--     to the same string as `{a = '', b = 'x'}`, even when a value contains
--     the delimiters. The code is length-prefixed for the same reason.
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

-- The name every artifact of one diagram shares, extension aside: its cache
-- entry, its mediabag entry, and its `save-tex` directory.
--
-- `<label>.<short-hash>`: the label makes a directory listing diagnosable at a
-- glance, and the hash — taken over the code *and* the options — keeps two
-- diagrams apart. An auto-generated SHA1 basename is replaced by a short
-- literal label, since repeating the content hash inside the name says
-- nothing.
local function artifact_name(basename, hash, options)
  local key = pandoc.sha1(#hash .. ':' .. hash .. canonical_options(options))
  local label = basename or 'tikz'
  if #label == 40 and label:match('^[0-9a-f]+$') then
    label = 'tikz'
  end
  return label .. '.' .. key:sub(1, 8)
end

-- Everything below takes the already-computed `name`, so a diagram's hash is
-- taken once per render rather than again for every artifact it produces.
local function artifact_file(name, format)
  return name .. '.' .. format
end

-- Where a given diagram's cached file lives, or nil when caching is off.
local function cache_path(dir, name, format)
  if not dir then return nil end
  return pandoc.path.join { dir, artifact_file(name, format) }
end

local function get_cached_image(dir, name, format)
  local path = cache_path(dir, name, format)
  local imgdata = path and read_file(path)
  if imgdata then
    return imgdata, mime_for_format(format)
  end
  return nil
end

local function cache_image(dir, name, format, imgdata)
  local path = cache_path(dir, name, format)
  if path then write_file(path, imgdata) end
end

local PASSTHROUGH_PACKAGES, PASSTHROUGH_LIBRARIES, PASSTHROUGH_HEADERS = 1, 2, 3

-- Queue `text` for the host document's preamble, at most once per render.
-- Deduplication is by exact text, which is what makes it safe to hoist the
-- same `\usetikzlibrary{arrows}` or `%%| additionalPackages:` line out of a
-- dozen blocks: identical strings collapse to one, and anything that differs
-- is emitted in full rather than being cleverly merged.
local function hoist(bucket, text)
  if not text or text == '' then return end
  if doc_state.passthrough_header_seen[text] then return end
  doc_state.passthrough_header_seen[text] = true
  local b = doc_state.passthrough_preamble[bucket]
  b[#b + 1] = text
end

-- Emit everything queued above into the host preamble. Called once, after the
-- document walk, so bucket order is what reaches the `.tex`.
local function flush_passthrough_preamble()
  local parts = {}
  for _, bucket in ipairs(doc_state.passthrough_preamble) do
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

-- Find every call to one of `macros` in `line` (comments already stripped), in
-- source order: the macro name, where the call starts and ends, and its
-- argument. The argument is matched with `%b{}` rather than a non-greedy
-- `(.-)}`, which would backtrack to the last brace on the line and read
-- `\usetikzlibrary{arrows}\begin{tikzpicture}` as one call whose argument is
-- `arrows}\begin{tikzpicture`.
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
        while line:sub(p, p):match('^%s$') do p = p + 1 end
        local arg = line:match('^(%b{})', p) or line:match('^(%b[])', p)
        found[#found + 1] = {
          pos = s,
          stop = arg and (p + #arg - 1) or e,
          macro = macro,
          arg = arg and arg:sub(2, -2) or nil,
        }
      end
    end
  end
  table.sort(found, function(a, b) return a.pos < b.pos end)
  return found
end

-- Whether `line` is *exactly* one library load and nothing else — the shape
-- that may be moved rather than copied. Asked of the scanner above so that
-- both passes share one idea of what a loader call is; a trailing `%` comment
-- and surrounding whitespace are already gone by the time we look.
local function match_loader_line(line)
  local c = code_part(line)
  local calls = scan_loader_calls(c, LOADER_MACROS)
  local call = #calls == 1 and calls[1] or nil
  if not call or not call.arg then return nil end
  if c:sub(1, call.pos - 1):match('^%s*$')
    and c:sub(call.stop + 1):match('^%s*$') then
    return call.macro, call.arg
  end
  return nil
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

-- Prepare a block body for passthrough: hoist its library loads into the host
-- preamble. Returns the preamble lines, the remaining body, and any warnings.
-- (`%%|` directives are already gone — `split_directives` removes them before
-- any renderer sees the code.)
--
-- Two passes, because how a load is written decides what may be done with it:
--
--   1. A line that is *exactly* one loader call, outside any `tikzpicture`, is
--      **moved**: hoisted and removed from the body.
--   2. A loader sharing its line with other code cannot be excised without
--      risking the drawing, so it is **copied** — the preamble gets a load and
--      the body keeps its own, which PGF's idempotent loaders make a no-op.
--
-- Both passes track `tikzpicture` depth, because a loader inside a picture may
-- be literal content in a diagram *about* TikZ. That, an argument that will
-- not brace-balance, and `\usepackage` / `\usegdlibrary` are the three shapes
-- left alone with a warning.
--
-- Why copying is not merely tidiness: see the README's LaTeX-passthrough
-- section, which explains what a library load scoped to a `figure` environment
-- does to a later block.
local function prepare_passthrough_body(code)
  local preamble, body, warns = {}, {}, {}

  -- One load per library name, so a dozen blocks opening with
  -- `\usetikzlibrary{arrows, arrows.meta}` collapse to two preamble lines.
  local function hoist_libs(macro, arg)
    for _, name in ipairs(split_libs(arg)) do
      preamble[#preamble + 1] = '\\' .. macro .. '{' .. name .. '}'
    end
  end

  local outer_depth = 0
  for _, line in ipairs(split_lines(code)) do
    local macro, arg = match_loader_line(line)
    if macro and outer_depth == 0 then
      hoist_libs(macro, arg)
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
        hoist_libs(call.macro, call.arg)
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
-- Everything a standalone wrapper would have supplied has to reach the host
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
  if doc_state.tikzjax_assets_injected then return end
  doc_state.tikzjax_assets_injected = true
  local url = conf['tikzjax-url']
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

-- Rewrite an SVG so it can be dropped into an HTML page beside others.
--
-- Inside an `<img>` an SVG is its own document: its ids, CSS classes and
-- `@font-face` families are sandboxed. Inlined, they are page-global, and
-- every converter we support emits names that repeat from diagram to diagram,
-- so a second diagram silently steals the first one's glyph definitions,
-- clip paths and fonts. All three name kinds are therefore suffixed with a
-- per-diagram nonce, and every reference form is rewritten in step.
--
-- Rewriting is scoped to where a name can legally appear: CSS text (a
-- `<style>` body or a `style="…"` attribute value) and specific attributes.
-- Nothing else is touched, so a decimal in path data or a literal `.f0` in a
-- diagram's own label cannot be mistaken for a selector.
local function namespace_svg(svg, nonce, alt)
  -- An inlined SVG is an element, not a document: drop the XML prolog,
  -- any DOCTYPE, and the generator comments that precede the root tag.
  local root = svg:find('<svg', 1, true)
  if not root then return nil end
  svg = svg:sub(root)

  -- Collect every name first, then rewrite. Collecting as we go would read a
  -- document already half-rewritten.
  local ids, classes, families = {}, {}, {}
  for _, name in svg:gmatch('id%s*=%s*(["\'])(.-)%1') do
    if name ~= '' then ids[name] = true end
  end
  -- A `class` attribute may carry several names, so they are collected — and
  -- rewritten below — token by token.
  for value in svg:gmatch('class%s*=%s*["\']([^"\']*)["\']') do
    for token in value:gmatch('%S+') do classes[token] = true end
  end
  -- The whole `@font-face` block, so the family is found wherever in the rule
  -- it was declared rather than only as the first entry.
  for block in svg:gmatch('@font%-face%s*(%b{})') do
    for name in block:gmatch('font%-family%s*:%s*["\']?([%w_%-]+)') do
      families[name] = true
    end
  end

  -- The namespaced form of `name`, or nil when it is not one we collected —
  -- and nil is what tells `gsub` to leave the match alone. Every pattern
  -- below is therefore free to be written broadly: the lookup, not the
  -- pattern, decides whether something is renamed.
  local function ns(names, name)
    if not names[name] then return nil end
    return name .. '-' .. nonce
  end

  -- `url(#id)`, which appears both in CSS and in presentation attributes.
  local function rewrite_urls(s)
    return (s:gsub('url%(%s*#([^)%s]*)%s*%)', function(name)
      local t = ns(ids, name); return t and ('url(#' .. t .. ')') or nil
    end))
  end

  -- CSS text: a `<style>` body or a `style="…"` attribute value.
  local function rewrite_css(css)
    -- Class selectors. One pattern covers every shape — `.f0 {`, `.f0{`, and
    -- the `.f0, .f1 {` group.
    css = css:gsub('%.([%w_%-]+)', function(name)
      local t = ns(classes, name); return t and ('.' .. t) or nil
    end)
    -- A `font-family` declaration. Anchored on the prefix rather than on a
    -- closing `;`/`}`, so the last declaration in a `style="…"` attribute —
    -- which is terminated by the quote — is renamed like any other. Renaming
    -- an `@font-face` while missing a reference to it loses the font.
    css = css:gsub('(font%-family%s*:%s*["\']?)([%w_%-]+)', function(a, name)
      local t = ns(families, name); return t and (a .. t) or nil
    end)
    return rewrite_urls(css)
  end

  -- Rewrite one attribute, both quoting styles, rebuilding the surroundings
  -- around the captured value — so a name that is a prefix of another
  -- (`clip-0` inside `clip-01`) cannot be partially rewritten.
  local function attr(text, name_pattern, f)
    for _, q in ipairs { '"', "'" } do
      text = text:gsub(
        '(' .. name_pattern .. '%s*=%s*' .. q .. ')([^' .. q .. ']*)(' .. q .. ')', f)
    end
    return text
  end

  -- Markup: ids, the three ways one SVG refers to another element, class
  -- lists, and font families named as an attribute or inside `style="…"`.
  local function rewrite_markup(text)
    text = attr(text, 'id', function(a, name, b)
      local t = ns(ids, name); return t and (a .. t .. b) or nil
    end)
    -- `href` and `xlink:href` alike.
    text = attr(text, '[%w:]-href', function(a, value, b)
      local name = value:match('^#(.*)$')
      if not name then return nil end
      local t = ns(ids, name); return t and (a .. '#' .. t .. b) or nil
    end)
    text = attr(text, 'class', function(a, value, b)
      local out = {}
      for token in value:gmatch('%S+') do out[#out + 1] = ns(classes, token) or token end
      if #out == 0 then return nil end
      return a .. table.concat(out, ' ') .. b
    end)
    text = attr(text, 'font%-family', function(a, name, b)
      local t = ns(families, name); return t and (a .. t .. b) or nil
    end)
    text = attr(text, 'style', function(a, value, b)
      return a .. rewrite_css(value) .. b
    end)
    -- `clip-path="url(#…)"`, `fill="url(#…)"`, and the rest.
    return rewrite_urls(text)
  end

  -- Split into `<style>` bodies and everything else, so each half is rewritten
  -- by the rules that apply to it.
  local pieces, pos = {}, 1
  while true do
    local open_s, open_e = svg:find('<style[^>]*>', pos)
    -- Reject a longer element name (`<styles>`): what follows `<style` must
    -- not continue the name.
    while open_s and svg:sub(open_s + 6, open_s + 6):match('[%w_%-]') do
      open_s, open_e = svg:find('<style[^>]*>', open_e + 1)
    end
    if not open_s then break end
    local close_s, close_e = svg:find('</style%s*>', open_e + 1)
    if not close_s then break end
    pieces[#pieces + 1] = rewrite_markup(svg:sub(pos, open_e))
    pieces[#pieces + 1] = rewrite_css(svg:sub(open_e + 1, close_s - 1))
    pieces[#pieces + 1] = svg:sub(close_s, close_e)
    pos = close_e + 1
  end
  pieces[#pieces + 1] = rewrite_markup(svg:sub(pos))
  svg = table.concat(pieces)

  -- Where the root `<svg …>` tag ends: the first `>` that is not inside a
  -- quoted attribute value.
  local stop
  do
    local quote
    for i = 1, #svg do
      local c = svg:sub(i, i)
      if quote then
        if c == quote then quote = nil end
      elseif c == '"' or c == "'" then quote = c
      elseif c == '>' then stop = i break end
    end
  end
  if not stop then return svg end

  local head, rest = svg:sub(1, stop), svg:sub(stop + 1)
  -- A self-closing root has no inside to put a <title> in, so open it up.
  if head:match('/%s*>$') then
    head = head:gsub('/%s*>$', '>')
    rest = '</svg>' .. rest
  end

  -- Give the page a styling hook, and the accessibility tree a name.
  -- `<title>` rather than `role="img"` + `aria-label`, which would hide the
  -- very text that inlining exists to expose. The hook is added after the
  -- renaming pass, so it is a stable page-wide selector rather than another
  -- namespaced name.
  local hooked, n = head:gsub('(class%s*=%s*["\'])([^"\']*)(["\'])',
    function(a, value, b) return a .. value .. ' tikz-svg' .. b end, 1)
  if n == 0 then hooked = head:gsub('^<svg', '<svg class="tikz-svg"', 1) end
  head = hooked

  local title = alt and stringify(alt) or ''
  if title ~= '' then
    title = title:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
    head = head .. '<title>' .. title .. '</title>'
  end
  return head .. rest
end

-- The shape of one LaTeX render: what the TeX run must leave behind, and
-- whether a converter then runs over it. Both are decided here, together, so
-- that they cannot contradict each other — when nothing is converted, the
-- intermediate is by definition the format we deliver.
local function pipeline_for(deliverable, svg_engine, svg_command)
  -- Under LaTeX output we embed the TeX run's own PDF directly. This skips the
  -- converter round-trip and preserves vector fidelity and fonts.
  if deliverable == 'pdf' then
    return { intermediate = 'pdf', convert = false }
  end
  -- Only dvisvgm reads a DVI, and only when it is the converter that will
  -- actually run: `svg-command` takes precedence over `svg-engine`, and its
  -- `{input}` is documented as the intermediate PDF.
  if svg_command then return { intermediate = 'pdf', convert = true } end
  if svg_engine == 'dvisvgm' then return { intermediate = 'dvi', convert = true } end
  return { intermediate = 'pdf', convert = true }
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
-- installation. It is also where `svg-command` overriding `svg-engine` is
-- decided — the pairing `pipeline_for` has to agree with about DVI.
--
-- `files` carries the paths the TeX run produced or is expected to produce:
-- `pdf`, `dvi`, `svg`.
local function convert_command(conf, files)
  if conf['svg-command'] then
    -- Element 1 is the executable; the rest are its arguments, with
    -- {input}/{output} substituted. Function replacements, because a plain
    -- one would read a '%' in a user-supplied `filename` as a capture
    -- reference; a function's return value is used verbatim.
    local args = {}
    for i = 2, #conf['svg-command'] do
      args[#args + 1] = conf['svg-command'][i]
        :gsub('{input}', function() return files.pdf end)
        :gsub('{output}', function() return files.svg end)
    end
    return conf['svg-command'][1], args
  end

  if conf['svg-engine'] == 'dvisvgm' then
    -- dvisvgm reads DVI directly. --font-format=woff embeds fonts as WOFF
    -- (instead of converting glyphs to paths), which keeps text selectable /
    -- styleable in the rendered SVG — the thing `embed: inline` exists to
    -- expose. Note: dvisvgm must be the TeX-Live-integrated build (e.g. via
    -- tlmgr); standalone packages can fail to find the PostScript prologue
    -- files.
    return 'dvisvgm', { '--font-format=woff', '-o', files.svg, files.dvi }
  end

  if conf['svg-engine'] == 'pdftocairo' then
    -- pdftocairo (poppler-utils) reads PDF and is widely available; a good
    -- lightweight alternative to Inkscape where Inkscape isn't installed.
    return 'pdftocairo', { '-svg', files.pdf, files.svg }
  end

  -- Inkscape default. Note: --pages=N (Inkscape 1.2+) is omitted because the
  -- standalone class always produces a single-page PDF, and dropping it
  -- preserves compatibility with Inkscape 1.0/1.1.
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
-- Three renderers produce a `RawBlock`, which `Figure` takes directly; the
-- `<img>` path produces an `Image`, which is an Inline and needs a `Plain`
-- around it.
local function as_figure(content, dgr_opt)
  local block = content.t == 'Image' and pandoc.Plain { content } or content
  if not dgr_opt.caption then return block end
  return pandoc.Figure({ block }, dgr_opt.caption, dgr_opt['fig-attr'])
end

-- Compile TikZ code to either SVG (default) or PDF (embedded directly under
-- LaTeX output).
--
-- Returns `imgdata, mimetype` on success and `nil, message` on failure.
-- Expected failures — no TeX engine, a LaTeX run that produced no file — are
-- returned rather than raised, because `error()` inside a filter does not
-- abort under Quarto: the message is logged, execution continues to the next
-- statement, and a surrounding `pcall` reports success.
local function compile_tikz_to_svg(code, user_opts, conf, name)
  -- Every failure quotes the block, which is what makes one diagnosable
  -- among fifty in a render log.
  local function fail(detail)
    return nil, detail .. "\nTikZ Code:\n" .. code
  end
  -- A missing executable is reported before anything runs: on a machine with
  -- TeX but no converter, fifty diagrams should say so fifty times without
  -- running LaTeX fifty times first.
  local function missing(cmd, remedy)
    return nil, cmd .. " not found. Install it, or set " .. remedy .. "."
  end

  if not check_dependency(conf['tex-engine']) then
    return missing(conf['tex-engine'],
      "tikz.tex-engine to a TeX engine you do have (pdflatex, lualatex, xelatex, …)")
  end
  -- The converter is only needed when we actually convert. Under LaTeX output
  -- the intermediate PDF is the deliverable and nothing here is invoked.
  local files = {
    tex = name .. ".tex",
    pdf = name .. ".pdf",
    svg = name .. ".svg",
    dvi = name .. ".dvi",
    log = name .. ".log",
  }
  local convert_cmd, convert_args = convert_command(conf, files)
  if conf.pipeline.convert and not check_dependency(convert_cmd) then
    return missing(convert_cmd,
      "tikz.svg-engine / tikz.svg-command to a converter you do have")
  end

  local function process_in_dir(dir)
    return with_working_directory(dir, function()
      -- A failed write would otherwise surface as a baffling LaTeX error
      -- about a file that was never there.
      if not write_file(
        files.tex,
        build_tex_document(code, user_opts, conf.tex_template_content)
      ) then
        return fail("Could not write " .. files.tex .. " for TikZ figure '" ..
          name .. "'.")
      end

      -- Execute the LaTeX compiler with TEXINPUTS so blocks can \input or
      -- \usepackage shared files from the qmd directory or the extension dir.
      -- with_environment replaces the entire env, so we merge our override
      -- onto a copy of the current env to preserve PATH and friends.
      local env = pandoc.system.environment()
      env.TEXINPUTS = conf.texinputs
      -- Ask for DVI only when the converter we are actually going to run
      -- consumes one; every other path reads the default PDF output. See
      -- `pipeline_for`.
      local latex_args = { '-interaction=nonstopmode' }
      if conf.pipeline.intermediate == 'dvi' then
        table.insert(latex_args, '-output-format=dvi')
      end
      table.insert(latex_args, files.tex)
      local success, latex_result = pcall(function()
        return pandoc.system.with_environment(env, function()
          return pandoc.pipe(conf['tex-engine'], latex_args, '')
        end)
      end)
      if not success then
        return fail("Error compiling TikZ figure '" .. name .. "':\n" ..
          tostring(latex_result) .. "\nLaTeX Log:\n" ..
          (read_file(files.log) or ""))
      end

      -- Nothing to convert: the intermediate the TeX run produced is what we
      -- deliver. Reading `pipeline.intermediate` rather than assuming a PDF is
      -- what keeps this in step with what the TeX run was actually asked for.
      if not conf.pipeline.convert then
        local produced = files[conf.pipeline.intermediate]
        local imgdata = read_file(produced)
        if not imgdata then
          return fail("Failed to read " .. produced .. " for TikZ figure '" ..
            name .. "'.")
        end
        return imgdata, mime_for_format(conf.pipeline.intermediate)
      end

      -- Convert TeX output to SVG with the command chosen above.
      local success_convert, convert_result = pcall(
        pandoc.pipe, convert_cmd, convert_args, ''
      )
      if not success_convert then
        return fail("Error converting to SVG (command: " .. convert_cmd ..
          ") for TikZ figure '" .. name .. "':\n" .. tostring(convert_result))
      end

      local imgdata = read_file(files.svg)
      if not imgdata then
        return fail("Failed to read generated SVG file for TikZ figure '" ..
          name .. "'.")
      end
      return imgdata, 'image/svg+xml'
    end)
  end

  if conf['save-tex'] then
    -- One subdirectory per diagram, under the same name as everything else
    -- it produces — so two blocks sharing a `%%| filename:` no longer
    -- overwrite each other's intermediates.
    local diagram_dir = pandoc.path.join { conf['tex-dir'], name }
    pandoc.system.make_directory(diagram_dir, true)
    return process_in_dir(diagram_dir)
  else
    return with_temporary_directory("tikz", function(tmpdir)
      return process_in_dir(tmpdir)
    end)
  end
end

-- Resolve the three orthogonal per-block axes, and derive the cache key. The
-- axes are independent by construction — `renderer` says *how* a block is
-- drawn, `latex-passthrough` says *whether* to draw it at all, and `embed`
-- says how the result reaches an HTML page; each is declared in `OPTIONS`
-- above.
--
-- `key_opts` is a *separate table* built from the *resolved* values, never
-- `user_opt` with keys deleted. A raw directive can therefore only reach the
-- key by being copied there, so a no-op `%%| renderer: latex` — or a value
-- that was rejected and warned about — cannot mint a second cache entry for a
-- byte-identical image.
local function resolve_axes(user_opt, conf)
  local renderer = resolve_option('renderer', user_opt, conf)
  local passthrough = resolve_option('latex-passthrough', user_opt, conf)
  local embed = resolve_option('embed', user_opt, conf)

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
  key_opts['tex-engine'] = conf['tex-engine']
  key_opts['svg-engine'] = conf['svg-engine']
  if conf['svg-command'] then
    key_opts['svg-command'] = table.concat(conf['svg-command'], ' ')
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
    -- One name for every artifact this diagram produces: its cache entry, the
    -- file handed to the mediabag, the `save-tex` directory, and whatever the
    -- diagnostics below name. Derived from the code *and* the options, so two
    -- blocks that differ only in their options no longer share a file.
    local name = artifact_name(basename, hash, key_opts)

    -- Check if image is cached
    local imgdata, imgtype = nil, nil
    local image_format = conf.image_format
    imgdata, imgtype = get_cached_image(conf.image_cache, name, image_format)

    if not imgdata or not imgtype then
      -- No cached image; compile. Two failure channels: a returned
      -- `nil, message` for an expected failure, and `pcall` for a genuine
      -- runtime error in the filter itself, which — unlike `error()`, see the
      -- note on `compile_tikz_to_svg` — really does propagate under Quarto.
      -- Either way one diagram must not take down the render: log it, leave
      -- the block as its source, and let the document through.
      local ok, result, extra = pcall(function()
        return compile_tikz_to_svg(code, compile_opts, conf, name)
      end)
      local failure
      if not ok then
        failure = tostring(result)
      elseif not result then
        failure = extra or "no image data was produced"
      end
      if failure then
        log.error(
          "tikz: could not render figure '" .. name .. "', leaving the " ..
          "block unrendered.\n" .. failure
        )
        return nil -- Return the original block unchanged
      end
      -- pcall returns (true, returned_values...) on success; result is the
      -- imgdata, extra is the MIME string returned by compile_tikz_to_svg.
      imgdata, imgtype = result, extra or mime_for_format(image_format)

      -- Cache the image
      cache_image(conf.image_cache, name, image_format, imgdata)
    end

    -- Inline embedding: hand the SVG to the page as markup rather than as a
    -- file reference, which is what exposes its text to selection, search and
    -- screen readers. Restricted to HTML output — `image_format` is 'svg' for
    -- everything that is not LaTeX, docx included, and docx needs a genuine
    -- image file.
    if embed == 'inline' and image_format == 'svg' and is_html_output() then
      doc_state.inline_svg_seq = doc_state.inline_svg_seq + 1
      local markup = namespace_svg(imgdata, 'tikz' .. doc_state.inline_svg_seq, dgr_opt.alt)
      if markup then
        return as_figure(pandoc.RawBlock('html', markup), dgr_opt)
      end
      log.warning(
        "tikz: could not inline figure '" .. name .. "' (no <svg> root " ..
        "in the converter's output); falling back to an <img> reference."
      )
    end

    local fname = artifact_file(name, image_format)

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
  -- `pandoc.system.get_working_directory()` rather than $PWD: PWD is a shell
  -- convention, not something every launcher exports, and the old `or '.'`
  -- fallback produced exactly the relative path this function exists to
  -- prevent.
  return pandoc.path.normalize(
    pandoc.path.join { pandoc.system.get_working_directory(), p }
  )
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
  local raw = meta.tikz or {}
  meta.tikz = nil  -- Remove tikz metadata to avoid processing it further

  -- Every document-level option, through the one schema-driven reader.
  -- `conf` is keyed by canonical option name, so the spelling of a field says
  -- what it is: hyphens for something the user wrote, underscores for
  -- something we derived from it below.
  local conf = {}
  for name, spec in pairs(OPTIONS) do
    if spec.scope ~= 'block' then
      local value = read_option(name, raw[name], 'tikz.' .. name)
      if value == nil then value = spec.default end
      conf[name] = value
    end
  end

  -- Strip a trailing slash so concatenation with /fonts.css and /tikzjax.js
  -- produces a single separator however the user wrote the URL.
  conf['tikzjax-url'] = conf['tikzjax-url']:gsub('/+$', '')

  -- On-disk cache for rendered images.
  if conf['cache'] then
    conf.image_cache = conf['cache-dir'] or cachedir()
    if conf.image_cache then
      pandoc.system.make_directory(conf.image_cache, true)
    end
  end

  -- `save-tex` preserves the intermediates for debugging, which caching makes
  -- pointless: on a cache hit nothing is compiled, so there is nothing to keep.
  if conf['save-tex'] then
    if conf.image_cache then
      log.warning(
        "tikz: both 'cache' and 'save-tex' are enabled; disabling 'save-tex', " ..
        "because a cache hit compiles nothing to preserve."
      )
      conf['save-tex'] = false
    else
      pandoc.system.make_directory(conf['tex-dir'], true)
    end
  end

  -- Custom standalone template, read once at setup so we neither pay file I/O
  -- per diagram nor resolve the path after `with_working_directory` has moved.
  if conf['tex-template'] then
    local path = absolutize(conf['tex-template'])
    conf.tex_template_content = read_file(path)
    if not conf.tex_template_content then
      log.error(
        "tikz: tex-template not found: " .. tostring(path) ..
        " — falling back to the default template."
      )
    end
  end

  -- Setting both is a configuration mistake rather than a layered override, so
  -- say which one is being ignored instead of silently picking. Tested against
  -- `raw`, not `conf`: the latter always carries the svg-engine default.
  if conf['svg-command'] and raw['svg-engine'] then
    log.warning(
      "tikz: both svg-command and svg-engine are set; svg-command wins and " ..
      "svg-engine '" .. conf['svg-engine'] .. "' is ignored." ..
      (conf['svg-engine'] == 'dvisvgm'
        and " In particular the TeX run still produces a PDF, which is what " ..
            "{input} names — dvisvgm's DVI input is not available to a custom " ..
            "command. Remove one of the two settings."
        or " Remove one of the two settings to silence this warning.")
    )
  end

  -- Is the host document LaTeX? True for `format: pdf`, `beamer` and
  -- `format: latex` alike (verified: `is_format('pdf')` answers yes to all
  -- three), which is what `latex-passthrough` needs to know.
  conf.host_is_latex = (quarto and quarto.doc and quarto.doc.is_format
    and quarto.doc.is_format('pdf')) or false

  -- What we produce for that host: the intermediate PDF embedded directly
  -- under LaTeX, an SVG everywhere else. Doubles as the file extension.
  conf.image_format = conf.host_is_latex and 'pdf' or 'svg'

  conf.pipeline = pipeline_for(conf.image_format, conf['svg-engine'],
    conf['svg-command'])

  conf.texinputs = build_texinputs()
  return conf
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
  convert_command = convert_command,
  build_tex_document = build_tex_document,
  as_figure = as_figure,
  artifact_name = artifact_name,
  artifact_file = artifact_file,
  pipeline_for = pipeline_for,
  check_dependency = check_dependency,
  find_executable = find_executable,
  resolve_axes = resolve_axes,
  read_option = read_option,
  resolve_option = resolve_option,
  OPTIONS = OPTIONS,
  configure = configure,
  split_libs = split_libs,
  prepare_passthrough_body = prepare_passthrough_body,
}

return {
  {
    Pandoc = function(doc)
      reset_document_state()
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
