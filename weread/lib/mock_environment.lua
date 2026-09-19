-- Global mode selector, separate from both production and mock preferences.
-- The active snapshot is deliberately immutable until KOReader restarts.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local M = {}
local active

function M.read()
    local store = LuaSettings:open(DataStorage:getSettingsDir() .. "/weread-environment.lua")
    return {
        enabled = store:readSetting("enabled", false) == true,
        host = store:readSetting("host", "192.168.31.111"),
        port = store:readSetting("port", 8765),
    }
end

function M.endpoint(config)
    local host = tostring(config.host or "")
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    local port = tonumber(config.port)
    if not a or a > 255 or b > 255 or c > 255 or d > 255
        or not (a == 10 or a == 127 or (a == 192 and b == 168)
            or (a == 172 and b >= 16 and b <= 31)) then
        return nil, "Enter a private LAN IPv4 address (or 127.0.0.1)."
    end
    if not port or port < 1 or port > 65535 or port ~= math.floor(port) then
        return nil, "Enter a port between 1 and 65535."
    end
    return string.format("http://%d.%d.%d.%d:%d", a, b, c, d, port)
end

function M.save(config)
    local endpoint, err = M.endpoint(config)
    if not endpoint then return nil, err end
    local store = LuaSettings:open(DataStorage:getSettingsDir() .. "/weread-environment.lua")
    store:saveSetting("enabled", config.enabled == true)
    store:saveSetting("host", endpoint:match("^http://([^:]+)"))
    store:saveSetting("port", tonumber(config.port))
    store:flush()
    return true
end

function M.active()
    if not active then active = M.read() end
    return { enabled = active.enabled, host = active.host, port = active.port }
end

return M
