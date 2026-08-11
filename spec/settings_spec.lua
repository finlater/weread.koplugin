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
    wr_ticket = "legacy-ticket",
    wr_wrpa = "legacy-wrpa",
    account = { name = "legacy-user" },
    books = { ["42"] = { cache_dir = "/cache/42" } },
    cache = { download_images = false },
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
package.preload["weread.lib.book_store"] = function()
    return {
        load = function(_settings, book_id, index)
            return {
                book_id = book_id,
                cache_dir = index.cache_dir,
                loaded = true,
            }
        end,
        save = function(_settings, book_id, book)
            saved_books[book_id] = book
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
    and values.cache.auto_prefetch_next_chapter == false
    and values.cache.show_prefetch_notifications == true
    and values.cache.concurrency_auto == true
    and values.cache.chapter_concurrency == 2
    and values.cache.comment_concurrency == 2
    and values.cache.image_concurrency == 2
    and values.cache.show_annotations == true
    and values.cache.download_images == nil,
    "legacy cache preferences were not migrated")
expect(flush_count == 2,
    "cache and authentication migrations should each flush once")

local books = settings:get("books")
expect(books["42"].loaded and books["42"].book_id == "42",
    "book indexes were not hydrated through BookStore")
settings:set("books", {
    ["7"] = { title = "Seven" },
})
expect(saved_books["7"].title == "Seven",
    "book was not persisted through BookStore")
expect(values.books["7"].cache_dir == "/saved/7",
    "settings did not store the minimal book index")
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

settings:reset_account()
expect(values.api_key == "" and next(values.cookies) == nil
    and values.account.name == "",
    "account reset left credentials behind")

print(("settings_spec: %d checks"):format(checks))
