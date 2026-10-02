-- File handling for the autosave module.
--
-- UCP replaces io.open with a resolver that refuses absolute paths, and the saves live under
-- an absolute documents path, so every file operation goes through Windows' own ANSI
-- functions instead: the game's kernel32 imports (CreateDirectoryA, FindFirstFileA,
-- GetFileAttributesA, ...) and, for what the game does not import (MoveFileA, DeleteFileA,
-- WinExec, GetLastError), kernel32's export table. File names therefore come back exactly as
-- the game writes them, including names like "hüpfende dächer test".
--
-- A deleted file is moved into a "staged for deletion" folder next to it and renamed to
-- "<YYYY-MM-DD HH.MM.SS>[-n] <original name>". The time is when it was deleted: it decides
-- which file a restore brings back and when the file is removed for good, and the player
-- can read it in the folder.

local files = {}

local STAGING_FOLDER = "staged for deletion"
local STAGED_NAME_PATTERN = "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d)%.(%d%d)%.(%d%d)%-?(%d*) (.+)$"
local STAGED_TIME_FORMAT = "%Y-%m-%d %H.%M.%S"
local SECONDS_PER_DAY = 24 * 60 * 60

local IMAGE_BASE = 0x400000
local OFFSET_NT_HEADERS = 0x3C
local OFFSET_EXPORT_DIRECTORY = 0x78
local OFFSET_IMPORT_DIRECTORY = 0x80
local IMPORT_DESCRIPTOR_SIZE = 20
local MAX_FORWARDS = 4

local FILE_ATTRIBUTE_DIRECTORY = 0x10
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local FIND_DATA_SIZE = 320
local FIND_DATA_NAME = 0x2C
local INVALID_HANDLE = 0xFFFFFFFF
local PATH_BUFFER_SIZE = 1024
local SW_SHOWNORMAL = 1
local WINEXEC_SUCCESS = 31 -- WinExec returns more than this on success

local win = {}
local pathBuffer, secondPathBuffer, findData, gameDirectory

---The import address table slot of `functionName` from `dllName` in the game exe.
local function findImportSlot(dllName, functionName)
  local ntHeaders = IMAGE_BASE + core.readInteger(IMAGE_BASE + OFFSET_NT_HEADERS)
  local descriptor = IMAGE_BASE + core.readInteger(ntHeaders + OFFSET_IMPORT_DIRECTORY)
  while core.readInteger(descriptor + 12) ~= 0 do
    local dll = core.readString(IMAGE_BASE + core.readInteger(descriptor + 12))
    if dll:lower() == dllName:lower() then
      local lookup = core.readInteger(descriptor)
      local addresses = core.readInteger(descriptor + 16)
      if lookup == 0 then
        lookup = addresses
      end
      local index = 0
      local entry = core.readInteger(IMAGE_BASE + lookup)
      while entry ~= 0 do
        -- a negative entry is an import by ordinal
        if entry > 0 and core.readString(IMAGE_BASE + entry + 2) == functionName then
          return IMAGE_BASE + addresses + index * 4
        end
        index = index + 1
        entry = core.readInteger(IMAGE_BASE + lookup + index * 4)
      end
    end
    descriptor = descriptor + IMPORT_DESCRIPTOR_SIZE
  end
  return nil
end

---A cdecl function that forwards its arguments to a stdcall function, called through the
---pointer at `slot`.
local function stdcallThunk(slot, argumentCount)
  local code = {}
  for _ = 1, argumentCount do
    -- push dword [esp + 4 * argumentCount]: each push moves the next argument into place
    for _, byte in ipairs({ 0xFF, 0x74, 0x24, 4 * argumentCount }) do
      table.insert(code, byte)
    end
  end
  table.insert(code, 0xFF)
  table.insert(code, 0x15)
  for _, byte in ipairs(core.itob(slot)) do
    table.insert(code, byte)
  end
  table.insert(code, 0xC3)
  return core.allocateCode(code)
end

local function exposeStdcall(address, argumentCount)
  local slot = core.allocate(4, true)
  core.writeInteger(slot, address)
  return core.exposeCode(stdcallThunk(slot, argumentCount), argumentCount, 0)
end

