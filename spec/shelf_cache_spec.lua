package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0

local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

-- In-memory LuaSettings stand-in shared across open() calls so saved state
-- survives a reopen, like the real file-backed implementation.
local files = {}
local broken_paths = {}
local readonly_paths = {}

local Store = {}
Store.__index = Store

function Store:readSetting(key)
    return self.data[key]
end

function Store:saveSetting(key, value)
    self.data[key] = value
    return self
end

function Store:flush()
    if readonly_paths[self.path] then
        error("write failed: " .. self.path)
    end
    files[self.path] = self.data
end

function Store:purge()
    files[self.path] = nil
    self.data = {}
end

package.loaded["luasettings"] = {
    open = function(_class, path)
        if broken_paths[path] then
            error("corrupt settings file: " .. path)
        end
        local data = {}
        for key, value in pairs(files[path] or {}) do
            data[key] = value
        end
        return setmetatable({ path = path, data = data }, Store)
    end,
}

local ShelfCache = require("weread.lib.shelf_cache")

local function fake_settings(data_dir, user_vid)
    return {
        data_dir = data_dir,
        get = function(_self, key, default)
            if key == "account" then
                return { user_vid = user_vid }
            end
            return default
        end,
    }
end

local settings = fake_settings("/data", "vid-1")
local books = {
    { bookId = "book-1", title = "Book One", readUpdateTime = 100 },
    { bookId = "MP_WXS_1", title = "Account One" },
}

-- No cache file yet.
expect(ShelfCache.load(settings) == nil, "load must return nil before any save")

-- Roundtrip across a reopen.
ShelfCache.save(settings, books, 1234)
local cached = ShelfCache.load(settings)
expect(cached ~= nil, "load must return the saved cache")
expect(#cached.books == 2, "cached book count must match")
expect(cached.books[1].bookId == "book-1", "cached book content must match")
expect(cached.synced_at == 1234, "synced_at must roundtrip")

-- A different account must never see the cached shelf.
expect(ShelfCache.load(fake_settings("/data", "vid-2")) == nil,
    "cache written by another account must be ignored")

-- Invalid payloads are not persisted.
ShelfCache.save(settings, nil, 99)
expect(ShelfCache.load(settings).synced_at == 1234,
    "save with non-table books must be a no-op")

-- An empty shelf is treated as no cache so the caller falls back to sync.
ShelfCache.save(fake_settings("/other", "vid-1"), {}, 50)
expect(ShelfCache.load(fake_settings("/other", "vid-1")) == nil,
    "empty cached shelf must load as nil")

-- clear() drops the cache.
ShelfCache.clear(settings)
expect(ShelfCache.load(settings) == nil, "load after clear must return nil")

-- A store that fails to write must degrade silently: the caller holds a
-- freshly fetched shelf and must still be able to present it.
readonly_paths["/readonly/shelf_cache.lua"] = true
local readonly = fake_settings("/readonly", "vid-1")
local save_ok, save_result = pcall(ShelfCache.save, readonly, books, 1)
expect(save_ok, "save on an unwritable store must not raise")
expect(save_result == false, "failed save must report false")

-- A store that fails to open must degrade to "no cache", not raise.
broken_paths["/broken/shelf_cache.lua"] = true
local broken = fake_settings("/broken", "vid-1")
expect(ShelfCache.load(broken) == nil, "unreadable cache must load as nil")
ShelfCache.save(broken, books, 1)
ShelfCache.clear(broken)

-- Auth-error classification for the shelf failure dialog.
local WeRead = require("weread.lib.protocol")
expect(WeRead.is_auth_error("HTTP 401, content_type=application/json, body_bytes=40, error_code=-2010, error_message=用户不存在"),
    "HTTP 401 must classify as auth error")
expect(WeRead.is_auth_error("HTTP 499, error_code=-2010, error_message=用户不存在"),
    "errcode -2010 must classify as auth error")
expect(not WeRead.is_auth_error("HTTP 499, content_type=application/json;charset=utf-8, body_bytes=51, error_code=-202, error_message=-202"),
    "errcode -202 must not classify as auth error")
expect(not WeRead.is_auth_error("error_code=-20100, error_message=other"),
    "-2010 must not match as a prefix of longer codes")
expect(not WeRead.is_auth_error("Too many redirects"),
    "arbitrary error text must not classify as auth error")
expect(not WeRead.is_auth_error(nil), "nil must not classify as auth error")

print(string.format("shelf_cache_spec: %d checks, 0 failure(s)", checks))
