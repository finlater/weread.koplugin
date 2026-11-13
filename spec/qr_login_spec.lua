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
package.preload["weread.ui.qr_dialog"] = function() return {} end
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

local function run_login(fingerprint)
    local protocol_requests, saved = {}, nil
    local responses = {
        { "html", { ["set-cookie"] = "wr_preflight=test-preflight; Path=/" } },
        { { uid = "test-uid" } },
        { { succeed = true, webLoginVid = "test-user", accessToken = "test-access", refreshToken = "test-refresh" } },
        { { name = "Test user" } },
        { { apikey = "test-api-key" } },
    }
    local protocol_client = {
        request = function(_self, opts)
            protocol_requests[#protocol_requests + 1] = opts
            local response = table.remove(responses, 1)
            return response[1], 200, response[2] or {}
        end,
        decode_http_json = function(_self, body) return body end,
    }
    protocol_client.request_follow = protocol_client.request
    local settings = {
        get_device_fingerprint = function() return fingerprint end,
        update_auth = function(_self, credentials, options)
            expect(options.replace_cookies, "login should replace account cookies")
            saved = credentials
        end,
    }
    local protocol_login = QRLogin:new({}, protocol_client, settings)
    local uid = protocol_login:_begin_protocol()
    local result = protocol_login:_poll_protocol(uid)
    protocol_login:_complete_protocol(result, protocol_login.generation)
    local expected_urls = {
        "https://weread.qq.com/r/weread-skills",
        "https://weread.qq.com/api/auth/getLoginUid",
        "https://weread.qq.com/api/auth/getLoginInfo?uid=test-uid&otp=",
        "https://weread.qq.com/api/userInfo?userVid=test-user",
        "https://weread.qq.com/api/skills/apikeyGet?only_show=1",
    }
    expect(#protocol_requests == #expected_urls, "fingerprint must not introduce a new login chain")
    for i, request in ipairs(protocol_requests) do
        expect(request.url == expected_urls[i], "classic login endpoint changed")
        expect(request.skip_cookie, "login must not inherit old account credentials")
        expect(request.headers.Cookie:find("wr_fp=" .. fingerprint, 1, true),
            "fingerprint missing from login request " .. i)
        expect(not request.headers.Cookie:find("wr_gid=", 1, true),
            "fingerprint-only experiment must not add a guest ID")
    end
    expect(protocol_requests[2].headers.Cookie:find("wr_preflight=test-preflight", 1, true),
        "fingerprint must not discard server cookies")
    expect(saved.cookies.wr_fp == fingerprint and saved.cookies.wr_skey == "test-access",
        "completed login must persist both the fingerprint and new credentials")
    expect(saved.api_key == "test-api-key" and protocol_login.login_cookies == nil,
        "login completion state changed")
    return protocol_requests[2].headers.Cookie
end

expect(run_login("1234567890") ~= run_login("2345678901"),
    "separate device fingerprints must reach the server independently")

local shown, qr_opts, show_args
package.loaded["weread.lib.qr_login"] = nil
package.loaded["weread.ui.qr_dialog"] = nil
package.loaded["ui/uimanager"] = nil
package.preload["weread.ui.qr_dialog"] = function()
    return { new = function(_self, opts) qr_opts = opts; return opts end }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, callback)
            if delay == 0.2 then callback() end
        end,
        show = function(_self, widget, mode) shown, show_args = widget, mode end,
        close = function() end,
    }
end
local ShowLogin = require("weread.lib.qr_login")
local show_login = ShowLogin:new({}, client, {})
show_login:_show_qr("uid", show_login.generation)
expect(qr_opts.width == nil and qr_opts.height == nil and qr_opts.scale_factor == nil,
    "QRDialog owns the QR sizing; the caller must not override it")
expect(shown == qr_opts and show_args == "full",
    "QR dialog must be shown with a full e-ink refresh")

local infos = {}
local poll_login = ShowLogin:new({
    showInfo = function(_self, text) infos[#infos + 1] = text end,
    showTransientInfo = function() end,
}, client, {})
poll_login.qr_dialog = {}
poll_login.started_at = os.time()
poll_login._poll_protocol = function() error("getLoginInfo failed: HTTP 401") end
for _ = 1, 3 do poll_login:_poll("uid", poll_login.generation) end
expect(#infos == 0 and poll_login.poll_unauthorized == 3,
    "transient getLoginInfo 401 must be retried, not reported")
poll_login:_poll("uid", poll_login.generation)
expect(#infos == 1, "persistent getLoginInfo 401 must still be reported")

print("qr_login_spec: " .. checks .. " checks passed")
