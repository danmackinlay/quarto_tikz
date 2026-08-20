-- Unit tests for the two halves of a block's option handling: the `%%|`
-- directive parser and the router that sends the parsed keys to the things
-- that consume them.
-- Run from the repo root:   pandoc lua tests/test_options.lua

dofile('_extensions/tikz/tikz.lua')
local T = TIKZ_TEST
local t = dofile('tests/harness.lua')
local check = t.check

local function props_of(code) return (T.split_directives(code)) end
local function code_of(code) return (select(2, T.split_directives(code))) end

local PIC = '\\begin{tikzpicture}\n  \\draw (0,0) -- (1,1);\n\\end{tikzpicture}'

-- The regression this suite exists for: pandoc strips the trailing newline
-- from a CodeBlock, and the old `gmatch` for "| key: value\n" therefore never
-- matched a directive on the block's last line. It was silently ignored as an
-- option while still being stripped from the hashed code.
check('trailing directive, no newline, is recognised',
  props_of(PIC .. '\n%%| filename: demo').filename, 'demo')
check('…and is still stripped', code_of(PIC .. '\n%%| filename: demo'), PIC)
check('a lone directive with no code at all',
  props_of('%%| filename: demo').filename, 'demo')

-- Ordinary parsing.
check('a leading directive', props_of('%%| filename: demo\n' .. PIC).filename,
  'demo')
local MANY = props_of('%%| filename: demo\n%%| caption: A line.\n' ..
  '%%| renderer: tikzjax\n' .. PIC)
check('several directives: first', MANY.filename, 'demo')
check('several directives: second', MANY.caption, 'A line.')
check('several directives: third', MANY.renderer, 'tikzjax')
check('a hyphenated key', props_of('%%| header-includes: \\relax')['header-includes'],
  '\\relax')
check('a colon in the value', props_of('%%| caption: a: b').caption, 'a: b')
check('the last spelling of a key wins',
  props_of('%%| renderer: latex\n%%| renderer: tikzjax').renderer, 'tikzjax')

-- The value is trimmed. Untrimmed, `%%| renderer: latex ` reached the enum
-- lookup as "latex " and was rejected as an unknown renderer.
check('trailing space trimmed', props_of('%%| renderer: latex ').renderer, 'latex')
check('extra space after the colon trimmed',
  props_of('%%| renderer:    latex').renderer, 'latex')

-- An empty value means unset, not "". `'' or fallback` is truthy in Lua, so
-- an empty basename would otherwise have been used as a filename.
check('an empty value is unset', props_of('%%| filename:').filename, nil)
check('a whitespace-only value is unset', props_of('%%| filename:   ').filename, nil)
check('…and the line is still stripped',
  code_of('%%| filename:\n' .. PIC), PIC)

-- The old pattern required a literal ": ", so these were not directives.
check('no space after the colon', props_of('%%| renderer:tikzjax').renderer,
  'tikzjax')
check('no space after the marker', props_of('%%|renderer: tikzjax').renderer,
  'tikzjax')
check('an indented directive still parses',
  props_of('   %%| filename: demo').filename, 'demo')

-- Stripping is deliberately not conditional on parsing: a line carrying `%%|`
-- always goes, so the sub-lines of a stale nested block (the removed
-- `fig-attr` form) vanish instead of being resurrected as stray options.
local NESTED = '%%| caption: hi\n%%|   id: fig-x\n' .. PIC
check('a non-key `%%|` sub-line is not an option', props_of(NESTED).id, nil)
check('…but is stripped anyway', code_of(NESTED), PIC)
check('the sibling directive on the same block still parses',
  props_of(NESTED).caption, 'hi')

-- A mid-line directive truncates its line and keeps the code before it; a
-- line left blank by the truncation is dropped, so an indented directive and
-- an absent one leave identical code behind.
check('mid-line directive keeps the code before it',
  code_of('\\draw (0,0); %%| caption: x'), '\\draw (0,0); ')
check('…and still parses', props_of('\\draw (0,0); %%| caption: x').caption, 'x')
check('an indented directive line is dropped entirely',
  code_of('   %%| caption: x\n' .. PIC), PIC)
check('the first marker on a line wins',
  props_of('%%| caption: a %%| b').caption, 'a %%| b')

-- Everything that is not a directive survives byte for byte.
check('a TeX comment is preserved', code_of('% a real comment\n' .. PIC),
  '% a real comment\n' .. PIC)
check('a blank line is preserved', code_of('\\relax\n\n\\relax'),
  '\\relax\n\n\\relax')
