-- Local cache of the last successful /shelf/sync book list so the bookshelf
-- can open without a network round-trip and remain usable when the sync
-- endpoint fails server-side. Stored outside the main settings file, like the
-- per-book stores, to keep frequent settings flushes small.
local LuaSettings = require("luasettings")

local ShelfCache = {}

local function cache_file(settings)
    return settings.data_dir .. "/shelf_cache.lua"
end

local function account_vid(settings)
    local account = settings:get("account", {})
    return tostring(account.user_vid or "")
end

local function open_store(settings)
    local ok, store = pcall(LuaSettings.open, LuaSettings, cache_file(settings))
    if not ok or type(store) ~= "table" then
        return nil
    end
    return store
end

-- Returns { books = <list>, synced_at = <unix ts> } or nil when there is no
-- usable cache. A cache written by a different account is ignored so a
-- re-login on a shared device never shows someone else's shelf.
function ShelfCache.load(settings)
    local store = open_store(settings)
    if not store then
        return nil
    end
    local books = store:readSetting("books")
    if type(books) ~= "table" or #books == 0 then
        return nil
    end
    if tostring(store:readSetting("user_vid") or "") ~= account_vid(settings) then
        return nil
    end
    return {
        books = books,
        synced_at = tonumber(store:readSetting("synced_at")) or 0,
    }
end

function ShelfCache.save(settings, books, synced_at)
    if type(books) ~= "table" then
        return
    end
    local store = open_store(settings)
    if not store then
        return
    end
    store:saveSetting("books", books)
    store:saveSetting("synced_at", synced_at)
    store:saveSetting("user_vid", account_vid(settings))
    store:flush()
end

function ShelfCache.clear(settings)
    local store = open_store(settings)
    if store then
        store:purge()
    end
end

return ShelfCache
