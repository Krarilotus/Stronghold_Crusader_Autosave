-- Assembly injected by the autosave module (FASM syntax, see core.allocateAssembly).
-- Every name that is not a label is a constant supplied by init.lua. Game functions follow
-- the MSVC ABI, so nothing here relies on eax / ecx / edx surviving a call.

local templates = {}

-- Runs once a frame in the main loop, right after the game ticks, in place of the
-- 5 byte `mov ecx, gameCore` that sets up the isInGameScreen call there.
--
-- Adds the real time since the previous frame to the autosave timer while a single
-- player game is on the map, not paused and no dialog is open (the pause menu, options,
-- the Save dialog ... all stop the clock), and saves once the interval is reached. The frame delta is capped so a loading screen or a stall does not
-- count as playing time.
--
-- It also hands the text focus back if the Save dialog closed (Escape) while the
-- interval box was being edited.
templates.frameHook = [[
pushad
pushfd
call dword [timeGetTimeSlot]
mov edx, eax
sub edx, dword [stateLastTime]
mov dword [stateLastTime], eax
cmp edx, maxFrameMs
jbe delta_capped
mov edx, maxFrameMs
delta_capped:
mov dword [stateDelta], edx
cmp dword [stateFocused], 0
je focus_checked
cmp dword [menuGuard], saveModalId
je focus_checked
call releaseFocus
focus_checked:
cmp dword [stateEnabled], 0
je reset_timer
cmp dword [gameMode2], mapEditorMode
je reset_timer
mov eax, dword [currentGameMode]
cmp eax, scenarioMode
je single_player
cmp eax, skirmishMode
jne reset_timer
single_player:
mov ecx, gameCore
call isInGameScreen
test eax, eax
je reset_timer
cmp dword [gamePaused], 0
jne frame_done
cmp dword [menuGuard], -1
jne frame_done
mov eax, dword [stateElapsed]
add eax, dword [stateDelta]
mov dword [stateElapsed], eax
cmp eax, dword [stateInterval]
jb frame_done
mov dword [stateElapsed], 0
call autosaveRoutine
jmp frame_done
reset_timer:
mov dword [stateElapsed], 0
frame_done:
popfd
popad
mov ecx, gameCore
jmp resumeAddress
]]

-- Saves the game under the autosave name.
--
-- First the older autosaves move up one number (lua). The game's save command then writes
-- <text slot 2>.sav, the slot the Save dialog types into, so the player's own text in that
-- slot (and the text handler's focus fields) is put aside, the autosave name written in,
-- the save run, and everything put back.
templates.autosaveRoutine = [[
push ebx
push esi
push edi
call rotateAutosaves
mov ebx, textHandler
mov eax, dword [ebx + textIndex]
mov dword [snapshot], eax
mov eax, dword [ebx + textActive]
mov dword [snapshot + 4], eax
mov eax, dword [ebx + textReturnPressed]
mov dword [snapshot + 8], eax
mov eax, dword [ebx + textLock]
mov dword [snapshot + 12], eax
mov eax, dword [ebx + nameLength]
mov dword [snapshot + 16], eax
mov eax, dword [ebx + nameCursor]
mov dword [snapshot + 20], eax
cld
lea esi, [ebx + nameText]
mov edi, nameBackup
mov ecx, slotSize
rep movsb
mov esi, saveName
lea edi, [ebx + nameText]
mov ecx, dword [stateNameLength]
inc ecx
rep movsb
mov eax, dword [stateNameLength]
mov dword [ebx + nameLength], eax
mov dword [ebx + nameCursor], eax
push 0
call executeSave
add esp, 4
mov ebx, textHandler
cld
mov esi, nameBackup
lea edi, [ebx + nameText]
mov ecx, slotSize
rep movsb
mov eax, dword [snapshot + 16]
mov dword [ebx + nameLength], eax
mov eax, dword [snapshot + 20]
mov dword [ebx + nameCursor], eax
mov eax, dword [snapshot]
mov dword [ebx + textIndex], eax
mov eax, dword [snapshot + 4]
mov dword [ebx + textActive], eax
mov eax, dword [snapshot + 8]
mov dword [ebx + textReturnPressed], eax
mov eax, dword [snapshot + 12]
mov dword [ebx + textLock], eax
pop edi
pop esi
pop ebx
ret
]]

-- Stands in for one of the Save dialog's own item actions (cdecl, one parameter). Hands
-- the text focus back to the file name first if the interval box has it, then continues
-- into the original action with the stack untouched.
templates.actionWrapper = [[
cmp dword [stateFocused], 0
je run_original
call releaseFocus
run_original:
jmp originalAction
]]

-- Stands in for the Save dialog's Return key item, which runs every frame and saves when
-- Return was pressed in the text box. While the interval box has the focus, Return
-- confirms the interval instead and must not save a game named after the number.
templates.returnKeyWrapper = [[
cmp dword [stateFocused], 0
je run_original
cmp dword [returnPressed], 0
je return_done
mov dword [returnPressed], 0
call releaseFocus
return_done:
ret
run_original:
jmp originalAction
]]

-- Render function of the delete and restore buttons. Draws them with the game's image button
-- renderer (hover frame included) wherever the dialog lists files the buttons can handle,
-- and not at all otherwise. The conditions are the ones the game itself uses to pick the
-- file extension in these dialogs: .map in the main menu's map editor (Load) and in the
-- editor (Save), .sav in single player, .msv in multiplayer (not handled) and .tmp in the
-- unused siege editor (not handled).
templates.fileButtonRender = [[
mov eax, dword [screenId]
cmp eax, siegeEditorScreen
je hide_button
cmp dword [menuGuard], loadModalId
jne save_dialog
cmp eax, scenarioEditorScreen
je show_button
jmp check_mode
save_dialog:
cmp eax, mapEditorScreen
je show_button
check_mode:
mov eax, dword [currentGameMode]
cmp eax, scenarioMode
je show_button
cmp eax, skirmishMode
je show_button
hide_button:
ret
show_button:
jmp imageButtonRenderer
]]

return templates
