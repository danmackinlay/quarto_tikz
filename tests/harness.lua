--[[
Shared assertion harness for the suites under tests/.

Usage, from the repo root:

    local t = dofile('tests/harness.lua')
    t.check('a label', got, want)
    t.done()
]]

local M = { checks = 0, failures = 0 }

-- `%q` for strings, so a trailing space or a stray newline is visible in the
-- diff rather than something you have to infer; `tostring` for everything
-- else, because `%q` raises on a boolean or a nil.
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
