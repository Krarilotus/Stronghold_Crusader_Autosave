-- Autosave
--
-- Saves a running single player game every few minutes into Autosave_1 .. Autosave_N, puts
-- the controls for it into the in-game Save dialog (a box for the interval that shows
-- "5 min" and takes the number typed into it, and a button that switches autosaving on and
-- off), and adds a delete and a restore button to the Load and Save dialogs. Everything uses
-- the game's own drawing, so it looks like the controls next to it.
--
-- Every address is found by pattern scan and is valid for both Stronghold Crusader.exe and
-- Stronghold_Crusader_Extreme.exe:
--
--   * The Load and Save dialogs are Menus whose item tables are static data, handed to the
--     Menu constructor by CRT initializers (`push table / mov ecx, menu / call Menu::Menu`).
--     Copies of the tables with the new items are written to allocated memory and the push
--     operands pointed at them. Nothing else in either exe references the tables.
--   * The drawing functions and their `this` objects are read out of the Save dialog's own
--     item renderers: the file name box (translucent rounded box, white shadowed text at
--     size 0x12, the lime text cursor) and the Save / Back buttons (the stretched button
--     sprite, the centred label and its hover colour). The delete and restore buttons are
--     image items drawn by the game's image button renderer with the build menu's Delete
--     and Undo pictures.
--   * Typing into the interval box uses the game's text input. The text handler has 16
--     slots; slot 6 accepts digits only and is not used by the Save dialog, so the box moves
--     the input focus there while it is edited and back to the file name slot afterwards.
--     The dialog's own actions (Save, Back, the file list, Return) are wrapped so they hand
--     the focus back first, otherwise Return would save a game called "15".
--   * Saving goes through the game's save command, the one a multiplayer save runs: it
--     opens the progress bar and writes <text slot 2>.sav straight away. The name is put
--     into that slot for the duration of the call and the player's text restored after.
--   * The timer runs in assembly in the main loop, right after the game ticks, so nothing
--     calls into lua per frame unless the Save dialog is open.
--   * The selected file of a dialog is resolved the way its Load / Save button does it
--     (list order, file name table, the game's path builder). Delete and restore move files
--     (files.lua) and then run the dialog's own opener again to rebuild the list; the opener
--     keeps the row selection and scroll position.
--
-- The interval, the on/off state and the autosave name are remembered in
-- ucp/autosave-settings.txt. How many autosaves to keep and how long deleted files are kept
-- are UCP settings.

local templates = require("templates")
local files = require("files")

local SETTINGS_FILE = "ucp/autosave-settings.txt"

local DEFAULT_ENABLED = true
local DEFAULT_MINUTES = 5
local DEFAULT_SAVE_NAME = "Autosave"
local MIN_MINUTES = 1
local MAX_MINUTES = 999
local MAX_MINUTE_DIGITS = 3
local MAX_SAVE_NAME_LENGTH = 32 -- what the Save dialog's name box accepts
local MAX_BASE_NAME_LENGTH = MAX_SAVE_NAME_LENGTH - 2 -- room for "_1" .. "_5"

local DEFAULT_VERSIONS = 5
local MAX_VERSIONS = 5
local DEFAULT_DELETE_AFTER_DAYS = 7
local MAX_DELETE_AFTER_DAYS = 3650

local LABELS = require("messages").english
local LABEL_ENABLED = LABELS[1]
local LABEL_DISABLED = LABELS[2]
local MINUTES_SUFFIX = LABELS[3]

-- Position inside the 700 x 397 Save dialog. The Save and Back buttons are at x 50, width
-- 210, height 27, 40 px apart (y 310 and 350); this row sits the same distance above Save
-- and spans the same width.
local MINUTES_BOX = { x = 50, y = 270, width = 80, height = 27 }
local TOGGLE_BUTTON = { x = 140, y = 270, width = 120, height = 27 }

-- Delete and restore sit under the dialog's title banner, right-aligned with the Load
-- dialog's map preview (200 x 200 at 55, 95). Same place in the Save dialog.
local DELETE_BUTTON = { x = 194, y = 71, width = 29, height = 21 }
local RESTORE_BUTTON = { x = 226, y = 70, width = 29, height = 22 }
-- Under the dialog's frame, right-aligned with the file list.
local OPEN_FOLDER_BUTTON = { x = 555, y = 408, width = 140, height = 27 }
local LABEL_OPEN_FOLDER = LABELS[4]

-- Patterns ---------------------------------------------------------------------------------

-- Construction of the dialog modals: push menu / push render / push colour / push 0x200
-- border / push 397 / push 700 / push -1 / push -1 / push id / mov ecx, modal.
local SAVE_MODAL_AOB =
  "68 ? ? ? ? 68 ? ? ? ? 50 68 00 02 00 00 68 8D 01 00 00 68 BC 02 00 00 6A FF 6A FF 6A 0A B9"
local LOAD_MODAL_AOB =
  "68 ? ? ? ? 68 ? ? ? ? 50 68 00 02 00 00 68 8D 01 00 00 68 BC 02 00 00 6A FF 6A FF 6A 09 B9"
local OFFSET_MODAL_MENU = 1

-- The save command (cdecl, 0 = save): opens the progress bar and saves.
local EXECUTE_SAVE_AOB =
  "8B 44 24 04 F7 D8 1B C0 83 E0 0E 83 C0 20 6A 0E B9 ? ? ? ? A3 ? ? ? ? E8 ? ? ? ? C7"

-- Main loop, after the tick loop: mov [msPerTick], eax / mov ecx, gameCore /
-- call isInGameScreen / test eax, eax / je / mov ecx, ... / call.
local FRAME_HOOK_AOB = "A3 ? ? ? ? B9 ? ? ? ? E8 ? ? ? ? 85 C0 74 0A B9 ? ? ? ? E8"
local OFFSET_FRAME_HOOK = 5
local SIZE_FRAME_HOOK = 5

-- Menu item interaction reads timeGetTime through the import slot: mov ebp, [slot].
local TIME_GET_TIME_AOB = "66 83 7E 34 00 55 8B 2D ? ? ? ? 74 13 FF D5 2B 46 40"
local OFFSET_TIME_GET_TIME_SLOT = 8

-- GameMode2 is 1 in the map editor.
local GAME_MODE_2_AOB = "83 3D ? ? ? ? 01 75 0D 6A 04 B9 ? ? ? ? E8 ? ? ? ? C3"
local OFFSET_GAME_MODE_2 = 2

-- Prologue of the in-game key handlers: gameCore (the screen object) and the modal guard,
-- which holds the id of the open dialog and -1 when there is none.
local IN_GAME_GUARD_AOB =
  "F7 C1 00 00 00 40 0F 85 ? ? ? ? B9 ? ? ? ? E8 ? ? ? ? 85 C0 0F 84 ? ? ? ? 83 3D ? ? ? ? FF"
local OFFSET_GAME_CORE = 13
local OFFSET_MENU_GUARD = 32

local IS_IN_GAME_SCREEN_AOB = "8B 41 0C 83 F8 0C 74 0D 83 F8 0E 74 08 83 F8 10 74 03 33 C0 C3"

-- ResourceManager::setPath(this, pathType, fileName): writes the full path of a game file
-- into the buffer of that path type.
local SET_PATH_AOB = "83 EC 24 A1 ? ? ? ? 33 C4 89 44 24 20 53 55 8B 6C 24 34 56 8B 74 24 34 8D 46 FF 83 F8 12"

-- The openers that fill the Load / Save dialog's list: saved games and maps
-- (thiscall on the dialog state, argument = the dialog's modal id).
local GAME_DIALOG_OPENER_AOB = "6A FF 68 ? ? ? ? 64 A1 00 00 00 00 50 83 EC 3C A1 ? ? ? ? 33 C4 89 44 24 38 53 55 56 57 A1 ? ? ? ? 33 C4 50 8D 44 24 50 64 A3 00 00 00 00 A1 ? ? ? ? 33 DB 3B C3 8B F1"
local MAP_DIALOG_OPENER_AOB = "55 56 57 8B F1 C7 05 ? ? ? ? 01 00 00 00 E8 ? ? ? ? 68 80 38 01 00 33 FF 57 68 ? ? ? ? E8 ? ? ? ? 83 C4 0C 68"

-- The game's image button renderer: draws item picture (+1 when hovered) from the image
-- table (lea ecx, [edx + table]).
local IMAGE_BUTTON_RENDERER_AOB = "56 33 F6 39 ? ? ? ? ? 57 74 05"
local IMAGE_TABLE_OPERAND = { 0x24, { 0x8D, 0x8A } }

-- Game values -------------------------------------------------------------------------------

local SAVE_MODAL_ID = 0x0A
local LOAD_MODAL_ID = 0x09
local MAP_EDITOR_MODE = 1 -- GameMode2
local SCENARIO_MODE = 0 -- currentGameMode: campaign missions and custom scenarios
local SKIRMISH_MODE = 0x63 -- currentGameMode: skirmish and the Crusader trail
local OFFSET_GAME_PAUSED = 0x2344 -- GameCore.gamePausedLogical
local OFFSET_SCREEN_ID = 0x0C -- GameCore.currentScreen

-- Screens on which the dialogs list maps instead of saved games.
local SCREEN_SCENARIO_EDITOR = 0x2C -- main menu map editor: Load lists .map
local SCREEN_MAP_EDITOR = 0x11 -- the editor: Save writes .map
local SCREEN_SIEGE_EDITOR = 0x2F -- the unused siege editor: .tmp

local MENU_ITEM_SIZE = 0x50
local MENU_ITEM_LAST_ENTRY = 0x66
local MENU_ITEM_CLICKABLE = 3
local MENU_ITEM_PER_FRAME = 0
local MENU_ITEM_SCROLLBAR = 6
local MENU_ITEM_GROUP_START = 0x1000000
local MENU_ITEM_GROUP_MEMBER = 0x2000000
local MENU_ITEM_RENDER_SIMPLE = 1
local MENU_ITEM_RENDER_IMAGE = 3

local ITEM_TYPE = 0x00
local ITEM_X = 0x04
local ITEM_Y = 0x08
local ITEM_WIDTH = 0x0C
local ITEM_HEIGHT = 0x10
local ITEM_ACTION = 0x14
local ITEM_RENDER = 0x1C
local ITEM_IMAGE = 0x20
local ITEM_RENDER_TYPE = 0x24

-- The Save dialog's item table as both exes ship it.
local SAVE_ITEM_COUNT = 28
local SAVE_ITEM_RETURN_KEY = 0 -- runs every frame, saves when Return was pressed
local SAVE_ITEM_BUTTONS = 2 -- group: scroll arrows, Save, Back
local SAVE_ITEM_FILE_LIST = 7 -- group: the 16 rows of the file list
local SAVE_ITEM_NAME_BOX = 24 -- the file name box
local SAVE_ITEM_LIST_HEADER = 25 -- group: the column headers
local NAME_BOX_WIDTH = 200
local NAME_BOX_HEIGHT = 27

-- ... and the Load dialog's.
local LOAD_ITEM_COUNT = 26
local LOAD_ITEM_SCROLLBAR = 0
local LOAD_ITEM_BUTTONS = 1 -- group: scroll arrows, Load, Back
local LOAD_ITEM_FILE_LIST = 6 -- group: the 16 rows of the file list
local LOAD_ITEM_LIST_HEADER = 23 -- group: the column headers

-- Image table entries (both exes): gm 45 interface_buttons, picture 30 is the build menu's
-- Delete button, picture 69 its Undo button (picture + 1 is the hover frame).
local IMAGE_TABLE_STRIDE = 0x1C
local IMAGE_DELETE = 167
local IMAGE_UNDO = 166
local GM_INTERFACE_BUTTONS = 45
local PICTURE_DELETE = 30
local PICTURE_UNDO = 69

-- UserTextHandler
local TEXT_INDEX = 0x00
local TEXT_ACTIVE = 0x04
local TEXT_RETURN_PRESSED = 0x08
local TEXT_LOCK = 0x0C
local TEXT_MAX_CHARS = 0x50
local TEXT_LENGTH = 0x90
local TEXT_CURSOR = 0xD0
local TEXT_STRINGS = 0x150
local TEXT_SLOT_SIZE = 250
local FILE_NAME_SLOT = 2
local MINUTES_SLOT = 6 -- digits only, unused by the Save dialog

-- MenuTextInputState: the state of the Load / Save dialog's list.
local LIST_KIND = 0x00 -- set by the openers: 1 load game, 2 maps, 3 save game
local LIST_COUNT = 0x74
local LIST_SELECTED_ROW = 0x7C -- -1 when nothing is selected
local LIST_SCROLL = 0x80
local LIST_ORDER = 0x880 -- list position -> file index
local LIST_KIND_LOAD_GAME = 1
local LIST_KIND_MAPS = 2
local LIST_KIND_SAVE_GAME = 3

-- ResourceManager
local FILE_NAMES = 0xBC8 -- per file index, without extension
local PATHS = 0x7AEE0 -- per path type
local NAME_SIZE = 0x3E9
local MAX_FILES = 500
local PATH_TYPE_SAVE = 1
local PATH_TYPE_MAP = 0x0F

-- Where the operands sit in the file name box renderer (identical in both exes).
local NAME_BOX_RENDERER = {
  itemY = { 0x00, { 0xA1 } },
  itemHeight = { 0x05, { 0x8B, 0x0D } },
  itemWidth = { 0x0B, { 0x8B, 0x15 } },
  itemX = { 0x18, { 0x8B, 0x0D } },
  pencil = { 0x23, { 0xB9 } },
  drawRoundedBox = 0x28,
  textHandler = { 0x2D, { 0xB9 } },
  textWidthUntilCursor = 0x32,
  cursorColour = { 0x37, { 0x0F, 0xB7, 0x15 } },
  drawColourBox = 0x69,
  textManager = { 0x9C, { 0xB9 } },
  renderShadowedText = 0xA1,
}
-- Inside textWidthUntilCursor, the call that measures a string up to a cursor.
local WIDTH_UNTIL_CURSOR_CALL = 0x22

-- ... in the Save / Back button renderer ...
local BUTTON_RENDERER = {
  currentGameMode = { 0x00, { 0xA1 } },
  buttonSurface = { 0x5D, { 0xB9 } },
  itemHovered = { 0x62, { 0xC7, 0x05 } },
  renderButtonBackground = 0x6C,
  renderText = 0xE6,
}

-- ... and in the Save dialog's file list action (select a row, copy its name).
local FILE_LIST_ACTION = {
  scroll = { 0x04, { 0xA1 } },
  count = { 0x0B, { 0x3B, 0x05 } },
  selectedRow = { 0x13, { 0x89, 0x0D } },
  order = { 0x19, { 0x8B, 0x0C, 0x85 } },
  resourceManager = { 0x21, { 0xB9 } },
}

local FONT_SIZE = 0x12
local TEXT_BOX_BLEND = 5
local TEXT_COLOUR = 0xFFFFFF
local BUTTON_TEXT_COLOUR = 0xC2F0EB
local BUTTON_TEXT_HOVER_COLOUR = 0xCCFAFF
local ALIGN_LEFT = 0
local ALIGN_CENTRE = 1

-- Shared with the assembly
local STATE_ENABLED = 0x00
local STATE_INTERVAL = 0x04 -- ms
local STATE_ELAPSED = 0x08 -- ms
local STATE_LAST_TIME = 0x0C
local STATE_DELTA = 0x10
local STATE_FOCUSED = 0x14
local STATE_NAME_LENGTH = 0x18
local STATE_SIZE = 0x20
local MAX_FRAME_MS = 1000
local MS_PER_MINUTE = 60000

-- Helpers -----------------------------------------------------------------------------------

local function scan(pattern, purpose)
  local found, address = pcall(core.AOBScan, pattern)
  if not found or address == nil then
    error("could not find " .. purpose)
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (core.readByte(address + index - 1) & 0xFF) ~= byte then
      error(string.format("unexpected code at 0x%X while looking for %s", address, purpose))
    end
  end
end

local function readOperand(functionAddress, site, purpose)
  local offset, opcode = site[1], site[2]
  expectBytes(functionAddress + offset, opcode, purpose)
  return core.readInteger(functionAddress + offset + #opcode)
end

local function readCallTarget(functionAddress, offset, purpose)
  expectBytes(functionAddress + offset, { 0xE8 }, purpose)
  return functionAddress + offset + 5 + core.readInteger(functionAddress + offset + 1)
end

local function writeCString(address, text)
  core.writeString(address, text)
  core.writeByte(address + #text, 0)
end

local function allocateCString(text, size)
  local address = core.allocate(size or (#text + 1), true)
  writeCString(address, text)
  return address
end

-- FASM gets a fixed 64 KB for source, symbols and output: only pass what a script uses.
local function assemble(script, values)
  local used = {}
  for name, value in pairs(values) do
    if script:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  return core.allocateAssembly(script, used)
end

-- A cdecl function with no arguments that runs `callback` in lua (UCP's own trick).
local function luaFunction(purpose, callback)
  local pad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  local reported = false
  core.detourCode(function(registers)
    local ok, message = pcall(callback)
    if not ok and not reported then
      reported = true
      log(WARNING, string.format("autosave: %s failed: %s", purpose, tostring(message)))
    end
    return registers
  end, pad, 5)
  return pad
end

local function clampMinutes(minutes)
  minutes = math.floor(minutes)
  if minutes < MIN_MINUTES then return MIN_MINUTES end
  if minutes > MAX_MINUTES then return MAX_MINUTES end
  return minutes
end

local function integerOption(value, minimum, maximum, default)
  local number = tonumber(value)
  if number == nil then
    return default
  end
  number = math.tointeger(math.floor(number)) or default
  return math.max(minimum, math.min(maximum, number))
end

local function isValidSaveName(name)
  return #name >= 1 and #name <= MAX_BASE_NAME_LENGTH
    and name:match("^[%w _%-%(%)]+$") ~= nil
    and name:match("^%s") == nil and name:match("%s$") == nil
end

-- Settings ----------------------------------------------------------------------------------

local function loadSettings()
  local settings = {
    enabled = DEFAULT_ENABLED,
    minutes = DEFAULT_MINUTES,
    name = DEFAULT_SAVE_NAME,
  }
  local file = io.open(SETTINGS_FILE, "r")
  if file == nil then
    return settings
  end
  for line in file:lines() do
    local key, value = line:match("^%s*([%a_]+)%s*=%s*(.-)%s*$")
    if key == "enabled" then
      settings.enabled = value == "true" or value == "on" or value == "1"
    elseif key == "minutes" then
      local minutes = tonumber(value)
      if minutes ~= nil then
        settings.minutes = clampMinutes(minutes)
      end
    elseif key == "name" then
      if isValidSaveName(value) then
        settings.name = value
      else
        log(WARNING, "autosave: ignoring save name '" .. value .. "' in " .. SETTINGS_FILE)
      end
    end
  end
  file:close()
  return settings
end

local function saveSettings(settings)
  local file, message = io.open(SETTINGS_FILE, "w")
  if file == nil then
    log(WARNING, "autosave: could not write " .. SETTINGS_FILE .. ": " .. tostring(message))
    return
  end
  file:write("# Autosave module settings. The in-game Save dialog updates this file.\n")
  file:write("# name: autosaves are written as <name>_1 .. <name>_5 (letters, digits, space, - _ ( ), at most 30).\n")
  file:write("enabled = " .. tostring(settings.enabled) .. "\n")
  file:write("minutes = " .. tostring(settings.minutes) .. "\n")
  file:write("name = " .. settings.name .. "\n")
  file:close()
end

-- Setup -------------------------------------------------------------------------------------

---Finds a dialog's item table from its modal constructor, checks it has `count` items, and
---returns the table, its static initializer and the menu.
local function resolveDialog(modalPattern, count, purpose)
  local dialog = {}
  dialog.menu = core.readInteger(scan(modalPattern, purpose) + OFFSET_MODAL_MENU)

  local menuBytes = {}
  for index, byte in ipairs(core.itob(dialog.menu)) do
    menuBytes[index] = string.format("%02X", byte & 0xFF)
  end
  dialog.initSite = scan("68 ? ? ? ? B9 " .. table.concat(menuBytes, " ") .. " E8",
    purpose .. "'s item table")
  dialog.itemTable = core.readInteger(dialog.initSite + 1)
  dialog.menuConstructor = readCallTarget(dialog.initSite, 10, "the Menu constructor")

  dialog.item = function(index, offset)
    return core.readInteger(dialog.itemTable + index * MENU_ITEM_SIZE + offset)
  end
  local found = 0
  while found <= count and dialog.item(found, ITEM_TYPE) ~= MENU_ITEM_LAST_ENTRY do
    found = found + 1
  end
  if found ~= count then
    error(purpose .. "'s item table is not the one this module knows")
  end
  dialog.count = count
  return dialog
end

local function resolveGame()
  local game = {}

  local save = resolveDialog(SAVE_MODAL_AOB, SAVE_ITEM_COUNT, "the Save dialog")
  if save.item(SAVE_ITEM_RETURN_KEY, ITEM_TYPE) ~= MENU_ITEM_PER_FRAME
    or save.item(SAVE_ITEM_BUTTONS, ITEM_TYPE) ~= MENU_ITEM_GROUP_START
    or save.item(SAVE_ITEM_FILE_LIST, ITEM_TYPE) ~= MENU_ITEM_GROUP_START
    or save.item(SAVE_ITEM_LIST_HEADER, ITEM_TYPE) ~= MENU_ITEM_GROUP_START
    or save.item(SAVE_ITEM_NAME_BOX, ITEM_TYPE) ~= MENU_ITEM_CLICKABLE
    or save.item(SAVE_ITEM_NAME_BOX, ITEM_RENDER_TYPE) ~= MENU_ITEM_RENDER_SIMPLE
    or save.item(SAVE_ITEM_NAME_BOX, ITEM_WIDTH) ~= NAME_BOX_WIDTH
    or save.item(SAVE_ITEM_NAME_BOX, ITEM_HEIGHT) ~= NAME_BOX_HEIGHT then
    error("the Save dialog's item table is not the one this module knows")
  end
  save.actions = {
    returnKey = save.item(SAVE_ITEM_RETURN_KEY, ITEM_ACTION),
    buttons = save.item(SAVE_ITEM_BUTTONS, ITEM_ACTION),
    fileList = save.item(SAVE_ITEM_FILE_LIST, ITEM_ACTION),
    nameBox = save.item(SAVE_ITEM_NAME_BOX, ITEM_ACTION),
    listHeader = save.item(SAVE_ITEM_LIST_HEADER, ITEM_ACTION),
  }
  game.save = save

  local load = resolveDialog(LOAD_MODAL_AOB, LOAD_ITEM_COUNT, "the Load dialog")
  if load.item(LOAD_ITEM_SCROLLBAR, ITEM_TYPE) ~= MENU_ITEM_SCROLLBAR
    or load.item(LOAD_ITEM_BUTTONS, ITEM_TYPE) ~= MENU_ITEM_GROUP_START
    or load.item(LOAD_ITEM_FILE_LIST, ITEM_TYPE) ~= MENU_ITEM_GROUP_START
    or load.item(LOAD_ITEM_LIST_HEADER, ITEM_TYPE) ~= MENU_ITEM_GROUP_START then
    error("the Load dialog's item table is not the one this module knows")
  end
  game.load = load

  local nameBox = save.item(SAVE_ITEM_NAME_BOX, ITEM_RENDER)
  local r = NAME_BOX_RENDERER
  game.itemX = readOperand(nameBox, r.itemX, "the item position")
  game.itemY = readOperand(nameBox, r.itemY, "the item position")
  game.itemWidth = readOperand(nameBox, r.itemWidth, "the item size")
  game.itemHeight = readOperand(nameBox, r.itemHeight, "the item size")
  game.pencil = readOperand(nameBox, r.pencil, "the pencil")
  game.drawRoundedBox = readCallTarget(nameBox, r.drawRoundedBox, "the text box background")
  game.textHandler = readOperand(nameBox, r.textHandler, "the text handler")
  local widthUntilCursor = readCallTarget(nameBox, r.textWidthUntilCursor, "the cursor position")
  game.textWidthUntil = readCallTarget(widthUntilCursor, WIDTH_UNTIL_CURSOR_CALL, "the text width")
  game.cursorColour = readOperand(nameBox, r.cursorColour, "the cursor colour")
  game.drawColourBox = readCallTarget(nameBox, r.drawColourBox, "the cursor")
  game.textManager = readOperand(nameBox, r.textManager, "the text manager")
  game.renderShadowedText = readCallTarget(nameBox, r.renderShadowedText, "the text renderer")

  local buttons = save.item(SAVE_ITEM_BUTTONS, ITEM_RENDER)
  local b = BUTTON_RENDERER
  game.currentGameMode = readOperand(buttons, b.currentGameMode, "the game mode")
  game.buttonSurface = readOperand(buttons, b.buttonSurface, "the button surface")
  game.itemHovered = readOperand(buttons, b.itemHovered, "the hover flag")
  game.renderButtonBackground = readCallTarget(buttons, b.renderButtonBackground, "the button sprite")
  game.renderText = readCallTarget(buttons, b.renderText, "the button label")

  -- The Return key item tests the text handler's return flag directly.
  expectBytes(save.actions.returnKey, { 0xA1 }, "the Return key")
  game.returnPressed = core.readInteger(save.actions.returnKey + 1)
  if game.returnPressed ~= game.textHandler + TEXT_RETURN_PRESSED then
    error("the Return key does not use the text handler this module knows")
  end

  local l = FILE_LIST_ACTION
  local listScroll = readOperand(save.actions.fileList, l.scroll, "the file list")
  game.listState = listScroll - LIST_SCROLL
  if readOperand(save.actions.fileList, l.count, "the file list") ~= game.listState + LIST_COUNT
    or readOperand(save.actions.fileList, l.selectedRow, "the file list") ~= game.listState + LIST_SELECTED_ROW
    or readOperand(save.actions.fileList, l.order, "the file list") ~= game.listState + LIST_ORDER then
    error("the file list is not the one this module knows")
  end
  game.resourceManager = readOperand(save.actions.fileList, l.resourceManager, "the resource manager")

  game.setPath = scan(SET_PATH_AOB, "the path builder")
  local pathOperand = core.itob(PATHS)
  local pathCode = core.readBytes(game.setPath, 0x60)
  local foundPaths = false
  for index = 1, #pathCode - 3 do
    if (pathCode[index] & 0xFF) == pathOperand[1] and (pathCode[index + 1] & 0xFF) == pathOperand[2]
      and (pathCode[index + 2] & 0xFF) == pathOperand[3] and (pathCode[index + 3] & 0xFF) == pathOperand[4] then
      foundPaths = true
    end
  end
  if not foundPaths then
    error("the path builder does not use the path buffers this module knows")
  end
  game.gameDialogOpener = scan(GAME_DIALOG_OPENER_AOB, "the saved games list")
  game.mapDialogOpener = scan(MAP_DIALOG_OPENER_AOB, "the maps list")

  game.imageButtonRenderer = scan(IMAGE_BUTTON_RENDERER_AOB, "the image button renderer")
  local imageTable = readOperand(game.imageButtonRenderer, IMAGE_TABLE_OPERAND, "the image table")
  for _, image in ipairs({ { IMAGE_DELETE, PICTURE_DELETE }, { IMAGE_UNDO, PICTURE_UNDO } }) do
    local entry = imageTable + image[1] * IMAGE_TABLE_STRIDE
    if core.readInteger(entry) ~= GM_INTERFACE_BUTTONS or core.readInteger(entry + 4) ~= image[2] then
      error("the image table does not hold the Delete / Undo pictures this module knows")
    end
  end

  game.executeSave = scan(EXECUTE_SAVE_AOB, "the save command")
  game.timeGetTimeSlot = core.readInteger(
    scan(TIME_GET_TIME_AOB, "timeGetTime") + OFFSET_TIME_GET_TIME_SLOT)
  game.gameMode2 = core.readInteger(scan(GAME_MODE_2_AOB, "the map editor flag") + OFFSET_GAME_MODE_2)
  local guardSite = scan(IN_GAME_GUARD_AOB, "the in-game guard")
  game.gameCore = core.readInteger(guardSite + OFFSET_GAME_CORE)
  game.menuGuard = core.readInteger(guardSite + OFFSET_MENU_GUARD)
  game.isInGameScreen = scan(IS_IN_GAME_SCREEN_AOB, "isInGameScreen")

  game.frameHook = scan(FRAME_HOOK_AOB, "the main loop") + OFFSET_FRAME_HOOK
  expectBytes(game.frameHook, { 0xB9 }, "the main loop")
  if core.readInteger(game.frameHook + 1) ~= game.gameCore
    or readCallTarget(game.frameHook, 5, "the main loop") ~= game.isInGameScreen then
    error("the main loop is not the one this module knows")
  end

  local extreme = false
  pcall(function() extreme = data.version.isExtreme() end)
  game.gameMapsFolder = extreme and "mapsExtreme\\" or "maps\\"

  return game
end

---Copies a dialog's item table into allocated memory with `newItems` inserted before item
---`insertAt`, and returns the new table and a function that maps a shipped item index to its
---index in the new table.
local function extendItemTable(dialog, insertAt, newItems)
  local newTable = core.allocate((dialog.count + #newItems + 1) * MENU_ITEM_SIZE, true)
  core.writeBytes(newTable, core.readBytes(dialog.itemTable, insertAt * MENU_ITEM_SIZE))
  core.writeBytes(newTable + (insertAt + #newItems) * MENU_ITEM_SIZE,
    core.readBytes(dialog.itemTable + insertAt * MENU_ITEM_SIZE,
      (dialog.count + 1 - insertAt) * MENU_ITEM_SIZE))

  for offset, spec in ipairs(newItems) do
    local address = newTable + (insertAt + offset - 1) * MENU_ITEM_SIZE
    core.writeInteger(address + ITEM_TYPE, MENU_ITEM_CLICKABLE)
    core.writeInteger(address + ITEM_X, spec.box.x)
    core.writeInteger(address + ITEM_Y, spec.box.y)
    core.writeInteger(address + ITEM_WIDTH, spec.box.width)
    core.writeInteger(address + ITEM_HEIGHT, spec.box.height)
    core.writeInteger(address + ITEM_ACTION, spec.action)
    core.writeInteger(address + ITEM_RENDER, spec.render)
    core.writeInteger(address + ITEM_IMAGE, spec.image or 0)
    core.writeInteger(address + ITEM_RENDER_TYPE, spec.renderType)
  end

  local function newIndex(index)
    if index < insertAt then
      return index
    end
    return index + #newItems
  end
  return newTable, newIndex
end

-- A group's members take the first item's action from the Menu constructor, but only where
-- theirs is still 0, which it no longer is once the menu has been built. Set them all.
local function setItemAction(itemTable, index, action)
  core.writeInteger(itemTable + index * MENU_ITEM_SIZE + ITEM_ACTION, action)
  if core.readInteger(itemTable + index * MENU_ITEM_SIZE + ITEM_TYPE) == MENU_ITEM_GROUP_START then
    local member = index + 1
    while (core.readInteger(itemTable + member * MENU_ITEM_SIZE + ITEM_TYPE) & MENU_ITEM_GROUP_MEMBER) ~= 0 do
      core.writeInteger(itemTable + member * MENU_ITEM_SIZE + ITEM_ACTION, action)
      member = member + 1
    end
  end
end

---Points the dialog's static initializer at `newTable`. Should the menu already have been
---built, it is built again the same way.
local function installItemTable(dialog, newTable)
  core.writeCodeInteger(dialog.initSite + 1, newTable)
  local constructMenu = core.exposeCode(dialog.menuConstructor, 2, 1)
  local function ensureMenu()
    if core.readInteger(dialog.menu) == dialog.itemTable then
      constructMenu(dialog.menu, newTable)
    end
  end
  ensureMenu()
  hooks.registerHookCallback("afterInit", ensureMenu)
end

-- Enable ------------------------------------------------------------------------------------

local function enable(settings, options)
  local game = resolveGame()
  files.initialize()

  local textHandler = game.textHandler
  local minutesText = textHandler + TEXT_STRINGS + MINUTES_SLOT * TEXT_SLOT_SIZE

  local drawRoundedBox = core.exposeCode(game.drawRoundedBox, 6, 1)
  local drawColourBox = core.exposeCode(game.drawColourBox, 6, 1)
  local textWidthUntil = core.exposeCode(game.textWidthUntil, 4, 1)
  local renderShadowedText = core.exposeCode(game.renderShadowedText, 10, 1)
  local renderButtonBackground = core.exposeCode(game.renderButtonBackground, 3, 1)
  local renderText = core.exposeCode(game.renderText, 9, 1)
  local setPath = core.exposeCode(game.setPath, 3, 1)
  local openGameDialog = core.exposeCode(game.gameDialogOpener, 2, 1)
  local openMapDialog = core.exposeCode(game.mapDialogOpener, 2, 1)

  local state = core.allocate(STATE_SIZE, true)
  core.writeInteger(state + STATE_ENABLED, settings.enabled and 1 or 0)
  core.writeInteger(state + STATE_INTERVAL, settings.minutes * MS_PER_MINUTE)
  local newestAutosave = settings.name .. "_1"
  core.writeInteger(state + STATE_NAME_LENGTH, #newestAutosave)
  local saveName = allocateCString(newestAutosave, MAX_SAVE_NAME_LENGTH + 1)

  local labelEnabled = allocateCString(LABEL_ENABLED)
  local labelDisabled = allocateCString(LABEL_DISABLED)
  local minutesLabel = core.allocate(16, true)
  local minutesLabelText = nil
  local pathName = core.allocate(NAME_SIZE, true)

  local function isSinglePlayerMode()
    local mode = core.readInteger(game.currentGameMode)
    return mode == SCENARIO_MODE or mode == SKIRMISH_MODE
  end

  local function isSinglePlayerGame()
    return core.readInteger(game.gameMode2) ~= MAP_EDITOR_MODE and isSinglePlayerMode()
  end

  -- Game files --------------------------------------------------------------------------------

  ---The full path the game uses for `fileName` ("x.sav" / "x.map").
  local function gamePath(pathType, fileName)
    if #fileName >= NAME_SIZE then
      return nil
    end
    writeCString(pathName, fileName)
    setPath(game.resourceManager, pathType, pathName)
    return core.readString(game.resourceManager + PATHS + pathType * NAME_SIZE)
  end

  local function saveDirectory()
    return files.directoryOf(gamePath(PATH_TYPE_SAVE, "autosave.sav"))
  end

  ---The folders maps are listed from: the game's own and the one in the documents folder.
  ---An invalid name never exists in the game folder, so the path builder falls back to the
  ---documents folder for it.
  local function mapDirectories()
    local directories = { game.gameMapsFolder }
    local documents = files.directoryOf(gamePath(PATH_TYPE_MAP, "?.map"))
    if documents ~= "" and documents:lower() ~= game.gameMapsFolder:lower() then
      table.insert(directories, documents)
    end
    return directories
  end

  ---What the open dialog lists, decided the way the game decides it in these dialogs, or
  ---nil for lists this module leaves alone (multiplayer .msv, siege editor .tmp).
  local function dialogFiles()
    local modal = core.readInteger(game.menuGuard)
    local screen = core.readInteger(game.gameCore + OFFSET_SCREEN_ID)
    if (modal ~= LOAD_MODAL_ID and modal ~= SAVE_MODAL_ID) or screen == SCREEN_SIEGE_EDITOR then
      return nil
    end
    if (modal == LOAD_MODAL_ID and screen == SCREEN_SCENARIO_EDITOR)
      or (modal == SAVE_MODAL_ID and screen == SCREEN_MAP_EDITOR) then
      return { modal = modal, extension = ".map", pathType = PATH_TYPE_MAP, listKinds = { LIST_KIND_MAPS } }
    end
    if not isSinglePlayerMode() then
      return nil
    end
    return { modal = modal, extension = ".sav", pathType = PATH_TYPE_SAVE,
      listKinds = { LIST_KIND_LOAD_GAME, LIST_KIND_SAVE_GAME } }
  end

  local function selectedFile(context)
    local list = game.listState
    local row = core.readInteger(list + LIST_SELECTED_ROW)
    if row < 0 then
      return nil
    end
    local position = row + core.readInteger(list + LIST_SCROLL)
    if position < 0 or position >= core.readInteger(list + LIST_COUNT) then
      return nil
    end
    local fileIndex = core.readInteger(list + LIST_ORDER + position * 4)
    if fileIndex < 0 or fileIndex >= MAX_FILES then
      return nil
    end
    local name = core.readString(game.resourceManager + FILE_NAMES + fileIndex * NAME_SIZE)
    if name == "" then
      return nil
    end
    return gamePath(context.pathType, name .. context.extension)
  end

  ---Rebuilds the dialog's list with the dialog's own opener.
  local function refreshDialog(context)
    local kind = core.readInteger(game.listState + LIST_KIND)
    for _, listKind in ipairs(context.listKinds) do
      if kind == listKind then
        if kind == LIST_KIND_MAPS then
          openMapDialog(game.listState, context.modal)
        else
          openGameDialog(game.listState, context.modal)
        end
        return
      end
    end
  end

  -- Interval box focus ---------------------------------------------------------------------

  local focus = nil -- what the text handler looked like before the box took the focus

  local function slotField(offset, slot)
    return textHandler + offset + slot * 4
  end

  local function typedDigits()
    local length = core.readInteger(slotField(TEXT_LENGTH, MINUTES_SLOT))
    length = math.max(0, math.min(length, MAX_MINUTE_DIGITS))
    if length == 0 then
      return ""
    end
    return (core.readString(minutesText, length):gsub("%D", ""))
  end

  local function takeFocus()
    if focus ~= nil or not isSinglePlayerGame() then
      return
    end
    focus = {
      index = core.readInteger(textHandler + TEXT_INDEX),
      text = core.readBytes(minutesText, TEXT_SLOT_SIZE),
      length = core.readInteger(slotField(TEXT_LENGTH, MINUTES_SLOT)),
      cursor = core.readInteger(slotField(TEXT_CURSOR, MINUTES_SLOT)),
      maxChars = core.readInteger(slotField(TEXT_MAX_CHARS, MINUTES_SLOT)),
    }
    local digits = tostring(settings.minutes)
    writeCString(minutesText, digits)
    core.writeInteger(slotField(TEXT_LENGTH, MINUTES_SLOT), #digits)
    core.writeInteger(slotField(TEXT_CURSOR, MINUTES_SLOT), #digits)
    core.writeInteger(slotField(TEXT_MAX_CHARS, MINUTES_SLOT), MAX_MINUTE_DIGITS)
    core.writeInteger(textHandler + TEXT_RETURN_PRESSED, 0)
    core.writeInteger(textHandler + TEXT_ACTIVE, 1)
    core.writeInteger(textHandler + TEXT_INDEX, MINUTES_SLOT)
    core.writeInteger(state + STATE_FOCUSED, 1)
  end

  local function releaseFocus()
    core.writeInteger(state + STATE_FOCUSED, 0)
    if focus == nil then
      return
    end

    local minutes = tonumber(typedDigits())
    if minutes ~= nil and minutes >= MIN_MINUTES then
      minutes = clampMinutes(minutes)
      if minutes ~= settings.minutes then
        settings.minutes = minutes
        core.writeInteger(state + STATE_INTERVAL, minutes * MS_PER_MINUTE)
        saveSettings(settings)
      end
    end

    -- Back to the file name, cursor at its end, the way the game returns to the dialog.
    if core.readInteger(textHandler + TEXT_INDEX) == MINUTES_SLOT then
      core.writeInteger(textHandler + TEXT_INDEX, focus.index)
      if focus.index >= 0 and focus.index < 16 then
        core.writeInteger(slotField(TEXT_CURSOR, focus.index),
          core.readInteger(slotField(TEXT_LENGTH, focus.index)))
      end
      core.writeInteger(textHandler + TEXT_RETURN_PRESSED, 0)
    end

    core.writeBytes(minutesText, focus.text)
    core.writeInteger(slotField(TEXT_LENGTH, MINUTES_SLOT), focus.length)
    core.writeInteger(slotField(TEXT_CURSOR, MINUTES_SLOT), focus.cursor)
    core.writeInteger(slotField(TEXT_MAX_CHARS, MINUTES_SLOT), focus.maxChars)
    focus = nil
  end

  local function toggleAutosave()
    if not isSinglePlayerGame() then
      return
    end
    releaseFocus()
    settings.enabled = not settings.enabled
    core.writeInteger(state + STATE_ELAPSED, 0)
    core.writeInteger(state + STATE_ENABLED, settings.enabled and 1 or 0)
    saveSettings(settings)
  end

  -- Delete / restore ---------------------------------------------------------------------------

  ---The folders the files of a dialog's list come from.
  local function listDirectories(context)
    if context.extension == ".map" then
      return mapDirectories()
    end
    return { saveDirectory() }
  end

  local function deleteSelected()
    releaseFocus()
    local context = dialogFiles()
    if context == nil then
      return
    end
    local path = selectedFile(context)
    if path == nil or not files.exists(path) then
      log(WARNING, "autosave: the selected file was not found: " .. tostring(path))
      return
    end
    local now = os.time()
    local directories = listDirectories(context)
    local result, detail
    if options.deleteAfterDays == 0 then
      result, detail = files.remove(path, now, directories)
    else
      local staged, message = files.stage(path, now, directories)
      if staged ~= nil then
        result, detail = "staged", staged
      else
        detail = message
      end
    end
    if result == "deleted" then
      log(INFO, "autosave: deleted " .. path)
    elseif result == "staged" then
      log(INFO, string.format("autosave: moved %s to %s", path, detail))
    else
      log(WARNING, string.format("autosave: could not delete %s: %s", path, tostring(detail)))
      return
    end
    refreshDialog(context)
  end

  local function restoreLatest()
    releaseFocus()
    local context = dialogFiles()
    if context == nil then
      return
    end
    local restored, reason = files.restoreNewest(listDirectories(context), context.extension)
    if restored == nil then
      log(INFO, "autosave: nothing restored: " .. tostring(reason))
      return
    end
    log(INFO, "autosave: restored " .. restored)
    refreshDialog(context)
  end

  ---Opens the folder of the selected file (and selects it), or the folder the dialog saves to.
  local function openFolder()
    releaseFocus()
    local context = dialogFiles()
    if context == nil then
      return
    end
    local selected = selectedFile(context)
    local opened
    if selected ~= nil and files.exists(selected) then
      opened = files.openFolder(files.directoryOf(selected), selected)
    else
      local directories = listDirectories(context)
      opened = files.openFolder(directories[#directories])
    end
    if not opened then
      log(WARNING, "autosave: could not open the folder")
    end
  end

  -- Autosave versions -------------------------------------------------------------------------

  ---Before an autosave: <name>_1 .. <name>_(N-1) move up one number and whatever would end up
  ---past N (or is left over from a larger setting) is deleted for good.
  local function rotateAutosaves()
    local directory = saveDirectory()
    local function autosavePath(number)
      return string.format("%s%s_%d.sav", directory, settings.name, number)
    end
    local now = os.time()
    for number = MAX_VERSIONS, options.versions, -1 do
      local path = autosavePath(number)
      if files.exists(path) then
        local result, detail = files.remove(path, now)
        if result == "staged" then
          log(WARNING, string.format("autosave: could not delete %s, moved it to %s", path, detail))
        elseif result == nil then
          log(WARNING, string.format("autosave: could not delete %s: %s", path, tostring(detail)))
        end
      end
    end
    for number = options.versions - 1, 1, -1 do
      local path = autosavePath(number)
      if files.exists(path) then
        local moved, message = files.rename(path, autosavePath(number + 1))
        if not moved then
          log(WARNING, string.format("autosave: could not rename %s: %s", path, tostring(message)))
        end
      end
    end
  end

  ---At start-up: remove staged files older than the configured number of days.
  local function purgeStagedFiles()
    local directories = { saveDirectory() }
    for _, directory in ipairs(mapDirectories()) do
      table.insert(directories, directory)
    end
    local removed, kept = files.purgeStaged(directories, options.deleteAfterDays, os.time())
    if removed > 0 or kept > 0 then
      log(INFO, string.format("autosave: permanently deleted %d staged file(s), %d could not be deleted.",
        removed, kept))
    end
  end

  -- Drawing ----------------------------------------------------------------------------------

  local function renderMinutesBox()
    if not isSinglePlayerGame() then
      return
    end
    local x = core.readInteger(game.itemX)
    local y = core.readInteger(game.itemY)
    local width = core.readInteger(game.itemWidth)
    local height = core.readInteger(game.itemHeight)

    drawRoundedBox(game.pencil, x, y, x + width, y + height, TEXT_BOX_BLEND)

    local digits
    if focus ~= nil then
      digits = typedDigits()
    else
      digits = tostring(settings.minutes)
    end
    local text = digits .. " " .. MINUTES_SUFFIX
    if text ~= minutesLabelText then
      writeCString(minutesLabel, text)
      minutesLabelText = text
    end
    renderShadowedText(game.textManager, minutesLabel, x + 8, y + 7,
      ALIGN_LEFT, TEXT_COLOUR, 0, FONT_SIZE, 0, 0)

    if focus ~= nil then
      local cursor = core.readInteger(slotField(TEXT_CURSOR, MINUTES_SLOT))
      local cursorX = x + textWidthUntil(game.textManager, minutesText, cursor, FONT_SIZE)
      drawColourBox(game.pencil, cursorX + 6, y + 2, cursorX + 7, y + height - 4,
        core.readSmallInteger(game.cursorColour) & 0xFFFF)
    end
  end

  ---Draws the current item like the Save / Back buttons.
  local function drawButton(label)
    local x = core.readInteger(game.itemX)
    local y = core.readInteger(game.itemY)
    local width = core.readInteger(game.itemWidth)

    renderButtonBackground(game.buttonSurface, 0, -1)
    local colour = BUTTON_TEXT_COLOUR
    if core.readInteger(game.itemHovered) ~= 0 then
      colour = BUTTON_TEXT_HOVER_COLOUR
    end
    renderText(game.textManager, label, x + width // 2, y + 7, ALIGN_CENTRE, colour, FONT_SIZE, 0, 0)
  end

  local function renderToggleButton()
    if isSinglePlayerGame() then
      drawButton(settings.enabled and labelEnabled or labelDisabled)
    end
  end

  local labelOpenFolder = allocateCString(LABEL_OPEN_FOLDER)
  local function renderOpenFolderButton()
    if dialogFiles() ~= nil then
      drawButton(labelOpenFolder)
    end
  end

  -- Assembly --------------------------------------------------------------------------------

  local values = {
    timeGetTimeSlot = game.timeGetTimeSlot,
    menuGuard = game.menuGuard,
    gameMode2 = game.gameMode2,
    currentGameMode = game.currentGameMode,
    gameCore = game.gameCore,
    gamePaused = game.gameCore + OFFSET_GAME_PAUSED,
    screenId = game.gameCore + OFFSET_SCREEN_ID,
    isInGameScreen = game.isInGameScreen,
    executeSave = game.executeSave,
    imageButtonRenderer = game.imageButtonRenderer,
    textHandler = textHandler,
    returnPressed = game.returnPressed,
    stateEnabled = state + STATE_ENABLED,
    stateInterval = state + STATE_INTERVAL,
    stateElapsed = state + STATE_ELAPSED,
    stateLastTime = state + STATE_LAST_TIME,
    stateDelta = state + STATE_DELTA,
    stateFocused = state + STATE_FOCUSED,
    stateNameLength = state + STATE_NAME_LENGTH,
    saveName = saveName,
    snapshot = core.allocate(24, true),
    nameBackup = core.allocate(TEXT_SLOT_SIZE, true),
    releaseFocus = luaFunction("handing back the text focus", releaseFocus),
    rotateAutosaves = luaFunction("renaming the older autosaves", rotateAutosaves),
    saveModalId = SAVE_MODAL_ID,
    loadModalId = LOAD_MODAL_ID,
    mapEditorMode = MAP_EDITOR_MODE,
    scenarioMode = SCENARIO_MODE,
    skirmishMode = SKIRMISH_MODE,
    scenarioEditorScreen = SCREEN_SCENARIO_EDITOR,
    mapEditorScreen = SCREEN_MAP_EDITOR,
    siegeEditorScreen = SCREEN_SIEGE_EDITOR,
    maxFrameMs = MAX_FRAME_MS,
    textIndex = TEXT_INDEX,
    textActive = TEXT_ACTIVE,
    textReturnPressed = TEXT_RETURN_PRESSED,
    textLock = TEXT_LOCK,
    nameText = TEXT_STRINGS + FILE_NAME_SLOT * TEXT_SLOT_SIZE,
    nameLength = TEXT_LENGTH + FILE_NAME_SLOT * 4,
    nameCursor = TEXT_CURSOR + FILE_NAME_SLOT * 4,
    slotSize = TEXT_SLOT_SIZE,
    resumeAddress = game.frameHook + SIZE_FRAME_HOOK,
  }

  values.autosaveRoutine = assemble(templates.autosaveRoutine, values)
  local frameHook = assemble(templates.frameHook, values)
  local fileButtonRender = assemble(templates.fileButtonRender, values)

  local function wrapAction(original, template)
    values.originalAction = original
    return assemble(template or templates.actionWrapper, values)
  end

  -- Item tables -------------------------------------------------------------------------------

  local deleteAction = luaFunction("deleting the selected file", deleteSelected)
  local restoreAction = luaFunction("restoring a deleted file", restoreLatest)
  local openFolderAction = luaFunction("opening the folder", openFolder)
  local openFolderRender = luaFunction("drawing the open folder button", renderOpenFolderButton)
  local function fileButtons()
    return {
      { box = DELETE_BUTTON, action = deleteAction, render = fileButtonRender,
        renderType = MENU_ITEM_RENDER_IMAGE, image = IMAGE_DELETE },
      { box = RESTORE_BUTTON, action = restoreAction, render = fileButtonRender,
        renderType = MENU_ITEM_RENDER_IMAGE, image = IMAGE_UNDO },
      { box = OPEN_FOLDER_BUTTON, action = openFolderAction, render = openFolderRender,
        renderType = MENU_ITEM_RENDER_SIMPLE },
    }
  end

  -- Save dialog: shipped items 0-24, the autosave row, delete and restore, then the column
  -- headers and the end marker.
  local saveItems = {
    { box = MINUTES_BOX, renderType = MENU_ITEM_RENDER_SIMPLE,
      action = luaFunction("focusing the interval box", takeFocus),
      render = luaFunction("drawing the interval box", renderMinutesBox) },
    { box = TOGGLE_BUTTON, renderType = MENU_ITEM_RENDER_SIMPLE,
      action = luaFunction("switching autosave", toggleAutosave),
      render = luaFunction("drawing the autosave button", renderToggleButton) },
  }
  for _, button in ipairs(fileButtons()) do
    table.insert(saveItems, button)
  end
  local saveTable, saveIndex = extendItemTable(game.save, SAVE_ITEM_NAME_BOX + 1, saveItems)
  setItemAction(saveTable, saveIndex(SAVE_ITEM_RETURN_KEY),
    wrapAction(game.save.actions.returnKey, templates.returnKeyWrapper))
  setItemAction(saveTable, saveIndex(SAVE_ITEM_BUTTONS), wrapAction(game.save.actions.buttons))
  setItemAction(saveTable, saveIndex(SAVE_ITEM_FILE_LIST), wrapAction(game.save.actions.fileList))
  setItemAction(saveTable, saveIndex(SAVE_ITEM_NAME_BOX), wrapAction(game.save.actions.nameBox))
  setItemAction(saveTable, saveIndex(SAVE_ITEM_LIST_HEADER), wrapAction(game.save.actions.listHeader))

  -- Load dialog: scrollbar and buttons, delete and restore, then the file list and headers.
  local loadTable = extendItemTable(game.load, LOAD_ITEM_FILE_LIST, fileButtons())

  -- Patch -----------------------------------------------------------------------------------

  installItemTable(game.save, saveTable)
  installItemTable(game.load, loadTable)

  hooks.registerHookCallback("afterInit", function()
    -- CR.TEX is now loaded; the text owner selects and encodes the game language.
    local owner = modules.textResourceModifier
    local texts = require("messages")[owner:GetLanguage():lower()] or LABELS
    local encoded = {}
    for index, text in ipairs(texts) do
      encoded[index] = owner:TransformText(text)
      assert(not encoded[index]:match("^ERROR:"), "autosave: text encoding unavailable")
    end
    labelEnabled = allocateCString(encoded[1])
    labelDisabled = allocateCString(encoded[2])
    MINUTES_SUFFIX = encoded[3]
    labelOpenFolder = allocateCString(encoded[4])
    local ok, message = pcall(purgeStagedFiles)
    if not ok then
      log(WARNING, "autosave: cleaning up staged files failed: " .. tostring(message))
    end
  end)

  core.writeCode(game.frameHook, {
    0xE9, core.itob(core.getRelativeAddress(game.frameHook, frameHook, -5)),
  })

  log(INFO, string.format(
    "autosave: %s, every %d min to '%s_1.sav' .. '_%d', deleted files kept %d day(s).",
    settings.enabled and "on" or "off", settings.minutes, settings.name, options.versions,
    options.deleteAfterDays))
end

return {

  enable = function(self, config)
    config = config or {}
    local options = {
      versions = integerOption(config.versions, 1, MAX_VERSIONS, DEFAULT_VERSIONS),
      deleteAfterDays = integerOption(config.delete_after_days, 0, MAX_DELETE_AFTER_DAYS,
        DEFAULT_DELETE_AFTER_DAYS),
    }
    local settings = loadSettings()
    local ok, message = pcall(enable, settings, options)
    if not ok then
      log(WARNING, "autosave: not active: " .. tostring(message))
    end
  end,

  disable = function(self, config) end,

}
