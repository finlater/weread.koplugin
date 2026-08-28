local DataStorage = require("datastorage")
local BookStore = require("weread.lib.book_store")
local Cookie = require("weread.lib.cookie")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local ok_time, time = pcall(require, "ui/time")
if not ok_time then
    time = { now = function() return 0 end }
end
local PluginUtil = require("weread.lib.plugin_util")
local perf = PluginUtil.perf or function() end

local Settings = {}
Settings.__index = Settings
Settings.AUTH_SCHEMA_VERSION = 1

local defaults = {
    auth_schema_version = Settings.AUTH_SCHEMA_VERSION,
    api_key = "",
    cookies = {},
    wr_ticket = "",
    wr_wrpa = "",
    account = {
        name = "",
        user_vid = "",
        login_method = "",
        login_time = 0,
    },
    books = {},
    downloads = {},
    sync = {
        pull_on_open = false,
        upload_on_close = false,
        ask_on_conflict = true,
        upload_interval_minutes = 0,
    },
    cache = {
        download_book_images = true,
        download_mp_images = false,
        book_footnotes_in_popup = false,
        download_underlines_and_thoughts = false,
        auto_prefetch_next_chapter = false,
        show_prefetch_notifications = true,
        show_annotations = true,
        -- When true, taps in the left/right edge zones never open thought popups
        -- (and native #wrthought link follow is suppressed there too).
        ignore_edge_thought_taps = true,
        -- Fraction of screen width on each side treated as the page-turn edge zone.
        edge_tap_ratio = 0.20,
        max_size_mb = 1024,
    },
    read_report = {
        enabled = false,
        mode = "manual",
        book_id = "",
        book_title = "",
        interval_seconds = 30,
        report_on_open = true,
    },
    advanced = {
        developer_logs = false,
    },
    update = {
        -- auto: prefer GitHub release, fall back to branch zipball
        channel = "auto",
        branch = "main",
        -- ghspeedup.com | gh-proxy.com | ghfast.top | direct | custom
        proxy_id = "ghspeedup.com",
        custom_proxy = "",
        check_on_start = false,
        last_check = 0,
        last_remote_version = "",
        last_remote_source = "",
        installed_version = "",
        installed_source = "",
    },
    shelf = {
        sort_order = "time_desc",
        paginated = true,
        view_mode = "list",
    },
    download_dir = "",
    -- Sidecar root for thoughts.db / catalog / metadata / MP articles.
    -- Kept separate from download_dir so EPUB files can sit flat in the library.
    meta_dir = "",
}


local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

local function clear_auth_store(store)
    store:saveSetting("api_key", "")
    store:saveSetting("cookies", {})
    store:saveSetting("wr_ticket", "")
    store:saveSetting("wr_wrpa", "")
    store:saveSetting("account", deepcopy(defaults.account))
end

function Settings:new()
    local data_dir = DataStorage:getFullDataDir() .. "/weread"
    ensure_dir(data_dir)
    local obj = {
        data_dir = data_dir,
        default_cache_dir = data_dir .. "/cache",
        -- Default metadata lives under KOReader data, NOT under the book library.
        default_meta_dir = data_dir .. "/meta",
        settings_file = DataStorage:getSettingsDir() .. "/weread.lua",
    }
    obj.store = LuaSettings:open(obj.settings_file)
    -- cache_dir / download_dir: flat EPUB library root (e.g. /mnt/base-us/books)
    local download_dir = obj.store:readSetting("download_dir", "")
    obj.cache_dir = (type(download_dir) == "string" and download_dir ~= "") and download_dir or obj.default_cache_dir
    ensure_dir(obj.cache_dir)
    -- meta_dir: per-bookId sidecar folders (thoughts/catalog/metadata/MP html)
    local meta_dir = obj.store:readSetting("meta_dir", "")
    obj.meta_dir = (type(meta_dir) == "string" and meta_dir ~= "") and meta_dir or obj.default_meta_dir
    -- Guard: never default metadata into the book library root.
    if obj.meta_dir == obj.cache_dir then
        obj.meta_dir = obj.default_meta_dir
        obj.store:saveSetting("meta_dir", "")
    end
    ensure_dir(obj.meta_dir)
    local cache = obj.store:readSetting("cache", deepcopy(defaults.cache))
    local cache_changed = false
    if cache.download_book_images == nil then
        cache.download_book_images = cache.download_images ~= false
        cache_changed = true
    end
    if cache.download_mp_images == nil then
        cache.download_mp_images = false
        cache_changed = true
    end
    if cache.book_footnotes_in_popup == nil then
        cache.book_footnotes_in_popup = false
        cache_changed = true
    end
    if cache.download_underlines_and_thoughts == nil then
        cache.download_underlines_and_thoughts = false
        cache_changed = true
    end
    if cache.auto_prefetch_next_chapter == nil then
        cache.auto_prefetch_next_chapter = false
        cache_changed = true
    end
    if cache.show_prefetch_notifications == nil then
        cache.show_prefetch_notifications = true
        cache_changed = true
    end
    if cache.show_annotations == nil then
        cache.show_annotations = true
        cache_changed = true
    end
    if cache.ignore_edge_thought_taps == nil then
        cache.ignore_edge_thought_taps = true
        cache_changed = true
    end
    if cache.edge_tap_ratio == nil then
        cache.edge_tap_ratio = 0.20
        cache_changed = true
    end
    if cache.download_images ~= nil then
        cache.download_images = nil
        cache_changed = true
    end
    if cache_changed then
        obj.store:saveSetting("cache", cache)
        obj.store:flush()
    end
    local legacy_changed = false
    for _, key in ipairs({
        "config_auth_fingerprint",
        "config_preferences_fingerprint",
        "config_loaded",
        "curl_payload",
    }) do
        if obj.store:readSetting(key, nil) ~= nil then
            if type(obj.store.delSetting) == "function" then
                obj.store:delSetting(key)
            else
                obj.store:saveSetting(key, nil)
            end
            legacy_changed = true
        end
    end
    local stored_auth_version = tonumber(obj.store:readSetting("auth_schema_version", 0)) or 0
    if stored_auth_version < Settings.AUTH_SCHEMA_VERSION then
        -- Authentication before schema v1 may have come from legacy manual
        -- flows and has no reliable QR account provenance.
        -- Invalidate only credentials; books, downloads and user preferences
        -- remain intact and the UI will guide the user through a fresh QR login.
        clear_auth_store(obj.store)
        obj.store:saveSetting("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        legacy_changed = true
    end
    if legacy_changed then
        obj.store:flush()
    end
    return setmetatable(obj, self)
end

function Settings:find_book_id_by_path(file_path)
    local started = time.now()
    if type(file_path) ~= "string" or file_path == "" then
        perf("path_index.invalid", started)
        return nil
    end

    -- Read only the compact raw index. Do not hydrate every BookStore record
    -- while KOReader is still opening the current document.
    local indexes = self.store:readSetting("books", {})
    for book_id, index in pairs(indexes or {}) do
        if type(index) == "table" then
            if index.cached_file == file_path then
                perf("path_index.hit", started, "kind=full_book")
                return tostring(book_id)
            end
            for _uid, chapter_path in pairs(index.cached_chapters or {}) do
                if chapter_path == file_path then
                    perf("path_index.hit", started, "kind=chapter")
                    return tostring(book_id)
                end
            end
        end
    end
    perf("path_index.miss", started)
    return nil
end

function Settings:update_book(book_id, patch)
    local total_started = time.now()
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then
        perf("update_book.invalid", total_started)
        return false
    end

    -- Hydrate and persist only the requested book. The old get/set("books")
    -- path rewrites every book and is too expensive for reader lifecycle state.
    local index_started = time.now()
    local indexes = self.store:readSetting("books", {})
    local numeric_id = tonumber(book_id)
    local current_index = indexes[book_id]
        or (numeric_id and indexes[numeric_id])
        or {}
    perf("update_book.read_index", index_started, "book=", book_id)

    local load_started = time.now()
    local book = BookStore.load(self, book_id, current_index)
    perf("update_book.load_book", load_started, "book=", book_id)

    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = value
        end
    end

    local save_started = time.now()
    local ok, new_index = BookStore.save(self, book_id, book)
    perf("update_book.save_book", save_started, "book=", book_id)
    if not ok then
        error("Could not save book data: " .. tostring(new_index))
    end

    indexes[book_id] = new_index
    if numeric_id and numeric_id ~= book_id then
        indexes[numeric_id] = nil
    end
    local flush_started = time.now()
    self.store:saveSetting("books", indexes)
    self.store:flush()
    perf("update_book.flush", flush_started, "book=", book_id)
    perf("update_book.total", total_started, "book=", book_id)
    return true
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    if key ~= "books" then
        return self.store:readSetting(key, deepcopy(default))
    end
    local indexes = self.store:readSetting("books", {})
    local books = {}
    for book_id, index in pairs(indexes or {}) do
        books[book_id] = BookStore.load(self, book_id, index)
    end
    return books
end

function Settings:set(key, value)
    if key == "books" and type(value) == "table" then
        local indexes = {}
        for book_id, book in pairs(value) do
            local ok, index_or_err = BookStore.save(self, book_id, book)
            if not ok then
                error("Could not save book data: " .. tostring(index_or_err))
            end
            indexes[book_id] = index_or_err
        end
        value = indexes
    end
    self.store:saveSetting(key, value)
end

function Settings:delete(key)
    if type(self.store.delSetting) == "function" then
        self.store:delSetting(key)
    else
        self.store:saveSetting(key, nil)
    end
end

function Settings:has_legacy_book_records()
    local books = self.store:readSetting("books", {})
    return not BookStore.is_minimal_index(books)
end

function Settings:flush()
    self.store:flush()
end

function Settings:update_auth(credentials, options)
    credentials = credentials or {}
    options = options or {}
    local changed = false

    if type(credentials.cookies) == "table" then
        local cookies = credentials.cookies
        if options.replace_cookies ~= true then
            cookies = Cookie.merge(self:get("cookies", {}), cookies)
        else
            cookies = deepcopy(cookies)
        end
        self:set("cookies", cookies)
        changed = true
    end

    for _, key in ipairs({ "api_key", "wr_ticket", "wr_wrpa" }) do
        local value = credentials[key]
        if type(value) == "string" then
            self:set(key, value)
            changed = true
        end
    end
    if type(credentials.account) == "table" then
        self:set("account", deepcopy(credentials.account))
        changed = true
    end

    if changed and options.flush ~= false then
        self:flush()
    end
    return changed
end

function Settings:merge_set_cookie(set_cookie, options)
    if not set_cookie or set_cookie == "" then
        return false
    end
    local cookies = Cookie.merge_set_cookie(self:get("cookies", {}), set_cookie)
    return self:update_auth({ cookies = cookies }, {
        replace_cookies = true,
        flush = not options or options.flush ~= false,
    })
end

function Settings:get_all()
    local all = {}
    for key in pairs(defaults) do
        all[key] = self:get(key)
    end
    return all
end

function Settings:get_download_dir()
    return self.cache_dir
end

-- Pass nil or "" to reset to the default download directory.
function Settings:set_download_dir(path)
    if type(path) ~= "string" or path == "" then
        self:set("download_dir", "")
        self.cache_dir = self.default_cache_dir
    else
        self:set("download_dir", path)
        self.cache_dir = path
    end
    -- Keep metadata out of the book library if user points both to the same place.
    if self.meta_dir == self.cache_dir then
        self.meta_dir = self.default_meta_dir
        self:set("meta_dir", "")
        ensure_dir(self.meta_dir)
    end
    self:flush()
    ensure_dir(self.cache_dir)
    return self.cache_dir
end

function Settings:get_meta_dir()
    return self.meta_dir
end

-- Pass nil or "" to reset to the default metadata directory.
function Settings:set_meta_dir(path)
    if type(path) ~= "string" or path == "" then
        self:set("meta_dir", "")
        self.meta_dir = self.default_meta_dir
    else
        if path == self.cache_dir then
            error("metadata directory must not be the same as the book directory")
        end
        self:set("meta_dir", path)
        self.meta_dir = path
    end
    self:flush()
    ensure_dir(self.meta_dir)
    return self.meta_dir
end

function Settings:reset_account()
    clear_auth_store(self.store)
    self:flush()
end

function Settings:is_cookie_configured()
    return Cookie.has_login_cookie(self:get("cookies", {})) == true
end

function Settings:is_api_configured()
    return self:get("api_key", "") ~= ""
end

return Settings
