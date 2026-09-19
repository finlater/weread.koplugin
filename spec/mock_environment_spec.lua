package.path = "./?.lua;./?/init.lua;" .. package.path

-- Separate stores model independent configuration files, including reopening
-- Settings while the same KOReader process still has active workers.
local stores = {
    ["/settings/weread.lua"] = {
        auth_schema_version = 1, api_key = "production-sentinel",
        cookies = { wr_skey = "production-sentinel" },
        books = { real_book = { cache_dir = "/real/downloads/book" } },
        download_dir = "/real/downloads",
        shelf = { view_mode = "cover" },
    },
}
package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return "/data" end,
        getSettingsDir = function() return "/settings" end,
    }
end
package.preload["luasettings"] = function()
    return { open = function(_self, path)
        stores[path] = stores[path] or {}
        local values = stores[path]
        return {
            readSetting = function(_store, key, default)
                if values[key] == nil then return default end
                return values[key]
            end,
            saveSetting = function(_store, key, value) values[key] = value end,
            delSetting = function(_store, key) values[key] = nil end,
            flush = function() end,
        }
    end }
end
local directories = {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path) return directories[path] and "directory" end,
        mkdir = function(path) directories[path] = true; return true end,
    }
end
package.preload["weread.lib.book_store"] = function()
    return { load = function(_settings, _id, index) return index end }
end

local Environment = require("weread.lib.mock_environment")
local Settings = require("weread.lib.settings")
local config = Environment.read()
assert(config.host == "192.168.31.111" and config.port == 8765 and not config.enabled)
for _, host in ipairs({ "8.8.8.8", "example.com", "192.168.1.1/path", "192.168.999.1", "172.32.0.1", "0.0.0.0" }) do
    assert(not Environment.endpoint({ host = host, port = 8765 }), host)
end
for _, port in ipairs({ 0, 65536, 1.5, "no" }) do
    assert(not Environment.endpoint({ host = "192.168.31.111", port = port }))
end
for _, host in ipairs({ "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.31.111", "127.0.0.1" }) do
    assert(Environment.endpoint({ host = host, port = 8765 }))
end
local production = Settings:new()
assert(not production.mock_endpoint and production.cache_dir == "/real/downloads")
config.enabled = true
assert(Environment.save(config))
assert(Environment.read().enabled and not Environment.active().enabled, "save must not hot-switch")
assert(not Settings:new().mock_endpoint, "new plugin instance in the same process must not hot-switch")

-- Simulate a fresh process's module cache, retaining persisted files.
package.loaded["weread.lib.mock_environment"] = nil
Environment = require("weread.lib.mock_environment")
local mock = Settings:new()
assert(mock.mock_endpoint == "http://192.168.31.111:8765")
assert(mock.data_dir == "/data/weread-mock" and mock.cache_dir == "/data/weread-mock/cache")
assert(mock.settings_file == "/settings/weread-mock.lua" and mock.collection_name == "weread-mock")
assert(mock:get("api_key") == "mock-api-key" and mock:get("account").login_method == "mock")
assert(next(mock:get("books")) == nil and mock:get("shelf").view_mode == "list")
assert(mock:set_download_dir("/real/downloads") == "/data/weread-mock/cache")
mock:set("shelf", { view_mode = "mock-only" })
config.host, config.port, config.enabled = "192.168.31.112", 8766, false
assert(Environment.save(config))
assert(Settings:new().mock_endpoint == "http://192.168.31.111:8765", "active endpoint changed")
assert(production:get("api_key") == "production-sentinel")
assert(production:get("books").real_book.cache_dir == "/real/downloads/book")
package.loaded["weread.lib.mock_environment"] = nil
local restored = Settings:new()
assert(not restored.mock_endpoint and restored:get("shelf").view_mode == "cover")
assert(restored:get("cookies").wr_skey == "production-sentinel")
assert(restored.data_dir == "/data/weread" and restored.collection_name == "weread")
print("mock_environment_spec: validation, restart-only switching, data/auth/cache/collection isolation passed")
