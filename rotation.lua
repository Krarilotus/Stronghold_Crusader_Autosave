local M = {}

-- The native save action has no success contract. Check the complete native
-- container after it returns, including the section ranges and exact file size.
function M.complete(read, size)
  local function word(offset)
    local bytes = read(offset, 4)
    return bytes and #bytes == 4 and string.unpack("<I4", bytes) or nil
  end
  if word(0) ~= 0xFFFFFFFF then return false end
  local offset = 4
  for _ = 1, 32 do
    local length = word(offset)
    if not length or length > size - offset - 4 then return false end
    offset = offset + 4
    if length == 0 then
      local directory = read(offset, 3036)
      if not directory or #directory ~= 3036 then return false end
      local bytes, payload, sections = string.unpack("<I4I4I4", directory)
      if bytes ~= #directory or payload == 0 or sections < 122 or sections > 150
          or offset + bytes + payload ~= size then return false end
      local nextSection = 0
      for index = 0, sections - 1 do
        local stored = string.unpack("<I4", directory, 633 + index * 4)
        local sectionOffset = string.unpack("<I4", directory, 2433 + index * 4)
        if sectionOffset ~= nextSection then return false end
        nextSection = nextSection + stored
        if nextSection > payload then return false end
      end
      return nextSection == payload
    end
    offset = offset + length
  end
  return false
end

-- Move the previous files only after the new save has passed validation.
-- Keep every displaced file recoverable until promotion succeeds.
function M.publish(files, pending, slot, keep, maximum)
  local moved, surplus = {}, {}
  local function move(from, to)
    if not files.exists(from) then return true end
    local ok, reason = files.rename(from, to)
    if not ok then return nil, reason end
    moved[#moved + 1] = { from, to }
    return true
  end

  local function undo(reason)
    local errors = { tostring(reason) }
    for i = #moved, 1, -1 do
      local from, to = table.unpack(moved[i])
      local ok, failure = files.rename(to, from)
      if not ok then
        errors[#errors + 1] = ("recovery file %s (%s)"):format(to, tostring(failure))
      end
    end
    return nil, table.concat(errors, ". ")
  end

  for n = maximum, keep, -1 do
    local from = slot(n)
    if files.exists(from) then
      local backup = pending:gsub("%.sav$", ("-recovery-%d.sav"):format(n))
      local ok, reason = move(from, backup)
      if not ok then return undo(reason) end
      surplus[#surplus + 1] = backup
    end
  end
  for n = keep - 1, 1, -1 do
    local ok, reason = move(slot(n), slot(n + 1))
    if not ok then return undo(reason) end
  end
  local ok, reason = files.rename(pending, slot(1))
  if not ok then return undo(reason) end
  local retained = {}
  for _, backup in ipairs(surplus) do
    if not files.delete(backup) then retained[#retained + 1] = backup end
  end
  return true, retained
end

return M
