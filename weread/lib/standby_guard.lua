-- Shared standby guard for long-running plugin jobs.
--
-- KOReader's UIManager API is the public coordination point and is always
-- used. Some platforms do not implement Device:setAutoStandby, however, so
-- retain the platform fallback that actually blocks their native suspend
-- mechanism. The module-level counter makes the fallback safe when book and
-- annotation downloads overlap.

local UIManager = require("ui/uimanager")

local Guard = {}
local active_count = 0

local function platform_services()
    return require("device"), require("pluginshare")
end

local function prevent_platform_standby()
    local Device, PluginShare = platform_services()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = true
    end
end

local function allow_platform_standby()
    local Device, PluginShare = platform_services()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = false
    end
end

function Guard.acquire()
    local token = { active = true }
    active_count = active_count + 1
    UIManager:preventStandby()
    if active_count == 1 then prevent_platform_standby() end
    return token
end

function Guard.release(token)
    if not token or not token.active then return false end
    token.active = false
    if active_count <= 0 then return false end
    active_count = active_count - 1
    UIManager:allowStandby()
    if active_count == 0 then allow_platform_standby() end
    return true
end

function Guard.recover()
    -- Kindle keeps the flag in powerd if KOReader is killed. Other platforms
    -- use an in-process shared flag that may belong to another component.
    local Device = require("device")
    if active_count == 0 and Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
end

return Guard
