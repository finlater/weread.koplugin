-- Lightweight pure-logic checks for weread.lib.updater helpers.
-- Run with: luajit spec/updater_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Minimal stubs so updater.lua can be loaded outside KOReader.
package.preload["datastorage"] = function()
    return {
        getDataDir = function()
            return "/tmp/weread-updater-spec"
        end,
        getSettingsDir = function()
            return "/tmp/weread-updater-spec/settings"
        end,
        getFullDataDir = function()
            return "/tmp/weread-updater-spec"
        end,
    }
end

package.preload["socket.http"] = function()
    return {
        request = function()
            return 1, 500, {}, "stub"
        end,
    }
end

package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(t)
                return function(chunk)
                    if chunk then
                        t[#t + 1] = chunk
                    end
                    return 1
                end
            end,
        },
    }
end

package.preload["socketutil"] = function()
    return {
        FILE_BLOCK_TIMEOUT = 30,
        FILE_TOTAL_TIMEOUT = 300,
        set_timeout = function() end,
        reset_timeout = function() end,
        file_sink = function(file)
            return function(chunk)
                if chunk then
                    file:write(chunk)
                end
                return 1
            end
        end,
        table_sink = function(t)
            return function(chunk)
                if chunk then
                    t[#t + 1] = chunk
                end
                return 1
            end
        end,
        USER_AGENT = "test",
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function()
            return nil
        end,
        mkdir = function()
            return true
        end,
        dir = function()
            return function()
                return nil
            end
        end,
        rmdir = function()
            return true
        end,
    }
end

package.preload["util"] = function()
    return {
        makePath = function() end,
        removeFile = function() end,
    }
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end

package.preload["weread.lib.plugin_util"] = function()
    return {
        LOG_MODULE = "[WeRead]",
        tr = function(text)
            return text
        end,
        T = function(template, ...)
            return template
        end,
    }
end

package.preload["ffi/archiver"] = function()
    error("archiver unavailable in unit test")
end

local Updater = require("weread.lib.updater")

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

assert_eq(Updater.compare_versions("0.5.0", "0.5.1"), -1, "0.5.0 < 0.5.1")
assert_eq(Updater.compare_versions("0.5.1", "0.5.0"), 1, "0.5.1 > 0.5.0")
assert_eq(Updater.compare_versions("v0.5.1", "0.5.1"), 0, "v prefix ignored")
assert_eq(Updater.is_newer("0.5.1", "0.5.0"), true, "is_newer true")
assert_eq(Updater.is_newer("0.5.0", "0.5.1"), false, "is_newer false")
assert_eq(Updater.is_newer("0.5.0", "0.5.0"), false, "is_newer equal")

local meta = [[
return {
    name = "weread",
    version = "0.5.1",
}
]]
assert_eq(Updater.extract_version_from_meta(meta), "0.5.1", "extract version")

assert_eq(
    Updater.wrap_proxy("https://gh-proxy.com", "https://github.com/a/b.zip"),
    "https://gh-proxy.com/https://github.com/a/b.zip",
    "proxy wrap"
)
assert_eq(
    Updater.wrap_proxy("", "https://github.com/a/b.zip"),
    "https://github.com/a/b.zip",
    "direct wrap"
)
assert_eq(
    Updater.wrap_proxy("https://gh-proxy.com/", "https://github.com/a/b.zip"),
    "https://gh-proxy.com/https://github.com/a/b.zip",
    "proxy trailing slash"
)

local fake_settings = {
    data = {
        update = {
            proxy_id = "ghfast.top",
            channel = "auto",
        },
    },
}
function fake_settings:get(key, default)
    if self.data[key] ~= nil then
        return self.data[key]
    end
    return default
end
function fake_settings:set(key, value)
    self.data[key] = value
end
function fake_settings:flush() end

local updater = Updater:new{ settings = fake_settings }
assert_eq(updater:resolve_proxy_base(), "https://ghfast.top", "resolve proxy")
local candidates = updater:proxy_candidates()
assert_eq(candidates[1], "https://ghfast.top", "preferred proxy first")
assert_eq(candidates[#candidates], "", "direct last")

print("updater_spec: ok")
