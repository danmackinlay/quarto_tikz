-- Unit tests for the pure helpers behind `renderer: latex-passthrough`.
-- Run from the repo root:   pandoc lua tests/test_passthrough.lua
-- No dependencies beyond pandoc, which the extension already requires.

dofile('_extensions/tikz/tikz.lua')
local T = TIKZ_TEST
local failures, checks = 0, 0

local function check(label, got, want)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    io.write(('FAIL %s\n  expected: %s\n  actual:   %s\n')
      :format(label, string.format('%q', want), string.format('%q', got)))
  end
end

-- A block's hoisted preamble, as one newline-joined string.
local function preamble_of(code)
  local preamble = T.prepare_passthrough_body(code)
  return table.concat(preamble, '\n')
end
local function body_of(code)
  local _, body = T.prepare_passthrough_body(code)
  return body
end
local function warn_count(code)
  local _, _, warns = T.prepare_passthrough_body(code)
  return #warns
end

-- code_part: comments are dropped, but `\%` is a literal percent.
check('comment stripped', T.code_part('\\usetikzlibrary{a} % tips'),
  '\\usetikzlibrary{a} ')
check('escaped percent kept', T.code_part('\\node {50\\% done};'),
  '\\node {50\\% done};')

-- match_loader_line: balanced braces, so a line carrying anything else is
-- not a whole-line load and must be left for the copy pass.
check('plain load', (T.match_loader_line('\\usetikzlibrary{calc}')),
  'usetikzlibrary')
check('indented load', (T.match_loader_line('  \\usetikzlibrary{calc}  ')),
  'usetikzlibrary')
check('trailing comment', (T.match_loader_line('\\usetikzlibrary{calc} % x')),
  'usetikzlibrary')
check('optional-arg form', (T.match_loader_line('\\usetikzlibrary[calc]')),
  'usetikzlibrary')
check('sibling loader', (T.match_loader_line('\\usepgfplotslibrary{groupplots}')),
  'usepgfplotslibrary')
check('longer control sequence', T.match_loader_line('\\usetikzlibraryfoo{a}'), nil)
-- Regression: `(.-)}%s*$` matched this and moved \begin{tikzpicture} too.
check('one-line block is not a whole-line load',
  T.match_loader_line('\\usetikzlibrary{a}\\begin{tikzpicture}'), nil)
check('load sharing a line with tikzset',
  T.match_loader_line('\\usetikzlibrary{a} \\tikzset{i/.style={draw,fill=b}}'), nil)

-- split_libs: comma-splitting is a dedup nicety and must never cut a group.
check('split on commas',
  table.concat(T.split_libs('arrows, arrows.meta'), '|'), 'arrows|arrows.meta')
check('no split when braces present',
  table.concat(T.split_libs('i/.style={draw,fill=b}'), '|'), 'i/.style={draw,fill=b}')

-- Whole-line loads are MOVED: hoisted and removed from the body.
check('whole-line load moved (preamble)',
  preamble_of('\\usetikzlibrary{arrows, calc}\n\\begin{tikzpicture}\n\\end{tikzpicture}'),
  '\\usetikzlibrary{arrows}\n\\usetikzlibrary{calc}')
check('whole-line load moved (body)',
  body_of('\\usetikzlibrary{arrows}\n\\begin{tikzpicture}\n\\end{tikzpicture}'),
  '\\begin{tikzpicture}\n\\end{tikzpicture}')

-- Regression for the over-capture bug: the library is hoisted, the picture is
-- NOT, and the body still opens and closes its environment.
check('one-line block: preamble',
  preamble_of('\\usetikzlibrary{arrows}\\begin{tikzpicture}\n\\end{tikzpicture}'),
  '\\usetikzlibrary{arrows}')
check('one-line block: body',
  body_of('\\usetikzlibrary{arrows}\\begin{tikzpicture}\n\\end{tikzpicture}'),
  '\\usetikzlibrary{arrows}\\begin{tikzpicture}\n\\end{tikzpicture}')

-- A load sharing its line is COPIED, never excised: the \tikzset survives
-- verbatim and no bogus library name is invented.
check('shared line: preamble',
  preamble_of('\\usetikzlibrary{arrows} \\tikzset{i/.style={draw,fill=b}}'),
  '\\usetikzlibrary{arrows}')
check('shared line: body untouched',
  body_of('\\usetikzlibrary{arrows} \\tikzset{i/.style={draw,fill=b}}'),
  '\\usetikzlibrary{arrows} \\tikzset{i/.style={draw,fill=b}}')

-- Inside a tikzpicture we only warn: the text may be part of the drawing.
check('load inside a picture is not hoisted',
  preamble_of('\\begin{tikzpicture}\n\\node {\\usetikzlibrary{a}};\n\\end{tikzpicture}'), '')
check('load inside a picture warns',
  warn_count('\\begin{tikzpicture}\n\\node {\\usetikzlibrary{a}};\n\\end{tikzpicture}'), 1)
-- …including when it is alone on its line. Pass 1 used to move this one
-- before any depth was known, so the one construct the function promises to
-- leave alone was the one it silently rewrote — and multi-line node content
-- is exactly where moving it changes the drawing:
--     \\node {
--     \\usetikzlibrary{arrows}
--     };
local IN_PIC = '\\begin{tikzpicture}\n\\usetikzlibrary{arrows}\n' ..
  '\\draw (0,0) -- (1,1);\n\\end{tikzpicture}'
check('an own-line load inside a picture is not hoisted',
  preamble_of(IN_PIC), '')
check('an own-line load inside a picture stays in the body',
  body_of(IN_PIC), IN_PIC)
check('an own-line load inside a picture warns', warn_count(IN_PIC), 1)
-- A picture that opens and closes on one line must not leave depth stuck.
check('a load after a one-line picture is still hoisted',
  preamble_of('\\begin{tikzpicture}\\draw (0,0);\\end{tikzpicture}\n' ..
              '\\usetikzlibrary{arrows}'),
  '\\usetikzlibrary{arrows}')
check('a load before any picture is hoisted',
  preamble_of('\\usetikzlibrary{arrows}\n' ..
              '\\begin{tikzpicture}\\draw (0,0);\\end{tikzpicture}'),
  '\\usetikzlibrary{arrows}')

check('load after a closed picture is hoisted',
  preamble_of('\\begin{tikzpicture}\\end{tikzpicture}\n\\usetikzlibrary{a} \\relax'),
  '\\usetikzlibrary{a}')

-- \usepackage is preamble-only and is never relocated, only reported.
check('usepackage warns', warn_count('\\usepackage{amsmath}\n\\relax'), 1)
check('usepackage not hoisted', preamble_of('\\usepackage{amsmath}\n\\relax'), '')

-- %%| directives are filter input, not LaTeX.
check('directives stripped',
  body_of('%%| caption: hi\n%%|   id: fig-x\n\\begin{tikzpicture}\n\\end{tikzpicture}'),
  '\\begin{tikzpicture}\n\\end{tikzpicture}')
-- A commented-out load is neither hoisted nor warned about.
check('commented load ignored',
  preamble_of('% \\usetikzlibrary{a}\n\\relax'), '')
check('commented load silent', warn_count('% \\usetikzlibrary{a}\n\\relax'), 0)

print(('%d checks, %d failures'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
