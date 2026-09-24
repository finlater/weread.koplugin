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
            return {
                dbg = function() end, info = function() end,
                warn = function() end, err = function() end,
            }
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
            return tostring(value):gsub("([^%w%-_%.~])", function(ch)
                return string.format("%%%02X", ch:byte())
            end)
        end,
    }
end

local Crypto = require("weread.lib.crypto")
local QRLogin = require("weread.lib.qr_login")

local function fake_settings(seed)
    return {
        values = { device_seed = seed or "qr-device-seed" },
        get = function(self, key, default)
            local value = self.values[key]
            if value == nil then return default end
            return value
        end,
        set = function(self, key, value) self.values[key] = value end,
        flush = function() end,
        update_auth = function(self, credentials)
            for key, value in pairs(credentials) do
                self.values[key] = value
            end
        end,
    }
end

local function make_client()
    local state = {
        posts = {},
        get_requests = {},
        follow_requests = {},
        post_queue = {},
        http_queue = {},
        follow_queue = {},
    }
    local client = {
        post_json = function(_self, url, payload, opts)
            state.posts[#state.posts + 1] = { url = url, payload = payload, opts = opts }
            local next_post = table.remove(state.post_queue, 1)
            if next_post == nil then error("unexpected post_json: " .. tostring(url)) end
            if next_post.raise then error(next_post.raise) end
            return next_post.data or {}, next_post.code or 200, next_post.headers or {}
        end,
        request = function(_self, opts)
            state.get_requests[#state.get_requests + 1] = opts
            local next_http = table.remove(state.http_queue, 1)
            if next_http == nil then error("unexpected request: " .. tostring(opts.url)) end
            if next_http.raise then error(next_http.raise) end
            state.last_decoded = next_http.decoded
            return next_http.body or "", next_http.code or 200,
                next_http.headers or {}, next_http.status
        end,
        request_follow = function(_self, opts)
            state.follow_requests[#state.follow_requests + 1] = opts
            local next_follow = table.remove(state.follow_queue, 1)
            if next_follow == nil then error("unexpected request_follow: " .. tostring(opts.url)) end
            if next_follow.raise then error(next_follow.raise) end
            return next_follow.body or "", next_follow.code or 200,
                next_follow.headers or {}, next_follow.status, opts.url
        end,
        decode_http_json = function(_self)
            return state.last_decoded
        end,
    }
    return client, state
end

local function new_login(client, settings)
    return QRLogin:new({}, client, settings or fake_settings())
end

-- Success predicate: getinfo carries credentials only with vid + skey + code.
local predicate_login = new_login((make_client()))
local vid, skey, code = predicate_login:_ink_login_payload(
    { vid = 12345678, skey = "S", code = 1001 })
expect(vid == "12345678", "an integer vid must be coerced to its decimal string")
expect(skey == "S" and code == 1001, "skey and code must be extracted")
expect(predicate_login:_ink_login_payload({ vid = 1, skey = "S" }) == nil,
    "a payload without code must not count as success")
expect(predicate_login:_ink_login_payload({ vid = 1, code = 2 }) == nil,
    "a payload without skey must not count as success")
expect(predicate_login:_ink_login_payload({ skey = "S", code = 2 }) == nil,
    "a payload without vid must not count as success")
expect(predicate_login:_ink_login_payload({ vid = "123", skey = "S", code = "c" }) == "123",
    "a string vid must still be accepted")
expect(predicate_login:_ink_login_payload({ vid = true, skey = "S", code = 1 }) == nil,
    "a boolean vid must not be accepted")

-- Confirm URL: pf=2 only for the ink chain; the classic chain stays unchanged.
local url_login = new_login((make_client()))
url_login.login_mode = "ink"
expect(url_login:_confirm_url("uid value") ==
    "https://weread.qq.com/web/confirm?pf=2&uid=uid%20value",
    "the ink confirm URL must carry pf=2")
url_login.login_mode = "classic"
expect(url_login:_confirm_url("uid value") ==
    "https://weread.qq.com/web/confirm?uid=uid%20value",
    "the classic confirm URL must stay unchanged")

-- Chain order and payloads: legacy weblogin then session/init.
local chain_client, chain_state = make_client()
local chain_settings = fake_settings("ink-seed")
local chain_login = new_login(chain_client, chain_settings)
local expected_fp = Crypto.sha256_hex("ink-seed")
chain_state.post_queue[1] = {
    data = { accessToken = "ACCESS", refreshToken = "REFRESH", vid = 12345678 },
    headers = {
        ["Set-Cookie"] = "wr_pf=2; Path=/; wr_vid=XXX-12345678; Path=/; "
            .. "wr_skey=ACCESS; Path=/; wr_rt=REFRESH; Path=/",
    },
}
chain_state.post_queue[2] = {
    data = {},
    headers = { ["Set-Cookie"] = "wr_ql=0; Path=/" },
}
local chain_result = chain_login:_resolve_ink_result(
    { vid = 12345678, skey = "GETINFO_SKEY", code = 1001, pf = 2 })
expect(chain_result ~= nil and chain_result.succeed == true,
    "the weblogin chain must produce a completable login result")
expect(chain_result.webLoginVid == "XXX-12345678" and chain_result.accessToken == "ACCESS"
    and chain_result.refreshToken == "REFRESH",
    "the login result must carry vid/accessToken/refreshToken")
expect(#chain_state.posts == 2, "the chain must issue exactly weblogin then session/init")
expect(chain_state.posts[1].url ==
    "https://weread.qq.com/wrwebsimplenjlogic/api/weblogin?platform=desktop",
    "the legacy weblogin endpoint must be used (not the ink-style variant)")
expect(chain_state.posts[2].url == "https://weread.qq.com/web/login/session/init",
    "session/init must follow weblogin")
local weblogin_body = chain_state.posts[1].payload
expect(weblogin_body.vid == "12345678" and weblogin_body.skey == "GETINFO_SKEY"
    and weblogin_body.code == 1001, "weblogin must forward the getinfo credentials")
expect(weblogin_body.isAutoLogout == 0 and weblogin_body.pf == 2,
    "weblogin must send isAutoLogout=0 and the payload pf")
expect(weblogin_body.fp == expected_fp,
    "weblogin must carry the per-device fingerprint")
expect(type(weblogin_body.cgiKey) == "number"
    and weblogin_body.cgiKey >= 100 and weblogin_body.cgiKey <= 999,
    "weblogin must send a random cgiKey in 100..999")
expect(weblogin_body.deviceId == nil,
    "the verified legacy variant carries no deviceId field")
local init_body = chain_state.posts[2].payload
expect(init_body.vid == "12345678" and init_body.skey == "ACCESS" and init_body.rt == "REFRESH"
    and init_body.ql == 0 and init_body.pf == 2,
    "session/init must reuse the issued tokens")
expect(chain_login.login_cookies.wr_fp == expected_fp,
    "wr_fp must be installed on the login jar")
expect(chain_login.login_cookies.wr_skey == "ACCESS"
    and chain_login.login_cookies.wr_vid == "XXX-12345678",
    "weblogin Set-Cookie credentials must be merged into the login jar")

-- Weblogin failure: the resolver must fail fast with no cross-namespace classic attempt.
local fallback_client, fallback_state = make_client()
local fallback_login = new_login(fallback_client)
fallback_state.post_queue[1] = { data = {}, headers = {} }
local fallback_result = fallback_login:_resolve_ink_result(
    { vid = 1, skey = "S", code = 2 })
expect(fallback_result == nil,
    "a failed weblogin chain must not complete via a classic fallback")
expect(#fallback_state.get_requests == 0,
    "a failed weblogin chain must issue NO classic getLoginInfo request")

-- Begin: the ink getuid is preferred and issues a JSON POST.
local ink_client, ink_state = make_client()
local ink_login = new_login(ink_client)
ink_state.follow_queue[1] = { code = 200, headers = { ["Set-Cookie"] = "skill=1; Path=/" } }
ink_state.post_queue[1] = { data = { uid = "ink-uid" } }
local ink_uid = ink_login:_begin_protocol()
expect(ink_uid == "ink-uid" and ink_login.login_mode == "ink",
    "the ink getuid must select the weblogin chain")
expect(ink_state.posts[1].url == "https://weread.qq.com/web/login/getuid",
    "begin must POST the ink getuid endpoint")
expect(ink_state.follow_requests[1].url == "https://weread.qq.com/r/weread-skills",
    "begin must still open the skills page first")
expect(ink_login.login_cookies.skill == nil,
    "non-wr cookies must not enter the login jar")

-- Begin fallback: a missing ink uid must fall back to the classic getuid.
local classic_client, classic_state = make_client()
local classic_login = new_login(classic_client)
classic_state.follow_queue[1] = { code = 200 }
classic_state.post_queue[1] = { data = {} }
classic_state.http_queue[1] = { decoded = { uid = "classic-uid" } }
local classic_uid = classic_login:_begin_protocol()
expect(classic_uid == "classic-uid" and classic_login.login_mode == "classic",
    "a missing ink uid must fall back to the classic chain")
expect(classic_state.get_requests[1].url ==
    "https://weread.qq.com/api/auth/getLoginUid",
    "the fallback must use the classic getLoginUid endpoint")

-- Poll: the getinfo POST forwards uid/otp and its int vid is detected.
local poll_client, poll_state = make_client()
local poll_login = new_login(poll_client)
poll_state.post_queue[1] = {
    data = { vid = 987654321, skey = "SKEY", code = 555, pf = 2 },
}
local poll_result = poll_login:_poll_ink("uid-1", "1234")
expect(poll_state.posts[1].url == "https://weread.qq.com/web/login/getinfo",
    "the ink poll must POST getinfo")
expect(poll_state.posts[1].payload.uid == "uid-1"
    and poll_state.posts[1].payload.otp == "1234",
    "the ink poll must forward uid and otp in the JSON body")
expect(poll_login:_ink_login_payload(poll_result) == "987654321",
    "the integer vid from a real getinfo response must be detected")

poll_state.post_queue[1] = { raise = "timeout" }
local pending = poll_login:_poll_ink("uid-1", "")
expect(pending.transport_pending == true,
    "a timed-out long poll must be reported as pending")

-- A non-table 2xx body must be rejected before _poll can index it.
poll_state.post_queue[1] = { data = 123 }
local scalar_ok, scalar_err = pcall(function() return poll_login:_poll_ink("uid-1", "") end)
expect(not scalar_ok and tostring(scalar_err):find("invalid JSON response", 1, true) ~= nil,
    "a non-table getinfo response must be rejected as invalid JSON")

-- Completion bumps session_generation so an in-flight renewal cannot overwrite it.
local gen_client, gen_state = make_client()
local gen_settings = fake_settings("gen-seed")
gen_settings.values.session_generation = 4
local gen_login = new_login(gen_client, gen_settings)
gen_state.http_queue[1] = { decoded = { name = "Alice" } }
gen_state.http_queue[2] = { decoded = { apikey = "KEY" } }
local gen_account = gen_login:_complete_protocol({
    succeed = true, webLoginVid = "vid-9", accessToken = "tok-9", refreshToken = "rt-9",
}, gen_login.generation)
expect(gen_account ~= nil and gen_account.user_vid == "vid-9",
    "a fresh completion returns the account")
expect(gen_settings.values.session_generation == 5,
    "QR login must bump session_generation so stale renewals are rejected")

-- A stale completion must not persist anything.
local stale_client, stale_state = make_client()
local stale_settings = fake_settings("stale-seed")
local stale_login = new_login(stale_client, stale_settings)
stale_state.http_queue[1] = { decoded = { name = "Alice" } }
stale_state.http_queue[2] = { decoded = { apikey = "KEY" } }
local stale_generation = stale_login.generation
stale_login:cancel()
local stale_ok, stale_err = pcall(function()
    return stale_login:_complete_protocol({
        succeed = true, webLoginVid = "vid-9", accessToken = "tok-9",
    }, stale_generation)
end)
expect(not stale_ok and tostring(stale_err):find("cancelled", 1, true) ~= nil,
    "a stale completion must be rejected")
expect(stale_settings.values.api_key == nil,
    "a stale completion must not persist the API key")

print(("qr_login_weblogin_spec: %d checks"):format(checks))
