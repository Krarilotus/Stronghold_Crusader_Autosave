# Autosave

Saves your single player game automatically every few minutes, keeps the last few autosaves,
and adds a delete and a restore button to the Load and Save dialogs.

## Autosaves

Open the Save dialog. Above the Save button there are two controls:

* **5 min** - the time between autosaves. Click the box, type a number of minutes (1 to 999)
  and press Enter, or just click somewhere else. "min" is added by itself.
* **Autosave on / Autosave off** - click to switch autosaving on or off.

Autosaves are named **Autosave_1** (the newest) to **Autosave_5**. Each new autosave moves the
older ones up one number; the one that would go past the limit is deleted. How many are kept
(1 to 5) is a UCP setting.

Autosaves only happen while a single player game (campaign, scenario, skirmish, Crusader
trail) is on the map, never in multiplayer or the map editor. The clock only runs while you
play: time in a paused game, with a menu open (Esc menu, options, Load/Save ...), while the
game window is in the background or outside of a game does not count.

## Deleting and restoring saves and maps

The Load and Save dialogs have two small buttons under the title:

* **Red cross** - deletes the selected save (or map in the map editor). The file is moved into
  a **staged for deletion** folder inside its own folder, with the date and time it was
  deleted in front of its name.
* **Arrow** - restores the most recently discarded file of that list. Press it again to restore
  the one before, and so on, as long as the files are still there. If a file with the same
  name exists by then, the restored one is called "... (restored)".

When the game starts, staged files that were discarded at least a set number of days ago
(default 7, a UCP setting) are deleted for good. With 0 days the red cross deletes files
immediately. Files Windows will not let the game delete stay in the staged folder so you can
delete them yourself.

**Open folder** (under the dialog) opens the save or map folder in Explorer, with the selected
file highlighted.

The buttons are hidden in multiplayer.

## Settings file

The interval, on/off and the autosave name are kept in `ucp/autosave-settings.txt`:

```
enabled = true
minutes = 5
name = Autosave
```
