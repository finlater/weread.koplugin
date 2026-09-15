package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end,
        getHeight = function() return 800 end } }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return { warn = function() end, err = function() end }
        end,
    }
end
package.preload["ui/widget/qrmessage"] = function() return {} end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        urlencode = function(value)
            return tostring(value):gsub(" ", "%%20")
        end,
    }
end

local requests = {}
local client = {
    request = function(_self, options)
        requests[#requests + 1] = options
        return "{}", 200, {}
    end,
    decode_http_json = function()
        return { logicCode = "PENDING" }
    end,
}

local QRLogin = require("weread.lib.qr_login")
local login = QRLogin:new({}, client, {})

login:_poll_protocol("uid value", "")
expect(requests[1].url ==
    "https://weread.qq.com/api/auth/getLoginInfo?uid=uid%20value&otp=",
    "empty OTP was not serialized with an explicit value")

login:_poll_protocol("uid value", "1234")
expect(requests[2].url ==
    "https://weread.qq.com/api/auth/getLoginInfo?uid=uid%20value&otp=1234",
    "non-empty OTP was serialized incorrectly")

print("qr_login_spec: " .. checks .. " checks passed")
