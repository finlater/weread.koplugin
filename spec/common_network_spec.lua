-- Unit tests for shared network task behavior.

package.path = "./?.lua;" .. package.path

local checks = 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        error(string.format("%s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

package.preload["ui/bidi"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/menu"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return false end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        unpack_args = function(args) return unpack(args) end,
    }
end

local Common = require("weread.ui.common")
local offline_notices = 0
local host = setmetatable({
    showOffline = function()
        offline_notices = offline_notices + 1
    end,
}, { __index = Common })

eq(host:runOnlineTask("automatic", function() end, nil, {
    silent_offline = true,
}), false, "silent offline task does not start")
eq(offline_notices, 0, "silent offline task does not show a notice")

eq(host:runOnlineTask("manual", function() end), false,
    "regular offline task does not start")
eq(offline_notices, 1, "regular offline task still shows a notice")

local transient_notices, qr_starts = 0, 0
local login_host = setmetatable({
    settings = {
        is_cookie_configured = function() return false end,
        is_api_configured = function() return false end,
    },
    qr_login = { start = function() qr_starts = qr_starts + 1 end },
    showTransientInfo = function() transient_notices = transient_notices + 1 end,
}, { __index = Common })
eq(login_host:requireLogin(true, false), false, "missing login is reported")
eq(qr_starts, 1, "automatic login starts QR login")
eq(transient_notices, 0, "automatic login shows no prompt that repaints over the QR")

print(string.format("common_network_spec: %d checks", checks))
