local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings

local defaults = {
    api_key = "",
    cookies = {},
    wr_ticket = "",
    wr_wrpa = "",
    config_auth_fingerprint = "",
    config_preferences_fingerprint = "",
    curl_payload = {},
    books = {},
    downloads = {},
    sync = {
        pull_on_open = true,
        upload_on_close = true,
        ask_on_conflict = true,
        upload_interval_minutes = 0,
    },
    cache = {
        download_book_images = true,
        download_mp_images = false,
        download_underlines_and_thoughts = false,
        show_annotations = true,
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
    shelf = {
        sort_order = "time_desc",
    },
    download_dir = "",
    config_loaded = false,
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

function Settings:new()
    local data_dir = DataStorage:getFullDataDir() .. "/weread"
    ensure_dir(data_dir)
    local obj = {
        data_dir = data_dir,
        default_cache_dir = data_dir .. "/cache",
        settings_file = DataStorage:getSettingsDir() .. "/weread.lua",
    }
    obj.store = LuaSettings:open(obj.settings_file)
    -- cache_dir is the download root; defaults to <data_dir>/cache unless overridden.
    local download_dir = obj.store:readSetting("download_dir", "")
    obj.cache_dir = (type(download_dir) == "string" and download_dir ~= "") and download_dir or obj.default_cache_dir
    ensure_dir(obj.cache_dir)
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
    if cache.download_underlines_and_thoughts == nil then
        cache.download_underlines_and_thoughts = false
        cache_changed = true
    end
    if cache.show_annotations == nil then
        cache.show_annotations = true
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
    return setmetatable(obj, self)
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    return self.store:readSetting(key, deepcopy(default))
end

function Settings:set(key, value)
    self.store:saveSetting(key, value)
end

function Settings:flush()
    self.store:flush()
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
    self:flush()
    ensure_dir(self.cache_dir)
    return self.cache_dir
end

function Settings:reset_account()
    self:set("api_key", "")
    self:set("cookies", {})
    self:set("wr_ticket", "")
    self:set("wr_wrpa", "")
    self:set("curl_payload", {})
    self:flush()
end

function Settings:is_cookie_configured()
    local cookies = self:get("cookies", {})
    return cookies.wr_skey ~= nil and #cookies.wr_skey >= 8
end

function Settings:is_api_configured()
    return self:get("api_key", "") ~= ""
end

function Settings:apply_config(config, options)
    options = options or {}
    if type(config) ~= "table" then
        return false, "config must return a table"
    end
    if type(config.api_key) == "string" then
        self:set("api_key", config.api_key)
    end
    if options.apply_preferences ~= false and type(config.sync) == "table" then
        local sync = self:get("sync")
        for key, value in pairs(config.sync) do
            sync[key] = value
        end
        self:set("sync", sync)
    end
    if options.apply_preferences ~= false and type(config.cache) == "table" then
        local cache = self:get("cache")
        for key, value in pairs(config.cache) do
            if key ~= "download_images" then
                cache[key] = value
            end
        end
        if config.cache.download_book_images == nil and config.cache.download_images ~= nil then
            cache.download_book_images = config.cache.download_images
        end
        cache.download_images = nil
        self:set("cache", cache)
    end
    if options.apply_preferences ~= false and type(config.read_report) == "table" then
        local rr = self:get("read_report")
        if config.read_report.interval_seconds then
            rr.interval_seconds = config.read_report.interval_seconds
        end
        if config.read_report.report_on_open ~= nil then
            rr.report_on_open = config.read_report.report_on_open
        end
        if type(config.read_report.book_id) == "string" and config.read_report.book_id ~= "" then
            rr.book_id = config.read_report.book_id
            rr.book_title = config.read_report.book_title or rr.book_title
            if config.read_report.enabled ~= nil then
                rr.enabled = config.read_report.enabled
            end
        end
        self:set("read_report", rr)
    end
    if options.apply_preferences ~= false and type(config.shelf) == "table" then
        local shelf = self:get("shelf")
        for key, value in pairs(config.shelf) do
            shelf[key] = value
        end
        self:set("shelf", shelf)
    end
    self:set("config_loaded", true)
    self:flush()
    return true
end

return Settings