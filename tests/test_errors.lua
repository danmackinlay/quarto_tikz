-- Unit tests for the failure paths (issue #30). Hermetic: no TeX or SVG
-- converter needed, because every case here fails at the dependency check.
-- Run from the repo root:   pandoc lua tests/test_errors.lua

dofile('_extensions/tikz/tikz.lua')
local failures, checks = 0, 0

local function check(label, got, want)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    io.write(('FAIL %s\n  expected: %s\n  actual:   %s\n')
      :format(label, tostring(want), tostring(got)))
  end
end

-- write_file must refuse a nil payload rather than let `fh:write` raise.
-- That raise is a genuine runtime error, so unlike `error()` it propagates,
-- and it took the whole render down.
-- os.tmpname() creates the file on some platforms; remove it so the check
-- below tests what write_file did rather than what tmpname did.
local tmp = os.tmpname()
os.remove(tmp)
check('write_file(nil) returns false', TIKZ_TEST.write_file(tmp, nil), false)
check('write_file(nil) creates nothing', io.open(tmp, 'rb') == nil, true)
check('write_file(string) returns true', TIKZ_TEST.write_file(tmp, 'x'), true)
local fh = io.open(tmp, 'rb')
check('write_file round-trips', fh and fh:read('a'), 'x')
if fh then fh:close() end
os.remove(tmp)

-- compile_tikz_to_svg reports expected failures by return value, so the
-- caller can leave one block unrendered and let the document through.
local compile = TIKZ_TEST.compile_tikz_to_svg
local PIC = '\\begin{tikzpicture}\\draw (0,0);\\end{tikzpicture}'

local data, msg = compile(PIC, {}, {
  tex_engine = 'tikz-no-such-tex-engine', output_format = 'svg',
}, 'demo')
check('missing tex engine returns no data', data, nil)
check('missing tex engine explains itself',
  msg and msg:find('not found', 1, true) ~= nil, true)
check('missing tex engine names the engine',
  msg and msg:find('tikz-no-such-tex-engine', 1, true) ~= nil, true)

-- `sh` stands in for a TeX engine that exists, so the second check is reached.
data, msg = compile(PIC, {}, {
  tex_engine = 'sh', output_format = 'svg',
  svg_command = {'tikz-no-such-converter', '{input}', '{output}'},
}, 'demo')
check('missing svg converter returns no data', data, nil)
check('missing svg converter names the command',
  msg and msg:find('tikz-no-such-converter', 1, true) ~= nil, true)

-- For PDF output no converter is needed, so a bogus one must not be checked.
data, msg = compile(PIC, {}, {
  tex_engine = 'tikz-no-such-tex-engine', output_format = 'pdf',
  svg_command = {'tikz-no-such-converter'},
}, 'demo')
check('pdf output does not require the svg converter',
  msg and msg:find('tikz-no-such-tex-engine', 1, true) ~= nil, true)

-- The converter dispatch, without needing any converter installed. This is
-- where `svg-command` overriding `svg-engine` is decided, which is the
-- pairing that used to disagree with the DVI request.
local CC = TIKZ_TEST.convert_command
local FILES = {pdf = 'd.pdf', dvi = 'd.dvi', svg = 'd.svg'}
local function joined(conf)
  local cmd, args = CC(conf, FILES)
  return cmd .. ' ' .. table.concat(args, ' ')
end
check('inkscape is the default', (CC({}, FILES)), 'inkscape')
check('inkscape reads the pdf and writes the svg',
  joined({svg_engine = 'inkscape'}):find('d.pdf', 1, true) ~= nil, true)
check('dvisvgm reads the dvi',
  joined({svg_engine = 'dvisvgm'}):find('d.dvi', 1, true) ~= nil, true)
check('dvisvgm does not read the pdf',
  joined({svg_engine = 'dvisvgm'}):find('d.pdf', 1, true), nil)
check('pdftocairo reads the pdf',
  joined({svg_engine = 'pdftocairo'}), 'pdftocairo -svg d.pdf d.svg')
check('a custom command wins over the engine',
  (CC({svg_engine = 'dvisvgm', svg_command = {'pdf2svg', '{input}', '{output}'}},
      FILES)),
  'pdf2svg')
check('…and its placeholders name the pdf, never the dvi',
  joined({svg_engine = 'dvisvgm',
          svg_command = {'pdf2svg', '{input}', '{output}'}}),
  'pdf2svg d.pdf d.svg')
-- The substitutions are gsub replacements, so a '%' in a user-supplied
-- `%%| filename:` must not be read as a capture reference.
check('a percent in the filename survives substitution',
  (select(2, CC({svg_command = {'x', '{input}'}},
                {pdf = '100%.pdf', dvi = 'd.dvi', svg = 'd.svg'})))[1],
  '100%.pdf')

-- Which intermediate file the TeX run must leave behind. `svg-command`
-- overrides `svg-engine` at conversion time and its {input} names the PDF, so
-- setting both used to produce a DVI and then look for a PDF that was never
-- written — a missing-file error naming neither cause.
local I = TIKZ_TEST.intermediate_format
check('inkscape reads the pdf', I('inkscape', nil), 'pdf')
check('pdftocairo reads the pdf', I('pdftocairo', nil), 'pdf')
check('dvisvgm reads the dvi', I('dvisvgm', nil), 'dvi')
check('a custom command reads the pdf', I('inkscape', {'pdf2svg'}), 'pdf')
check('a custom command reads the pdf even under dvisvgm',
  I('dvisvgm', {'pdf2svg', '{input}', '{output}'}), 'pdf')

-- The dependency probe searches PATH itself. It used to ask a shell
-- (`command -v`), which put a metadata-controlled string inside a shell
-- command and, because `command -v` is a POSIX builtin, reported every
-- program as missing under cmd.exe.
local F = TIKZ_TEST.find_executable
check('finds something that is certainly on PATH', F('sh'), true)
check('does not find something that is certainly not',
  F('tikz-no-such-binary-anywhere'), false)
-- An absolute path is taken at face value rather than looked up.
check('an absolute path that exists', F('/bin/sh'), true)
check('an absolute path that does not', F('/bin/tikz-no-such-binary'), false)
-- A shell metacharacter is now just part of a name that does not exist,
-- rather than something a shell would act on.
check('a shell pipeline is not a program', F('sh; echo pwned'), false)
check('a relative path with a separator is not looked up on PATH',
  F('./sh'), false)
-- The answer is memoized, so it must still be the same answer.
check('memoized probe agrees', TIKZ_TEST.check_dependency('sh'), true)
check('memoized probe agrees on a miss',
  TIKZ_TEST.check_dependency('tikz-no-such-binary-anywhere'), false)
check('memoized probe is stable across calls',
  TIKZ_TEST.check_dependency('sh'), true)

-- Diagnostics must survive the absence of Quarto. This suite runs under
-- `pandoc lua`, where the `quarto` global does not exist, so every check
-- below would previously have died with "attempt to index a nil value
-- (global 'quarto')" — the filter aborting while trying to report a mistake.
local ok, err = pcall(TIKZ_TEST.normalize_renderer, 'bogus', '%%| renderer:')
check('warning path does not raise without quarto', ok, true)
check('unknown renderer is rejected', err, nil)
check('known renderer survives',
  TIKZ_TEST.normalize_renderer('tikzjax', '%%| renderer:'), 'tikzjax')
ok, err = pcall(TIKZ_TEST.normalize_embed, 'bogus', '%%| embed:')
check('embed warning path does not raise without quarto', ok, true)
check('unknown embed is rejected', err, nil)
-- The retired renderer name has its own migration warning; same crash before.
ok = pcall(TIKZ_TEST.normalize_renderer, 'latex-passthrough', 'tikz.renderer')
check('migration warning does not raise without quarto', ok, true)

print(('%d checks, %d failures'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
