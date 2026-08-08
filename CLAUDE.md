# WeRead KOReader Plugin

## Project Overview

KOReader plugin for reading WeRead (微信读书) books and MP articles on e-ink devices. Lua codebase running inside KOReader's plugin system.

## Language

- Code, variable names, commit messages: English
- User-facing strings: wrapped in `_()` for i18n, Chinese translations in `weread/lib/i18n.lua`
- Communication with user: Simplified Chinese (简体中文)

## Architecture

```
main.lua                       Plugin entry, dependency construction, and module composition
weread/lib/mixin.lua          Collision-safe composition of feature methods into the plugin class
weread/lib/migrations.lua     Settings and per-book storage migrations
weread/lib/plugin_util.lua    Shared translation, logging, error, timing, and file helpers
weread/lib/reader_lifecycle.lua KOReader lifecycle and reader-state orchestration
weread/lib/client.lua         HTTP client (cookie-auth Web API + Bearer-auth gateway API)
weread/lib/book_store.lua     Per-book metadata, reading-state, and article-list persistence
weread/lib/content.lua        Content decoding (e_0/e_1/e_2/e_3), EPUB/HTML generation
weread/lib/footnotes.lua      Network-free book-footnote scanning, indexing, conversion, and validation
weread/lib/cookie.lua         Cookie header parsing and merging
weread/lib/crypto.lua         SHA-256, MD5 (pure Lua)
weread/lib/downloader.lua     Book/chapter download engine (state machine + standby guard)
weread/lib/i18n.lua           Chinese translations (zh table, _() wrapper)
weread/lib/position_mapper.lua Pure KOReader ↔ WeRead chapter/offset mapping
weread/lib/progress_sync.lua  Automatic progress-sync state machine and safety gate
weread/lib/read_report.lua    Reading-report state machine, context refresh, retries
weread/lib/reader_state.lua   Web Reader session and position extraction
weread/lib/settings.lua       Settings persistence via KOReader LuaSettings
weread/lib/protocol.lua       WeRead protocol utilities (encoding, signing, URL helpers)
weread/ui/menu.lua            Main menu and settings menu composition
weread/ui/common.lua          Shared dialog, network-task, and account UI helpers
weread/ui/cache.lua           Cache settings, directory selection, scan, and cleanup flows
weread/ui/library.lua         Bookshelf, book, chapter, public-account, and search flows
weread/ui/read_report.lua     Reading-report settings, target picker, and statistics flow
weread/ui/annotations_controller.lua Annotation visibility and thought-link interaction
weread/ui/reader_navigation.lua End-of-book navigation integration
weread/ui/download_dialog.lua Custom download progress dialog with cancel button
weread/ui/updater.lua        Update dialogs and background-task progress presentation
weread/ui/progress_sync_dialog.lua Progress conflict and sync-result dialogs
weread/ui/thought_popup.lua   Native thought popup entry; rendering in weread/ui/thought_popup/ (bitmap viewport)
```

## Key Conventions

### Module Namespace

- Keep every project-owned Lua module under the `weread/` namespace directory.
- Put non-UI modules in `weread/lib/` and load them with `require("weread.lib.<module>")`.
- Put UI and presentation modules in `weread/ui/` and load them with `require("weread.ui.<module>")`.
- Do not add project-owned modules under root-level `lib/` or `ui/`, and do not use bare `lib.*` or `ui.*` module keys. KOReader-owned imports such as `require("ui/widget/menu")` are not affected.
- Keep only KOReader plugin entry files such as `main.lua` and `_meta.lua` at the plugin root.

### KOReader Plugin API

