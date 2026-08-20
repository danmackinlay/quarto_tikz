--[[
Shared assertion harness for the suites under tests/.

Every suite used to carry its own copy of the counters, `check`, and the exit
epilogue — four copies of the same twelve lines. They had already drifted:
`test_passthrough` formatted both sides with `%q` and the other three with
`tostring`, so the same mismatch read differently depending on which file you
were looking at, and a trailing space or a stray newline was invisible in
three suites out of four.

Usage, from the repo root:

    local t = dofile('tests/harness.lua')
    t.check('a label', got, want)
    t.done()
]]

local M = { checks = 0, failures = 0 }

-- `%q` for strings, so whitespace differences are visible in the diff rather
-- than something you have to infer; `tostring` for everything else, because
-- `%q` raises on a boolean or a nil — which is what stopped the other three
-- suites adopting the better format.
local function show(v)
  if type(v) == 'string' then return string.format('%q', v) end
  return tostring(v)
end

function M.check(label, got, want)
  M.checks = M.checks + 1
  if got ~= want then
    M.failures = M.failures + 1
    io.write(('FAIL %s\n  expected: %s\n  actual:   %s\n')
      :format(label, show(want), show(got)))
  end
end

-- Substring assertion, used wherever the interesting question is "does the
-- output contain this" rather than "is it exactly this".
function M.has(s, sub) return s:find(sub, 1, true) ~= nil end

function M.done()
  print(('%d checks, %d failures'):format(M.checks, M.failures))
  os.exit(M.failures == 0 and 0 or 1)
end

return M
