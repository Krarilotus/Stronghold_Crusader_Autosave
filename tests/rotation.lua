local rotation = require("rotation")

local prefix = string.pack("<I4I4I4I4", 0xFFFFFFFF, 4, 0x1234, 0)
local function encodeDirectory()
  local sections, fields, bytes = 122, {}, 0
  for i = 1, 150 do
    local active = i <= sections
    fields[i] = {
      raw = active and 1 or 0,
      stored = active and 1 or 0,
      id = active and 1000 + i or 0,
      compressed = 0,
      offset = active and bytes or 0,
    }
    bytes = bytes + fields[i].stored
  end
  local result = {string.pack("<I4I4I4I4", 3036, bytes, sections, 172), string.rep("\0", 16)}
  for _, field in ipairs({"raw", "stored", "id", "compressed", "offset"}) do
    for _, row in ipairs(fields) do result[#result + 1] = string.pack("<I4", row[field]) end
  end
  result[#result + 1] = string.pack("<I4", 0)
  return table.concat(result), string.rep("p", bytes)
end
local directory, payload = encodeDirectory()
local data = prefix .. directory .. payload
local function complete(bytes)
  return rotation.complete(function(offset, length) return bytes:sub(offset + 1, offset + length) end, #bytes)
end

assert(complete(data))
assert(not complete(data:sub(1, -2)))
assert(not complete(data .. "x"))
assert(not complete("bad" .. data:sub(4)))
local firstOffset = #prefix + 2433
local corrupt = data:sub(1, firstOffset - 1) .. string.pack("<I4", 1) .. data:sub(firstOffset + 4)
assert(not complete(corrupt))

local function simulate(keep, failure)
  local saves = {["pending.sav"]="new", ["1.sav"]="last", ["2.sav"]="older", ["3.sav"]="oldest"}
  local function slot(n) return n .. ".sav" end
  local succeeded = rotation.publish({
    exists = function(path) return saves[path] ~= nil end,
    rename = function(from, to)
      if from == failure or not saves[from] or saves[to] then return nil, "blocked rename" end
      saves[to], saves[from] = saves[from], nil
      return true
    end,
    delete = function(path) saves[path] = nil; return true end,
  }, "pending.sav", slot, keep, 3)
  return succeeded, saves
end

for _, count in ipairs({1, 3}) do
  local ok, saves = simulate(count)
  assert(ok and saves["1.sav"] == "new" and saves["pending.sav"] == nil)
  assert(saves["2.sav"] == (count == 3 and "last" or nil))
  assert(saves["3.sav"] == (count == 3 and "older" or nil))
  for _, failure in ipairs({"3.sav", "2.sav", "1.sav", "pending.sav"}) do
    ok, saves = simulate(count, failure)
    assert(not ok and saves["pending.sav"] == "new" and saves["1.sav"] == "last")
    assert(saves["2.sav"] == "older" and saves["3.sav"] == "oldest")
  end
end
print("Autosave container and rotation checks passed")
