package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local values = {
    auth_schema_version = 0,
    api_key = "legacy-key",
    cookies = { wr_skey = "legacy-cookie" },
    wr_ticket = "old-ticket",
    wr_wrpa = "legacy-wrpa",
    account = { name = "legacy-user" },
    books = { ["42"] = { cache_dir = "/cache/42" } },
    cache = { download_images = false, book_footnotes_in_popup = true },
    config_loaded = true,
}
local flush_count = 0
local store = {
    readSetting = function(_self, key, default)
        local value = values[key]
        if value == nil then return default end
        return value
    end,
    saveSetting = function(_self, key, value)
        values[key] = value
    end,
    delSetting = function(_self, key)
        values[key] = nil
    end,
    flush = function()
        flush_count = flush_count + 1
    end,
}

package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return "/data" end,
        getSettingsDir = function() return "/settings" end,
    }
end
package.preload["luasettings"] = function()
    return {
        open = function(_self, path)
            expect(path == "/settings/weread.lua", "wrong settings file path")
            return store
        end,
    }
end
package.preload["weread.lib.mock_environment"] = function()
    return { active = function() return { enabled = false } end }
end
local created_dirs = {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        mkdir = function(path)
            created_dirs[#created_dirs + 1] = path
            return true
        end,
    }
end

local saved_books = {}
local minimal_index_checked = false
local loaded_ids, saved_ids = {}, {}
package.preload["weread.lib.book_store"] = function()
    return {
        resolved_dir = function(_settings, _book_id, index) return index.cache_dir end,
        load = function(_settings, book_id, index)
            loaded_ids[#loaded_ids + 1] = book_id
            return {
                book_id = book_id,
                cache_dir = index.cache_dir,
                loaded = true,
            }
        end,
        save = function(_settings, book_id, book)
            saved_books[book_id] = book
            saved_ids[#saved_ids + 1] = book_id
            return true, { cache_dir = "/saved/" .. book_id }
        end,
        is_minimal_index = function(books)
            minimal_index_checked = books == values.books
            return false
        end,
    }
end

local Settings = require("weread.lib.settings")
local settings = Settings:new()

expect(settings.data_dir == "/data/weread", "data directory was wrong")
expect(settings.cache_dir == "/data/weread/cache", "default cache directory was wrong")
expect(settings:get("update").prefer_proxy == true,
    "update proxy should be preferred by default")
expect(settings:get("shelf").paginated == true,
    "bookshelf pagination should be enabled by default")
local thought_popup = settings:get("thought_popup")
expect(thought_popup.height_ratio == 0.70
    and thought_popup.font_size_relative == 0
    and thought_popup.font_size == nil
    and thought_popup.position == "center"
    and thought_popup.width_ratio == 0.8
    and thought_popup.contrast == 9
    and thought_popup.tap_to_page == false,
    "thought popup preferences should use the defaults")
expect(settings:get("shelf").view_mode == "list",
    "bookshelf should default to the low-overhead list view")
expect(created_dirs[1] == "/data/weread"
    and created_dirs[2] == "/data/weread/cache",
    "settings directories were not initialized")
expect(values.api_key == "" and next(values.cookies) == nil
    and values.wr_ticket == "" and values.wr_wrpa == "",
    "legacy authentication data was not invalidated")
expect(values.account.name == "" and values.auth_schema_version == 1,
    "authentication schema migration was incomplete")
expect(values.books["42"].cache_dir == "/cache/42",
    "authentication migration changed the book index")
expect(values.config_loaded == nil, "legacy setting was not removed")
expect(values.cache.download_book_images == false
    and values.cache.download_mp_images == false
    and values.cache.book_footnotes_in_popup == nil
    and values.cache.download_underlines_and_thoughts == false
    and values.cache.prefetch_annotations == false
    and values.cache.auto_prefetch_next_chapter == false
    and values.cache.show_prefetch_notifications == true
    and values.cache.show_annotations == true
    and values.cache.download_images == nil,
    "legacy cache preferences were not migrated")
expect(flush_count == 2,
    "cache and authentication migrations should each flush once")

local books = settings:get_books()
expect(books["42"].loaded and books["42"].book_id == "42",
    "book indexes were not hydrated through BookStore")
expect(not pcall(settings.get, settings, "books") and not pcall(settings.set, settings, "books", {}),
    "get/set of the books key must raise")
expect(select(2, pcall(settings.get, settings, "books")):find("get_book", 1, true),
    "books key error should point at the per-book methods")

settings:put_book("7", { title = "Seven" })
expect(saved_books["7"].title == "Seven" and #saved_ids == 1 and saved_ids[1] == "7",
    "put_book must persist only the requested book through BookStore")
expect(values.books["7"].cache_dir == "/saved/7" and values.books["42"].cache_dir == "/cache/42",
    "put_book must update only its own index entry")

loaded_ids = {}
local seven = settings:get_book("7")
expect(seven.loaded and #loaded_ids == 1 and loaded_ids[1] == "7",
    "get_book must load only the requested book")
expect(settings:get_book(7).book_id == "7", "numeric id lookup must be tolerated")
expect(settings:get_book("missing") == nil and settings:get_book(nil) == nil,
    "unknown book ids return nil")
values.books[99] = { cache_dir = "/cache/99" }
expect(settings:get_book("99").cache_dir == "/cache/99",
    "numeric index keys must be found by string id")
values.books[99] = nil

local loads_before_dirs = #loaded_ids
local dirs = settings:get_book_dirs()
expect(dirs["42"] == "/cache/42" and dirs["7"] == "/saved/7",
    "get_book_dirs must resolve directories from the index")
expect(#loaded_ids == loads_before_dirs, "get_book_dirs must not load book files")

settings:delete_book(7)
expect(values.books["7"] == nil and values.books["42"] ~= nil,
    "delete_book must remove only its own index entry")
expect(#saved_ids == 1, "delete_book must not write book files")
values.large_runtime_data = { "temporary" }
settings:delete("large_runtime_data")
expect(values.large_runtime_data == nil,
    "settings delete did not remove the requested key")
expect(settings:has_legacy_book_records(),
    "legacy book record check was not delegated")
expect(minimal_index_checked, "book index was not passed to BookStore")

settings:update_auth({
    cookies = { wr_gid = "12345" },
    api_key = "new-key",
    account = { name = "new-user" },
})
expect(values.cookies.wr_gid == "12345" and values.api_key == "new-key",
    "authentication update did not persist credentials")
expect(values.account.name == "new-user" and settings:is_api_configured(),
    "authentication account/API state was wrong")
expect(settings:is_cookie_configured(),
    "modern wr_gid login cookie was not recognized")

expect(settings:set_download_dir("/external/books") == "/external/books",
    "custom download directory was not selected")
expect(values.download_dir == "/external/books",
    "custom download directory was not persisted")
expect(settings:set_download_dir("") == "/data/weread/cache",
    "download directory did not reset to default")

local original_environment = getfenv(Settings.get_device_fingerprint)
local random_reads = 0
local random_bytes = string.char(255, 254, 253, 252)
local random_closed = false
local function open_random(path, mode)
    expect(path == "/dev/urandom" and mode == "rb", "wrong randomness source")
    random_reads = random_reads + 1
    return {
        read = function(_self, length)
            expect(length == 4, "fingerprint should use 32 random bits")
            return random_bytes
        end,
        close = function() random_closed = true end,
    }
end
setfenv(Settings.get_device_fingerprint, setmetatable({ io = { open = open_random } }, {
    __index = original_environment,
}))
local before_fingerprint_flush = flush_count
local fingerprint = settings:get_device_fingerprint()
expect(fingerprint == "4294901244" and random_closed,
    "fingerprint must use unsigned decimal format and close the random source")
expect(values.device_fingerprint == fingerprint and flush_count == before_fingerprint_flush + 1,
    "fingerprint must be persisted before login begins")
expect(Settings:new():get_device_fingerprint() == fingerprint and random_reads == 1,
    "reopening settings should reuse the existing fingerprint")

settings:reset_account()
expect(values.api_key == "" and next(values.cookies) == nil
    and values.account.name == "",
    "account reset left credentials behind")
expect(settings:get_device_fingerprint() == fingerprint and random_reads == 1,
    "logout must not rotate the device fingerprint")

values.device_fingerprint = ""
random_bytes = string.char(1, 2, 3, 4)
expect(settings:get_device_fingerprint() ~= fingerprint and random_reads == 2,
    "a separate installation should generate its own fingerprint")
values.device_fingerprint = "invalid; cookie=value"
random_bytes = "short"
local ok = pcall(function() settings:get_device_fingerprint() end)
expect(not ok and values.device_fingerprint == "invalid; cookie=value",
    "failed entropy reads must not save a partial or shared fallback fingerprint")
setfenv(Settings.get_device_fingerprint, original_environment)

print(("settings_spec: %d checks"):format(checks))
