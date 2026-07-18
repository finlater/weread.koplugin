# WeRead KOReader Plugin

## Project Overview

KOReader plugin for reading WeRead (微信读书) books and MP articles on e-ink devices. Lua codebase running inside KOReader's plugin system.

## Language

- Code, variable names, commit messages: English
- User-facing strings: wrapped in `_()` for i18n, Chinese translations in `lib/i18n.lua`
- Communication with user: Simplified Chinese (简体中文)

## Architecture

```
main.lua               Plugin entry and UI/event wiring
lib/client.lua          HTTP client (cookie-auth Web API + Bearer-auth gateway API)
lib/book_store.lua      Per-book metadata, reading-state, and article-list persistence
lib/content.lua         Content decoding (e_0/e_1/e_2/e_3), EPUB/HTML generation
lib/cookie.lua          Cookie header parsing and merging
lib/crypto.lua          SHA-256, MD5 (pure Lua)
lib/downloader.lua      Book/chapter download engine (state machine + standby guard)
lib/i18n.lua            Chinese translations (zh table, _() wrapper)
lib/read_report.lua     Reading-report state machine, context refresh, retries
lib/reader_state.lua    Web Reader session and position extraction
lib/settings.lua        Settings persistence via KOReader LuaSettings
lib/weread.lua          WeRead protocol utilities (encoding, signing, URL helpers)
ui/download_dialog.lua  Custom download progress dialog with cancel button
ui/thought_popup.lua    Underline/thought popup widget (ScrollHtmlWidget, font preheat)
```

## Key Conventions

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
-- In main.lua:
local function _(text) return I18n.tr(text) end
_("English key")                    -- simple
T(_("Template %1"), value)          -- with substitution (ffi/util.template)

-- In lib/i18n.lua, add to zh table:
["English key"] = "中文翻译",
```

### Loop Variable

Use `_i` (not `_`) in `for _i, item in ipairs(...)` to avoid shadowing the `_()` translation function.

### Menu Maintenance

Whenever a menu item is added, removed, renamed, or moved:

- Update the menu definition in `main.lua`
- Add, rename, or remove the corresponding translation entry in `lib/i18n.lua`; do not leave unused menu translation keys behind
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
- Sync progress now — bidirectional progress sync with KOReader location mapping
- Book details — current-book WeRead metadata display
- Notes — read-only WeRead highlights/thoughts

## Reference Docs

- `docs/weread-api-reference.md` — full API endpoint reference (gateway + Web)
- `docs/weread-content-research.md` — content decoding and image packaging research
- `docs/weread-annotations-flow.md` — underline/thought download → embed → tap-to-display flow
