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
  msg and msg:find('not found on PATH', 1, true) ~= nil, true)
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

print(('%d checks, %d failures'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
