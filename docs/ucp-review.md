# UCP integration review

Autosave settings now use working sliders and short translated text. The in-game buttons follow the game language.

Adds all nine launcher locales, eleven native-game label catalogs, dependencies, aligned defaults and a runtime allowlist. Uses textResourceModifier 0.3.0 after CR.TEX loads. Autosave keeps its existing post-tick hook and native save action.

Autosave writes to a fresh name, checks the closed native save's section directory and length, and only then rotates the numbered saves. Conflicting rotations yield to the first instance. After a failed rename, numbered saves are restored where possible and the new file is kept for recovery. Old saves remain available after a failed native write. The native format check catches incomplete files and does not validate gameplay state.

The Recorder input-state API suppresses saves during recording, playback and world transitions. Recorder builds without this API suppress Autosave and log why. File handling uses cffi 1.0.0 to resolve the existing Windows APIs and no longer parses the game or kernel32 PE headers.

## Remaining native work

Failure recovery and playback still need native validation. The private settings file, custom save/load dialog hooks and ANSI file paths need review against existing config/UI/file owners. Accepted ASCII save names and retention defaults are unchanged.

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