check('code with no directives round-trips', code_of(PIC), PIC)
check('trailing whitespace in the code is preserved',
  code_of('\\relax  \n\\relax'), '\\relax  \n\\relax')
check('a block of directives only leaves nothing',
  code_of('%%| filename: demo\n%%| caption: x'), '')

-- diagram_options. `attribs` is the directive table; the CodeBlock supplies
-- the identifier and the deprecated fence attributes.
local function route(directives, identifier, attributes)
  local cb = pandoc.CodeBlock('x',
    pandoc.Attr(identifier or '', {'tikz'}, attributes or {}))
  return T.diagram_options(cb, directives)
end

-- The five entries of BLOCK_OPTIONS reach `opt` under their mapped names.
-- Anything missing from that table falls through the catch-all and becomes an
-- image attribute instead — silently, which is why these are pinned.
check('additionalPackages is remapped',
  route({additionalPackages = '\\usepackage{x}'}).opt['additional-packages'],
  '\\usepackage{x}')
check('…and does not survive under its own name',
  route({additionalPackages = '\\usepackage{x}'}).opt.additionalPackages, nil)
check('header-includes', route({['header-includes'] = '\\relax'}).opt['header-includes'],
  '\\relax')
check('renderer', route({renderer = 'tikzjax'}).opt.renderer, 'tikzjax')
check('embed', route({embed = 'inline'}).opt.embed, 'inline')
check('latex-passthrough',
  route({['latex-passthrough'] = 'true'}).opt['latex-passthrough'], 'true')

-- Keys with a field of their own.
check('filename', route({filename = 'demo'}).filename, 'demo')
check('filename defaults to nil', route({}).filename, nil)
check('alt', route({alt = 'a description'}).alt, 'a description')
check('an absent alt is an empty list, not nil', #route({}).alt, 0)
local CAP = route({caption = 'A *cap*'}).caption
check('caption is parsed as Markdown, not kept as text', CAP[1].t, 'Para')
check('caption content', pandoc.utils.stringify(CAP), 'A cap')
check('caption emphasis survives', CAP[1].content[3].t, 'Emph')
check('an absent caption is nil', route({}).caption, nil)

-- Figure identity: `label`/`name`, or the CodeBlock's own identifier.
check('label sets the figure id', route({label = 'fig-a'})['fig-attr'].id, 'fig-a')
check('name sets the figure name', route({name = 'a name'})['fig-attr'].name,
  'a name')
check('an unlabelled block takes the CodeBlock identifier',
  route({}, 'fig-from-fence')['fig-attr'].id, 'fig-from-fence')
check('label wins over the CodeBlock identifier',
  route({label = 'fig-a'}, 'fig-from-fence')['fig-attr'].id, 'fig-a')
check('no identifier and no label leaves an empty id',
  route({})['fig-attr'].id, '')

-- Prefixed keys route by prefix, with the prefix removed.
check('fig- goes to fig-attr', route({['fig-pos'] = 'H'})['fig-attr'].pos, 'H')
check('image- goes to image-attr',
  route({['image-width'] = '3in'})['image-attr'].width, '3in')
check('img- is a synonym for image-',
  route({['img-width'] = '3in'})['image-attr'].width, '3in')
check('opt- goes to opt', route({['opt-scale'] = '2'}).opt.scale, '2')
check('a prefixed key does not also keep its prefixed spelling',
  route({['opt-scale'] = '2'}).opt['opt-scale'], nil)

-- Current, deliberate behaviour for fence attributes: an unrecognised bare
-- key becomes an image attribute rather than being rejected. Pinned so that
-- changing it is visible rather than silent.
check('an unrecognised bare key falls through to image-attr',
  route({width = '3in'})['image-attr'].width, '3in')
check('…and an unrecognised prefix falls through whole',
  route({['data-x'] = '1'})['image-attr']['data-x'], '1')

-- Fence attributes are the deprecated pre-1.0 form; the `%%|` directive is
-- canonical and wins, and a genuine conflict warns (to stderr — not captured
-- here, only the resolution is asserted).
check('a fence attribute alone applies',
  route({}, '', {filename = 'from-fence'}).filename, 'from-fence')
check('a directive wins over a conflicting fence attribute',
  route({filename = 'from-directive'}, '', {filename = 'from-fence'}).filename,
  'from-directive')
check('agreeing sources are not a conflict',
  route({filename = 'same'}, '', {filename = 'same'}).filename, 'same')
check('unrelated fence attributes still merge in',
  route({filename = 'demo'}, '', {renderer = 'tikzjax'}).opt.renderer, 'tikzjax')

t.done()
