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

local SessionState = require("weread.lib.session_state")
local NetworkMgr = require("ui/network/manager")
NetworkMgr.isOnline = function() return true end
NetworkMgr.isConnected = function() return true end

local transient_messages = {}
local qr_starts = 0
local renewals = 0
local recovery_host = setmetatable({
    settings = {
        is_cookie_configured = function() return true end,
        is_api_configured = function() return true end,
    },
    client = {
        renew_cookie = function()
            renewals = renewals + 1
            SessionState.clear()
            return { succ = 1 }
        end,
    },
    qr_login = {
        start = function() qr_starts = qr_starts + 1 end,
    },
    showTransientInfo = function(_self, text, _timeout)
        transient_messages[#transient_messages + 1] = text
    end,
}, { __index = Common })

Common.last_session_recovery_at = 0
SessionState.mark_invalid("login_timeout")
eq(recovery_host:requireLogin(true, true), false,
    "invalid session still blocks the gated action")
eq(renewals, 1, "invalid session triggers one silent renewal")
eq(qr_starts, 0, "successful recovery never opens the QR login")
eq(SessionState.is_invalid(), false, "successful recovery clears the invalid state")
eq(#transient_messages, 1, "recovery informs the user to retry")
eq(transient_messages[1], "WeRead session restored. Please try again.",
    "recovery reports the restored session")

Common.last_session_recovery_at = 0
SessionState.mark_invalid("login_timeout")
recovery_host.client.renew_cookie = function()
    renewals = renewals + 1
    error("Cookie renewal response did not include succ=1")
end
eq(recovery_host:requireLogin(true, true), false,
    "failed recovery still blocks the gated action")
eq(renewals, 2, "failed recovery attempted the renewal")
eq(SessionState.is_invalid(), true, "failed recovery keeps the session invalid")
eq(qr_starts, 1, "failed recovery falls back to the scan prompt")
eq(transient_messages[2], "WeRead session has expired. Please scan the QR code again.",
    "fallback prompt asks for a new scan")

print(string.format("common_network_spec: %d checks", checks))
