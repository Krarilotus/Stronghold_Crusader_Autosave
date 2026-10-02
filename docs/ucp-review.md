# UCP integration review

Autosave settings now use working sliders and short translated text. The in-game buttons follow the game language.

Adds all nine launcher locales, eleven native-game label catalogs, dependencies, aligned defaults and a runtime allowlist. Uses textResourceModifier 0.3.0 after CR.TEX loads; no copied text encoder or new save hook is introduced. Save/file behavior is preserved.

## Remaining native work

Autosave calls the native save action, but rotates/deletes older files before the new save succeeds. Failed writes and failed rotation need recovery validation before release. The private settings file, custom save/load dialog hooks, manual PE/API resolver and ANSI file paths need review against existing config/UI/file owners. Do not claim non-ASCII-path or Recorder support from these packaging changes.

Inspected upstream parent: `1cc1ff7dfd9e9bf42145733f5c57e9dcbb035b1a`. Launcher locales follow
`UCP3-GUI/resources/lang/languages.yaml` (de, en, fr, ru, hu, tr, ch, es, fa).
Category identities follow the current Legacy/GUI catalog, including its existing
English category fallback; setting and description text has full locale entries.
Human translation review and installed GUI/RTL layout checks are pending.

Text reuse: textResourceModifier 0.3.0 at `5ab58fa`, `init.lua` exports
`GetLanguage` and `TransformText`; `textResourceModifier.cpp` reads CR.TEX
and owns UTF-8-to-game-codepage conversion. Framework `content/ucp/code/hooks.lua`
fires `afterInit` immediately before the Windows message loop. The existing
Improved Tunnelers caller uses that phase. Only labels and pointer tables change;
no text dispatch, encoder or game-state owner is duplicated. All eleven native
language catalogs have encodable labels; game font/RTL layout still needs testing.

Offline checks passed: YAML/default consistency, actual GUI control types,
all referenced locale keys, Lua 5.4 syntax and runtime package inputs. Runtime
allowlists exclude research/bench Python. These are not game/editor/save/replay
acceptance. Multiplayer testing belongs to players. No Store release is claimed.
