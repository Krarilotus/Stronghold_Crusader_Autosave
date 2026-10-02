# Autosave

A module for [UCP3](https://github.com/UnofficialCrusaderPatch/UnofficialCrusaderPatch3) that
autosaves Stronghold Crusader, and adds delete, restore and "open folder" buttons to the Load
and Save dialogs. Works with `Stronghold Crusader.exe` and `Stronghold_Crusader_Extreme.exe`.

## Features

* **Autosaves** every few minutes into `Autosave_1` .. `Autosave_5`. Each new autosave moves the
  older ones up one number; whatever would go past the limit is deleted. Single player only
  (campaign, scenario, skirmish, Crusader trail) and never in the map editor.
  The clock only runs while you actually play - a paused game, an open menu, an inactive game
  window or being outside a game does not count.
* **Controls in the Save dialog**: a box for the interval that shows `5 min` and takes the number
  typed into it, and a button that switches autosaving on and off.
* **Delete** (red cross) moves the selected save or map into a `staged for deletion` folder next
  to it, with the date and time it was deleted in front of its name. Staged files are deleted for
  good at the next game start once they are old enough (default 7 days, 0 = delete immediately).
  Files Windows refuses to delete stay there for you to remove.
* **Restore** (arrow) brings the most recently deleted file back, then the one before it, and so
  on. A name that is taken in the meantime becomes `... (restored)`.
* **Open folder** opens the save or map folder in Explorer with the selected file highlighted.

The buttons use the game's own sprites and fonts, so they look like the dialog around them. They
are hidden in multiplayer.

## Installing

Copy this folder into `<game>\ucp\modules\` as `autosave-<version>` (the folder name must carry
the version from `definition.yml`), then enable **Autosave** in the UCP3 GUI.

## Settings

In the UCP3 GUI: how many autosaves to keep (1-5) and how many days deleted files are kept.

The interval, the on/off state and the autosave name live in `ucp/autosave-settings.txt`:

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

See [the UCP integration review](docs/ucp-review.md) for ownership and remaining acceptance.
