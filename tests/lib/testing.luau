--!nonstrict
-- Minimal test framework for the Luau CLI.
--
--   local t = require("./lib/testing.luau")
--   t.describe("thing", function()
--     t.it("works", function()
--       t.expect(1 + 1).toBe(2)
--     end)
--   end)
--   t.finish() -- prints a summary; errors (exit code 1) when a test failed

local M = {}

local results = { passed = 0, failed = 0, failures = {} }
local scope = {}

local function fullName(name)
  local parts = table.clone(scope)
  table.insert(parts, name)
  return table.concat(parts, " › ")
end

local function show(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  if type(value) ~= "table" then
    return tostring(value)
  end
  local keys = {}
  for k in value do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in keys do
    table.insert(parts, string.format("%s = %s", tostring(k), show(value[k])))
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function deepEqual(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in a do
    if not deepEqual(v, b[k]) then
      return false
    end
  end
  for k in b do
    if a[k] == nil then
      return false
    end
  end
  return true
end

M.deepEqual = deepEqual

function M.describe(name, fn)
  table.insert(scope, name)
  fn()
  table.remove(scope)
end

function M.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.passed += 1
  else
    results.failed += 1
    table.insert(results.failures, { name = fullName(name), err = tostring(err) })
  end
end

function M.expect(actual)
  local function fail(message)
    error(message, 3)
  end
  local matchers = {}
  function matchers.toBe(expected)
    if actual ~= expected then
      fail(string.format("expected %s to be %s", show(actual), show(expected)))
    end
  end
  function matchers.toEqual(expected)
    if not deepEqual(actual, expected) then
      fail(string.format("expected %s to equal %s", show(actual), show(expected)))
    end
  end
  function matchers.toBeNil()
    if actual ~= nil then
      fail(string.format("expected %s to be nil", show(actual)))
    end
  end
  function matchers.toBeTruthy()
    if not actual then
      fail(string.format("expected %s to be truthy", show(actual)))
    end
  end
  function matchers.toBeFalsy()
    if actual then
      fail(string.format("expected %s to be falsy", show(actual)))
    end
  end
  function matchers.toThrow(pattern)
    local ok, err = pcall(actual)
    if ok then
      fail("expected function to throw")
    elseif pattern and not string.find(tostring(err), pattern) then
      fail(string.format("expected error matching %q, got %q", pattern, tostring(err)))
    end
  end
  return matchers
end

function M.finish()
  for _, failure in results.failures do
    print("  ✗ " .. failure.name)
    print("      " .. failure.err)
  end
  print(string.format("  %d passed, %d failed", results.passed, results.failed))
  if results.failed > 0 then
    error(string.format("%d test(s) failed", results.failed), 0)
  end
end

return M
