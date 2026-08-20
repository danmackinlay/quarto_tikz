-- Unit tests for the cache-key encoding (issue #21).
-- Run from the repo root:   pandoc lua tests/test_cache_key.lua

dofile('_extensions/tikz/tikz.lua')
local C = TIKZ_TEST.canonical_options
local failures, checks = 0, 0

local function check(label, got, want)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    io.write(('FAIL %s\n  expected: %s\n  actual:   %s\n')
      :format(label, tostring(want), tostring(got)))
  end
end
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
local H = TIKZ_TEST.hashable_code
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
local CONF = {['tex_engine'] = 'pdflatex', ['svg_engine'] = 'inkscape'}
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
  C(select(4, R({}, {tex_engine = 'lualatex', svg_engine = 'inkscape'}))) ~= bare,
  true)
check('the svg engine is in the key',
  C(select(4, R({}, {tex_engine = 'pdflatex', svg_engine = 'dvisvgm'}))) ~= bare,
  true)
check('the template is in the key',
  C(select(4, R({}, {tex_engine = 'pdflatex', svg_engine = 'inkscape',
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

print(('%d checks, %d failures'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
