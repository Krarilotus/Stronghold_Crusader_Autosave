# Autosave

A module for [UCP3](https://github.com/UnofficialCrusaderPatch/UnofficialCrusaderPatch3) that
autosaves Stronghold Crusader, and adds delete, restore and "open folder" buttons to the Load
and Save dialogs. Works with `Stronghold Crusader.exe` and `Stronghold_Crusader_Extreme.exe`.

## Features

* **Autosaves** every few minutes into `Autosave_1` .. `Autosave_5`. The game writes a fresh
  save first. An incomplete write leaves the numbered files in place. If a rename fails after
  writing, Autosave restores the numbering where possible and leaves recovery files.
  Game autosaves run in single-player sessions. It pauses while Recorder
  is recording, playing or changing worlds.
  The clock only runs while you actually play - a paused game, an open menu, an inactive game
  window or being outside a game does not count.
* **Controls in the Save dialog**: a box for the interval that shows `5 min` and takes the number
  typed into it, and a button that switches autosaving on and off.
* **Delete** (red cross) moves the selected save or map into a `staged for deletion` folder next
  to it, with the date and time it was deleted in front of its name. Staged files are deleted for
  good at the next game start once they are older than the configured number of days (default 0
  = never). Files Windows refuses to delete stay there for you to remove.
* **Restore** (arrow) brings the most recently deleted file back, then the one before it, and so
  on. A name that is taken in the meantime becomes `... (restored)`.
* **Open folder** opens the save or map folder in Explorer with the selected file highlighted.
* **Map editor**: a named map is autosaved as `<name>_autosave.map` until you save it yourself.

The buttons use the game's own sprites and fonts, so they look like the dialog around them. They
are hidden in multiplayer.

## Map editor

While you edit a map that has been saved or loaded before, a copy of it is autosaved next to it
as **<map name>_autosave.map**, on the same interval. The copy is deleted as soon as you save the
map yourself. A map that has never been saved has no name yet and is not autosaved. Can be
switched off in the UCP3 GUI.

## Installing

Copy this folder into `<game>\ucp\modules\` as `autosave-<version>` (the folder name must carry
the version from `definition.yml`), then enable **Autosave** in the UCP3 GUI.

## Settings

In the UCP3 GUI: whether autosaving starts switched on (default off), how many autosaves to keep
(1-5) whether named editor maps are autosaved, and how many days deleted files are kept (default 0 = never deleted).

The interval, the on/off state and the autosave name live in `settings.txt` in the module's UCP
user data folder (`ucp/userdata/autosave/` in the game's user folder). The Save dialog writes it;
once it exists, its on/off state overrides the GUI default. An older `ucp/autosave-settings.txt`
in the game folder is taken over on first start.

```
enabled = true
minutes = 5
name = Autosave
```

## How it works

Everything is located by pattern scan and works in both exes; no addresses are hardcoded.

* The Load and Save dialogs are menus whose item tables are static data passed to the menu
  constructor. The module copies a table, adds its own items and repoints the constructor at the
  copy.
* The new controls are drawn by the game's own renderers (text box, button, image button), read
  out of the dialog's existing items.
* The interval box uses the game's text input: it moves the input focus to a digits-only text
  slot while it is edited and hands it back afterwards.
* Autosaving calls the game's own save command, the one a multiplayer save runs, with the
  autosave name put into the save dialog's text slot for the duration of the call.
* The timer is a small assembly hook in the main loop, so nothing runs in Lua per frame unless a
  dialog is open.
* File work goes through Windows' ANSI functions (UCP's `io.open` cannot open absolute paths), so
  names with umlauts survive.

See the comments at the top of `init.lua`, `files.lua` and `templates.lua`.

## Licence

MIT, see [LICENSE](LICENSE).