local function writeCString(buffer, text)
  if #text >= PATH_BUFFER_SIZE then
    return false
  end
  core.writeString(buffer, text)
  core.writeByte(buffer + #text, 0)
  return true
end

local function writePath(path)
  return writeCString(pathBuffer, path)
end

---The address of `functionName` exported by the module loaded at `base`, following
---forwarders ("OTHER.Function") into other modules.
local function findExport(base, functionName, depth)
  local ntHeaders = base + core.readInteger(base + OFFSET_NT_HEADERS)
  local directoryRva = core.readInteger(ntHeaders + OFFSET_EXPORT_DIRECTORY)
  local directorySize = core.readInteger(ntHeaders + OFFSET_EXPORT_DIRECTORY + 4)
  local directory = base + directoryRva
  local nameCount = core.readInteger(directory + 0x18)
  local functionTable = base + core.readInteger(directory + 0x1C)
  local nameTable = base + core.readInteger(directory + 0x20)
  local ordinalTable = base + core.readInteger(directory + 0x24)
  for index = 0, nameCount - 1 do
    if core.readString(base + core.readInteger(nameTable + index * 4)) == functionName then
      local ordinal = core.readSmallInteger(ordinalTable + index * 2) & 0xFFFF
      local rva = core.readInteger(functionTable + ordinal * 4)
      if rva >= directoryRva and rva < directoryRva + directorySize then
        local dll, forwarded = core.readString(base + rva):match("^(.-)%.(.+)$")
        if dll == nil or depth >= MAX_FORWARDS or not writePath(dll .. ".dll") then
          return nil
        end
        local forwardBase = win.LoadLibraryA(pathBuffer) & 0xFFFFFFFF
        if forwardBase == 0 then
          return nil
        end
        return findExport(forwardBase, forwarded, depth + 1)
      end
      return base + rva
    end
  end
  return nil
end

function files.initialize()
  local imports = {
    { "kernel32.dll", "CreateDirectoryA", 2 }, { "kernel32.dll", "FindFirstFileA", 2 },
    { "kernel32.dll", "FindNextFileA", 2 }, { "kernel32.dll", "FindClose", 1 },
    { "kernel32.dll", "GetFileAttributesA", 1 }, { "kernel32.dll", "GetModuleFileNameA", 3 },
    { "kernel32.dll", "LoadLibraryA", 1 },
  }
  for _, import in ipairs(imports) do
    local slot = findImportSlot(import[1], import[2])
    if slot == nil then
      error("the game does not import " .. import[2])
    end
    win[import[2]] = core.exposeCode(stdcallThunk(slot, import[3]), import[3], 0)
  end
  pathBuffer = core.allocate(PATH_BUFFER_SIZE, true)
  secondPathBuffer = core.allocate(PATH_BUFFER_SIZE, true)
  findData = core.allocate(FIND_DATA_SIZE, true)

  writePath("kernel32.dll")
  local kernel32 = win.LoadLibraryA(pathBuffer) & 0xFFFFFFFF
  for _, export in ipairs({ { "MoveFileA", 2 }, { "DeleteFileA", 1 }, { "WinExec", 2 }, { "GetLastError", 0 } }) do
    local address = kernel32 ~= 0 and findExport(kernel32, export[1], 0) or nil
    if address == nil then
      error("kernel32 does not export " .. export[1])
    end
    win[export[1]] = exposeStdcall(address, export[2])
  end

  -- The game runs in its own folder; relative game paths ("mapsExtreme\") start there.
  local length = win.GetModuleFileNameA(0, pathBuffer, PATH_BUFFER_SIZE)
  gameDirectory = files.directoryOf(core.readString(pathBuffer, length))
end

local function lastError()
  return string.format("Windows error %d", win.GetLastError())
end

function files.exists(path)
  if not writePath(path) then
    return false
  end
  local attributes = win.GetFileAttributesA(pathBuffer) & 0xFFFFFFFF
  return attributes ~= INVALID_FILE_ATTRIBUTES and (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0
end

---Renames / moves a file. Returns true, or nil and a reason.
function files.rename(path, target)
  if not writeCString(pathBuffer, path) or not writeCString(secondPathBuffer, target) then
    return nil, "path too long"
  end
  if win.MoveFileA(pathBuffer, secondPathBuffer) == 0 then
    return nil, lastError()
  end
  return true
end

---Deletes a file for good. Returns true, or nil and a reason.
function files.delete(path)
  if not writePath(path) then
    return nil, "path too long"
  end
  if win.DeleteFileA(pathBuffer) == 0 then
    return nil, lastError()
  end
  return true
end

---"C:\a\b.sav" -> "C:\a\"
function files.directoryOf(path)
  return path:match("^(.*[\\/])[^\\/]*$") or ""
end

---"C:\a\b.sav" -> "b.sav"
function files.nameOf(path)
  return path:match("([^\\/]*)$")
end

function files.absolute(path)
  if path:match("^%a:") or path:match("^[\\/][\\/]") then
    return path
  end
  return gameDirectory .. path
end

---Opens `directory` in Explorer, with `selected` (a file in it) highlighted when given.
function files.openFolder(directory, selected)
  local command
  if selected ~= nil then
    command = 'explorer.exe /select,"' .. files.absolute(selected) .. '"'
  else
    command = 'explorer.exe "' .. files.absolute(directory) .. '"'
  end
  if not writePath(command) then
    return false
  end
  return win.WinExec(pathBuffer, SW_SHOWNORMAL) > WINEXEC_SUCCESS
end

---Names of the files (not folders) in `directory`, which ends with a backslash.
function files.list(directory)
  local names = {}
  if not writePath(directory .. "*") then
    return names
  end
  local handle = win.FindFirstFileA(pathBuffer, findData) & INVALID_HANDLE
  if handle == INVALID_HANDLE then
    return names
  end
  repeat
    if (core.readInteger(findData) & FILE_ATTRIBUTE_DIRECTORY) == 0 then
      table.insert(names, core.readString(findData + FIND_DATA_NAME))
    end
  until win.FindNextFileA(handle, findData) == 0
  win.FindClose(handle)
  return names
end

function files.stagingDirectory(directory)
  return directory .. STAGING_FOLDER .. "\\"
end

---"2026-09-17 14.19.00-2 Quicksave.sav" -> deletion time, number within that second, original name
local function parseStagedName(name)
  local year, month, day, hour, minute, second, counter, original = name:match(STAGED_NAME_PATTERN)
  if year == nil then
    return nil
  end
  return {
    time = os.time({
      year = tonumber(year), month = tonumber(month), day = tonumber(day),
      hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second),
    }),
    counter = tonumber(counter) or 1,
    original = original,
  }
end

---Moves `path` into the staging folder next to it. `related` are the other folders whose
---staged files a restore considers together with this one (a list shows maps from two
---folders). Returns the new path, or nil and a reason.
function files.stage(path, now, related)
  local directory = files.directoryOf(path)
  local staging = files.stagingDirectory(directory)
  if writePath((staging:gsub("\\$", ""))) then
    win.CreateDirectoryA(pathBuffer, 0) -- fails harmlessly when it already exists
  end
  local stamp = os.date(STAGED_TIME_FORMAT, now)
  local name = files.nameOf(path)
  -- Several deletions within one second are numbered, so a restore still takes them back in
  -- the order they were deleted.
  local counter = 0
  local folders = { directory }
  for _, other in ipairs(related or {}) do
    if other:lower() ~= directory:lower() then
      table.insert(folders, other)
    end
  end
  for _, folder in ipairs(folders) do
    for _, existing in ipairs(files.list(files.stagingDirectory(folder))) do
      local entry = parseStagedName(existing)
      if entry ~= nil and existing:sub(1, #stamp) == stamp then
        counter = math.max(counter, entry.counter)
      end
    end
  end
  local target
  repeat
    counter = counter + 1
    if counter == 1 then
      target = staging .. stamp .. " " .. name
    else
      target = string.format("%s%s-%d %s", staging, stamp, counter, name)
    end
  until not files.exists(target)
  local moved, message = files.rename(path, target)
  if not moved then
    return nil, message
  end
  return target
end

---Deletes `path` for good. When Windows refuses, the file is staged instead so the player can
---remove it by hand. Returns "deleted" or "staged" plus the staged path, or nil and a reason.
function files.remove(path, now, related)
  local removed, message = files.delete(path)
  if removed then
    return "deleted"
  end
  local staged = files.stage(path, now, related)
  if staged ~= nil then
    return "staged", staged
  end
  return nil, message
end

---The staged files that belong to `directory`, with the time they were deleted.
function files.stagedFiles(directory)
  local staging = files.stagingDirectory(directory)
  local staged = {}
  for _, name in ipairs(files.list(staging)) do
    local entry = parseStagedName(name)
    if entry ~= nil then
      entry.path = staging .. name
      entry.directory = directory
      table.insert(staged, entry)
    end
  end
  return staged
end

---Moves the most recently deleted `extension` file of `directories` back where it came from.
---A file that took its name in the meantime is kept; the restored one gets " (restored)".
---Returns the restored path, or nil and a reason.
function files.restoreNewest(directories, extension)
  local newest = nil
  for _, directory in ipairs(directories) do
    for _, entry in ipairs(files.stagedFiles(directory)) do
      if entry.original:lower():sub(-#extension) == extension:lower()
        and (newest == nil or entry.time > newest.time
          or (entry.time == newest.time and entry.counter > newest.counter)) then
        newest = entry
      end
    end
  end
  if newest == nil then
    return nil, "nothing to restore"
  end

  local stem = newest.original:sub(1, -#extension - 1)
  local target = newest.directory .. newest.original
  local attempt = 1
  while files.exists(target) do
    local suffix = attempt == 1 and " (restored)" or string.format(" (restored %d)", attempt)
    target = newest.directory .. stem .. suffix .. newest.original:sub(-#extension)
    attempt = attempt + 1
  end
  local moved, message = files.rename(newest.path, target)
  if not moved then
    return nil, message
  end
  return target
end

---Deletes the staged files of `directories` that were deleted at least `days` days before
---`now` (all of them for 0 days). Files Windows will not delete stay for the player.
function files.purgeStaged(directories, days, now)
  local removed, kept = 0, 0
  for _, directory in ipairs(directories) do
    for _, entry in ipairs(files.stagedFiles(directory)) do
      if days <= 0 or now - entry.time >= days * SECONDS_PER_DAY then
        local done, message = files.delete(entry.path)
        if done then
          removed = removed + 1
        else
          kept = kept + 1
          log(WARNING, string.format("autosave: could not delete '%s' (%s), delete it by hand.",
            entry.path, tostring(message)))
        end
      end
    end
  end
  return removed, kept
end

return files
