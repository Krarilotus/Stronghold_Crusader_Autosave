-- File handling for the autosave module.
--
-- The game's save paths are ANSI. Use the shared cffi module and Windows
-- file APIs to preserve the native file names while handling absolute paths.

-- A deleted file is moved into a "staged for deletion" folder next to it and renamed to
-- "<YYYY-MM-DD HH.MM.SS>[-n] <original name>". The time is when it was deleted: it decides
-- which file a restore brings back and when the file is removed for good, and the player
-- can read it in the folder.

local files = {}

local STAGING_FOLDER = "staged for deletion"
local STAGED_NAME_PATTERN = "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d)%.(%d%d)%.(%d%d)%-?(%d*) (.+)$"
local STAGED_TIME_FORMAT = "%Y-%m-%d %H.%M.%S"
local SECONDS_PER_DAY = 24 * 60 * 60

local FILE_ATTRIBUTE_DIRECTORY = 0x10
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local INVALID_HANDLE = 0xFFFFFFFF
local PATH_BUFFER_SIZE = 1024
local SW_SHOWNORMAL = 1
local WINEXEC_SUCCESS = 31

local CDEF = [[
typedef struct AutosaveFindData {
  unsigned long attributes;
  unsigned long times[6];
  unsigned long sizeHigh, sizeLow, reserved0, reserved1;
  char name[260];
  char alternateName[14];
} AutosaveFindData;
int __stdcall CreateDirectoryA(const char *path, void *security);
void * __stdcall FindFirstFileA(const char *pattern, AutosaveFindData *data);
int __stdcall FindNextFileA(void *handle, AutosaveFindData *data);
int __stdcall FindClose(void *handle);
unsigned long __stdcall GetFileAttributesA(const char *path);
unsigned long __stdcall GetModuleFileNameA(void *module, char *path, unsigned long size);
unsigned long __stdcall GetCurrentProcessId(void);
int __stdcall MoveFileA(const char *path, const char *target);
int __stdcall DeleteFileA(const char *path);
unsigned int __stdcall WinExec(const char *command, unsigned int show);
unsigned long __stdcall GetLastError(void);
void * __stdcall CreateFileA(const char *path, unsigned long access, unsigned long share,
  void *security, unsigned long disposition, unsigned long flags, void *templateFile);
unsigned long __stdcall GetFileSize(void *file, unsigned long *high);
unsigned long __stdcall SetFilePointer(void *file, long offset, long *high, unsigned long origin);
int __stdcall ReadFile(void *file, void *buffer, unsigned long size, unsigned long *read, void *overlap);
int __stdcall CloseHandle(void *handle);
]]

local ffi, win, gameDirectory

local function canUsePath(path)
  return #path < PATH_BUFFER_SIZE and not path:find("%z")
end

local function invalidHandle(handle)
  return ffi.tonumber(ffi.cast("unsigned long", handle)) == INVALID_HANDLE
end

function files.initialize()
  ffi = modules.cffi:cffi()
  ffi.cdef(CDEF)
  win = ffi.load("kernel32")
  local path = ffi.new("char[?]", PATH_BUFFER_SIZE)
  local length = win.GetModuleFileNameA(nil, path, PATH_BUFFER_SIZE)
  assert(length > 0 and length < PATH_BUFFER_SIZE, "Autosave cannot find the game directory")
  gameDirectory = files.directoryOf(ffi.string(path, length))
end

function files.processId()
  return ffi.tonumber(win.GetCurrentProcessId())
end

function files.withRotationLock(path, publish)
  if not canUsePath(path) then return nil, "lock path too long" end
  local handle = win.CreateFileA(path, 0x40000000, 0, nil, 4, 128, nil)
  if invalidHandle(handle) then return nil, "another instance may be rotating saves" end
  local ok, result, detail = pcall(publish)
  win.CloseHandle(handle)
  if not ok then return nil, result end
  return result, detail
end

function files.validateSave(path, complete)
  if not canUsePath(path) then return false end
  -- Exclusive read succeeds only after the native writer closes the file.
  local file = win.CreateFileA(path, 0x80000000, 0, nil, 3, 128, nil)
  if invalidHandle(file) then return false end
  local ok, valid = pcall(function()
    local high = ffi.new("unsigned long[1]")
    local size = ffi.tonumber(win.GetFileSize(file, high))
    if high[0] ~= 0 or size >= 0x7FFFFFFF then return false end
    local buffer = ffi.new("char[3036]")
    local count = ffi.new("unsigned long[1]")
    return complete(function(offset, length)
      if win.SetFilePointer(file, offset, nil, 0) ~= offset then return nil end
      if win.ReadFile(file, buffer, length, count, nil) == 0 or count[0] ~= length then return nil end
      return ffi.string(buffer, length)
    end, size)
  end)
  local closed = win.CloseHandle(file) ~= 0
  return ok and valid and closed
end

local function lastError()
  return string.format("Windows error %d", win.GetLastError())
end

function files.exists(path)
  if not canUsePath(path) then
    return false
  end
  local attributes = win.GetFileAttributesA(path) & 0xFFFFFFFF
  return attributes ~= INVALID_FILE_ATTRIBUTES and (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0
end

---Renames / moves a file. Returns true, or nil and a reason.
function files.rename(path, target)
  if not canUsePath(path) or not canUsePath(target) then
    return nil, "path too long"
  end
  if win.MoveFileA(path, target) == 0 then
    return nil, lastError()
  end
  return true
end

---Deletes a file for good. Returns true, or nil and a reason.
function files.delete(path)
  if not canUsePath(path) then
    return nil, "path too long"
  end
  if win.DeleteFileA(path) == 0 then
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
  if not canUsePath(command) then
    return false
  end
  return win.WinExec(command, SW_SHOWNORMAL) > WINEXEC_SUCCESS
end

---Names of the files (not folders) in `directory`, which ends with a backslash.
function files.list(directory)
  local names = {}
  local pattern = directory .. "*"
  if not canUsePath(pattern) then return names end
  local data = ffi.new("AutosaveFindData[1]")
  local handle = win.FindFirstFileA(pattern, data)
  if invalidHandle(handle) then return names end
  repeat
    if (data[0].attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 then
      table.insert(names, ffi.string(data[0].name))
    end
  until win.FindNextFileA(handle, data) == 0
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
  local folder = staging:gsub("\\$", "")
  if canUsePath(folder) then
    win.CreateDirectoryA(folder, nil) -- fails harmlessly when it already exists
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