- Plugin extends `WidgetContainer`, registered via `self.ui.menu:registerToMainMenu(self)`
- UI widgets: `Menu`, `InfoMessage`, `ConfirmBox`, `InputDialog`, `ButtonDialog`
- Event loop: `UIManager:show()`, `UIManager:close()`, `UIManager:scheduleIn()`
- Events: `onReaderReady` (book opened), `onCloseDocument` (book closed), `onFlushSettings`
- **`scheduleIn(0)` blocks the event loop** — use `scheduleIn(0.1)` minimum for cooperative multitasking
- Menu items support: `text`, `mandatory` (right-aligned), `post_text`, `callback`, `checked_func`, `enabled_func`, `sub_item_table_func`, `separator`, `keep_menu_open`
- Menu has built-in pagination (swipe, page indicators, search via page indicator tap)

### Settings Pattern

```lua
local val = self.settings:get("key")  -- reads with default from defaults table
self.settings:set("key", val)
self.settings:flush()                  -- must call to persist
```

### Network Pattern

```lua
self:runNetworkAction(label, function()
    -- runs inside NetworkMgr:runWhenOnline
    -- return string → shown as info; error → shown as error
end)
```

### Translation Pattern

```lua
local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
_("English key")                    -- simple
T(_("Template %1"), value)          -- with substitution (ffi/util.template)

-- In weread/lib/i18n.lua, add to zh table:
["English key"] = "中文翻译",
```

### Loop Variable

Use `_i` (not `_`) in `for _i, item in ipairs(...)` to avoid shadowing the `_()` translation function.

### Menu Maintenance

Whenever a menu item is added, removed, renamed, or moved:

- Update the menu definition in `weread/ui/menu.lua` (or the owning feature UI module)
- Add, rename, or remove the corresponding translation entry in `weread/lib/i18n.lua`; do not leave unused menu translation keys behind
- Keep the menu tree in `README.md` in sync
- Search all three files for the old and new labels before considering the change complete

## Two API Systems

1. **Gateway API** (official, `Bearer` auth with `api_key`): shelf, search, progress, book info
2. **Web API** (cookie auth): chapter content (`e_0`/`e_1`/`e_2`/`e_3`), reading time report, cookie renewal, MP articles

## WeRead API Integration Rules

**For any feature that calls WeRead APIs — especially undocumented/non-public Web APIs (anything NOT in the official gateway/skill):**

1. **Script-first validation**: Write a Python script in `scripts/` to prototype and validate the API interaction
2. **Verify on real data**: Run the script against actual WeRead responses to confirm correctness
3. **Then implement in Lua**: Only after the script validates successfully, implement the equivalent logic in the plugin

This applies to: content decoding, chapter downloading, image/resource packaging, reading time report payloads, cookie renewal, MP article fetching, and any new undocumented endpoint.

Existing reference scripts:
- `scripts/fetch_weread_epub.py` — content decoding + EPUB generation reference
- `scripts/verify_qr_login.py` — QR login, OTP, Cookie, user-info, API-key, and renewal-header verification
- `scripts/verify_mp_articles.py` — MP article API verification

Gateway (official skill) APIs can be called directly without script validation since they have stable, documented behavior.

## Privacy / Security

Never commit or log:
- KOReader `settings/weread.lua`
- Real API keys (`wrk-...`), cookie values (`wr_skey`, `wr_rt`, `wr_vid`, etc.)
- Anti-abuse headers (`x-wrpa-*`)
- Generated EPUB/cache files

Pre-commit scan:
```bash
rg -n "wrk-|wr_skey[=]|wr_rt[=]|wr_vid[=]|ptcz[=]|x-wrpa|thirdwx" -S .
```

## Unimplemented Features (WIP)

These are placeholder menu items shown when a WeRead book is open, currently greyed out:
- Book details — current-book WeRead metadata display
- Notes — read-only WeRead highlights/thoughts

## Reference Docs

- `docs/weread-api-reference.md` — full API endpoint reference (gateway + Web)
- `docs/weread-content-research.md` — content decoding and image packaging research
- `docs/weread-annotations-flow.md` — underline/thought download → embed → tap-to-display flow
- `docs/weread-progress-sync-plan.md` — progress protocol research, mapping, and safety design
