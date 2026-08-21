-- Unit tests for the cache-key encoding (issue #21).
-- Run from the repo root:   pandoc lua tests/test_cache_key.lua

dofile('_extensions/tikz/tikz.lua')
local C = TIKZ_TEST.canonical_options
local t = dofile('tests/harness.lua')
local check = t.check
local function distinct(label, a, b) check(label, C(a) ~= C(b), true) end
local function same(label, a, b) check(label, C(a), C(b)) end

-- Order independence: the same options must encode identically however the
-- table was built, and whatever order `pairs()` happens to walk it in.
local built_up, built_down = {}, {}
local pairs_ = { {'tex-engine','pdflatex'}, {'svg-engine','inkscape'},
                 {'renderer','tikzjax'}, {'additional-packages','\\usepackage{a}'},
                 {'header-includes',''}, {'svg-command','pdf2svg {input} {output}'} }
for i = 1, #pairs_ do built_up[pairs_[i][1]] = pairs_[i][2] end
for i = #pairs_, 1, -1 do built_down[pairs_[i][1]] = pairs_[i][2] end
same('insertion order does not matter', built_up, built_down)

-- Adding and removing a key rehashes the table but must not change the result.
local churned = {}
for k, v in pairs(built_up) do churned[k] = v end
churned['scratch'] = 'x'; churned['scratch'] = nil
same('add-then-remove does not matter', built_up, churned)

check('keys appear in the encoding',
  C({['tex-engine'] = 'foo'}) ~= C({['svg-engine'] = 'foo'}), true)

-- The three collisions the old `stringify(options)` key had.
distinct('same value under a different key',
  {['additional-packages'] = '\\usepackage{x}', ['header-includes'] = ''},
  {['additional-packages'] = '',                ['header-includes'] = '\\usepackage{x}'})
distinct('value boundaries are preserved',
  {['additional-packages'] = '\\usepackage{a}',                ['header-includes'] = '\\usepackage{b}'},
  {['additional-packages'] = '\\usepackage{a}\\usepackage{b}', ['header-includes'] = ''})
-- Length prefixes hold even when the values contain the delimiters themselves.
distinct('delimiters inside values do not confuse the encoding',
  {a = '1', b = '2'},
  {a = '1=1:2', b = ''})
distinct('separator inside values does not confuse the encoding',
  {a = 'x', b = 'y'},
  {a = 'x,1:b=1:y', b = ''})

-- Sanity: equal options really do encode equal, and any difference shows up.
same('identical options', {a = '1', b = '2'}, {a = '1', b = '2'})
distinct('a changed value', {a = '1', b = '2'}, {a = '1', b = '3'})
distinct('an added key', {a = '1'}, {a = '1', b = ''})
check('empty options', C({}), '')

-- hashable_code: `%%| directives are presentation or are folded into the
-- options separately, and are TeX comments either way, so they must not
-- reach the hash. Everything else must survive untouched. (#28)
local function H(code) return (select(2, TIKZ_TEST.split_directives(code))) end
local PIC = '\\begin{tikzpicture}\n  \\draw (0,0) -- (1,1);\n\\end{tikzpicture}'

check('directive line removed', H('%%| filename: demo\n' .. PIC), PIC)
check('several directive lines removed',
  H('%%| filename: demo\n%%| caption: A line.\n' .. PIC), PIC)
check('indented directive line removed', H('   %%| caption: x\n' .. PIC), PIC)
-- The migration that detonated a committed cache in the wild: the deprecated
-- fence attribute carries no directive line at all, so both must agree.
check('fence-attribute form and directive form agree',
  H(PIC), H('%%| filename: demo\n' .. PIC))
check('trailing directive with no newline removed',
  H(PIC .. '\n%%| caption: x'), PIC)
check('mid-line directive truncates but keeps the line',
  H('\\draw (0,0); %%| caption: x'), '\\draw (0,0); ')
check('ordinary TeX comments are preserved',
  H('% a real comment\n' .. PIC), '% a real comment\n' .. PIC)
check('code is otherwise untouched', H(PIC), PIC)
check('a blank line in the code is preserved',
  H('\\relax\n\n\\relax'), '\\relax\n\n\\relax')

-- resolve_axes: an option that resolves to its default must leave the cache
-- key untouched, however it was spelled. `embed` and `latex-passthrough`
-- already did; `renderer` wrote only in the non-default branch and so let
-- `diagram_options`' raw directive text survive into the key. A no-op
-- `%%| renderer: latex` then produced a second cache entry for a
-- byte-identical image, and an unknown value that had already been warned
-- about and discarded produced a third. (#28 again, by another route.)
local R = TIKZ_TEST.resolve_axes
local CONF = {['tex-engine'] = 'pdflatex', ['svg-engine'] = 'inkscape'}
local function key_for(user_opt)
  local _, _, _, key_opts = R(user_opt, CONF)
  return C(key_opts)
end

local bare = key_for({})
check('no directives', key_for({}), bare)
check('an explicit default renderer does not re-key',
  key_for({renderer = 'latex'}), bare)
check('a rejected renderer does not re-key',
  key_for({renderer = 'bogus'}), bare)
check('an explicit default embed does not re-key',
  key_for({embed = 'img'}), bare)
check('a non-default embed does not re-key (delivery only)',
  key_for({embed = 'inline'}), bare)
check('a rejected embed does not re-key', key_for({embed = 'bogus'}), bare)
check('latex-passthrough does not re-key',
  key_for({['latex-passthrough'] = 'true'}), bare)

-- …but a renderer that really does change the bytes still must.
check('a non-default renderer re-keys',
  key_for({renderer = 'tikzjax'}) ~= bare, true)
-- …as must every option that reaches the compiler.
check('additionalPackages still re-keys',
  key_for({['additional-packages'] = '\\usepackage{x}'}) ~= bare, true)
check('header-includes still re-keys',
  key_for({['header-includes'] = '\\relax'}) ~= bare, true)
check('an opt-* passthrough still re-keys', key_for({scale = '2'}) ~= bare, true)

-- Doc-level settings that change the bytes are folded in too.
check('the tex engine is in the key',
  C(select(4, R({}, {['tex-engine'] = 'lualatex', ['svg-engine'] = 'inkscape'}))) ~= bare,
  true)
check('the svg engine is in the key',
  C(select(4, R({}, {['tex-engine'] = 'pdflatex', ['svg-engine'] = 'dvisvgm'}))) ~= bare,
  true)
check('the template is in the key',
  C(select(4, R({}, {['tex-engine'] = 'pdflatex', ['svg-engine'] = 'inkscape',
                     tex_template_content = '\\documentclass{article}'}))) ~= bare,
  true)

-- resolve_axes must not write back into the caller's table: the same table is
-- handed to the renderers as compile options.
local shared = {renderer = 'latex', embed = 'inline'}
R(shared, CONF)
check('the caller\'s option table is left alone', shared.renderer, 'latex')
check('…including the delivery axis', shared.embed, 'inline')

-- The resolved values themselves.
local renderer, passthrough, embed = R({}, CONF)
check('renderer defaults to latex', renderer, 'latex')
check('passthrough defaults to nil/false', not passthrough, true)
check('embed defaults to img', embed, 'img')
renderer, passthrough, embed = R({renderer = 'tikzjax', embed = 'inline',
                                  ['latex-passthrough'] = 'yes'}, CONF)
check('renderer directive honoured', renderer, 'tikzjax')
check('embed directive honoured', embed, 'inline')
check('passthrough directive honoured', passthrough, true)
check('doc-level renderer applies when the block is silent',
  (R({}, {renderer = 'tikzjax'})), 'tikzjax')
check('a rejected block renderer falls back to the doc level, not to latex',
  (R({renderer = 'bogus'}, {renderer = 'tikzjax'})), 'tikzjax')

-- Option reading, all types through the one schema-driven reader. There used
-- to be four: `normalize_enum` for block enums, `meta_string`/`meta_enum` for
-- the document-level half, `truthy` for one boolean, and bare Lua truthiness
-- for two more — so the same YAML meant different things at different levels.
local RO, OPTS = TIKZ_TEST.read_option, TIKZ_TEST.OPTIONS
check('an absent value reads as nil', RO('tex-engine', nil, 'tikz.tex-engine'),
  nil)
check('…and the schema carries the default', OPTS['tex-engine'].default,
  'pdflatex')
check('a present value wins', RO('tex-engine', 'lualatex', 'tikz.tex-engine'),
  'lualatex')
check('an explicitly empty value is not absent',
  RO('tex-engine', '', 'tikz.tex-engine'), '')
check('an unknown option name reads as nil',
  RO('no-such-option', 'x', 'tikz.no-such-option'), nil)

check('a known enum value is kept',
  RO('svg-engine', 'dvisvgm', 'tikz.svg-engine'), 'dvisvgm')
check('an unknown enum value warns and is rejected',
  RO('svg-engine', 'nonsense', 'tikz.svg-engine'), nil)
check('…so the caller falls back to the schema default',
  OPTS['svg-engine'].default, 'inkscape')

-- The booleans. `cache: "true"` was compared with `== true` and silently
-- ignored; `save-tex: "false"` was compared with `or false` and silently
-- switched save-tex ON. Both now travel the same path as latex-passthrough.
check('a YAML boolean', RO('cache', true, 'tikz.cache'), true)
check('the string "true"', RO('cache', 'true', 'tikz.cache'), true)
check('the string "false" is false, not truthy',
  RO('save-tex', 'false', 'tikz.save-tex'), false)
check('"no" is false', RO('save-tex', 'no', 'tikz.save-tex'), false)
check('"0" is false', RO('save-tex', '0', 'tikz.save-tex'), false)
check('an unparseable boolean warns and is rejected',
  RO('cache', 'perhaps', 'tikz.cache'), nil)

-- The list type, which had its own bespoke parser inside `configure`.
check('a whitespace-tokenized command',
  table.concat(RO('svg-command', 'pdf2svg {input} {output}',
    'tikz.svg-command'), '|'), 'pdf2svg|{input}|{output}')
check('an all-whitespace command is rejected',
  RO('svg-command', '   ', 'tikz.svg-command'), nil)
-- A command that names neither placeholder would be run with no PDF to read
-- and would write nothing we could find. A one-element `svg-command` passed
-- the non-empty check and did exactly that.
check('a command with no {input} is rejected',
  RO('svg-command', 'pdf2svg', 'tikz.svg-command'), nil)
check('a command with no {output} is rejected',
  RO('svg-command', 'pdf2svg {input}', 'tikz.svg-command'), nil)
check('a complete command is kept',
  table.concat(RO('svg-command', 'pdf2svg {input} {output}',
    'tikz.svg-command'), ' '), 'pdf2svg {input} {output}')

-- The supported-values list in a diagnostic is the schema's own list, so a
-- message cannot drift from the set it describes. It already had: the strings
-- were typed by hand beside the tables, and the two disagreed.
check('renderer values are declared once',
  table.concat(OPTS['renderer'].values, ', '), 'latex, tikzjax')
check('embed values are declared once',
  table.concat(OPTS['embed'].values, ', '), 'img, inline')
check('svg-engine values are declared once',
  table.concat(OPTS['svg-engine'].values, ', '), 'inkscape, dvisvgm, pdftocairo')


-- The artifact name: one name for a diagram's cache entry, its mediabag file
-- and its `save-tex` directory. Only the cache used to fold the options in;
-- the other two used the bare basename, so two blocks with identical TikZ and
-- different options wrote two correct cache entries and then collapsed onto
-- one mediabag file — the first block displaying the second one's diagram.
local AN, AF = TIKZ_TEST.artifact_name, TIKZ_TEST.artifact_file
local CODE = '\\begin{tikzpicture}\\draw (0,0);\\end{tikzpicture}'

check('the same code and options give the same name',
  AN('d', CODE, {a = '1'}), AN('d', CODE, {a = '1'}))
check('different options give different names',
  AN('d', CODE, {a = '1'}) ~= AN('d', CODE, {a = '2'}), true)
check('different code gives different names',
  AN('d', CODE, {}) ~= AN('d', CODE .. '\\relax', {}), true)
-- The collision as it actually appeared: same code, same explicit filename,
-- different `additionalPackages`.
check('a shared filename does not collide when the options differ',
  AN('shared', CODE, {['additional-packages'] = '\\usepackage{a}'}) ~=
  AN('shared', CODE, {['additional-packages'] = '\\usepackage{b}'}), true)

check('the basename is the label', AN('my-diagram', CODE, {}):match('^[^.]+'),
  'my-diagram')
check('an auto-generated sha1 basename becomes a short literal label',
  AN(pandoc.sha1(CODE), CODE, {}):match('^[^.]+'), 'tikz')
check('a missing basename becomes the same label',
  AN(nil, CODE, {}):match('^[^.]+'), 'tikz')
check('the hash is eight characters',
  #(AN('d', CODE, {}):match('%.(.+)$')), 8)

-- artifact_file takes the already-computed name, so the hash is taken once
-- per diagram rather than once per artifact it produces.
local NAME = AN('d', CODE, {})
check('artifact_file appends the extension', AF(NAME, 'svg'), NAME .. '.svg')
check('the formats differ only by extension',
  (AF(NAME, 'pdf'):gsub('pdf$', 'svg')), AF(NAME, 'svg'))

t.done()
