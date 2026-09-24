package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local timeout_calls = {}
local reset_count = 0
local requests = {}
local responses = {}
local logs = {}

package.preload["ltn12"] = function()
    return {
        source = {
            string = function(value)
                return function() return value end
            end,
        },
    }
end
package.preload["logger"] = function()
    local function capture(level, ...)
        local parts = { level }
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        logs[#logs + 1] = table.concat(parts, " ")
    end
    return {
        info = function(...) capture("info", ...) end,
        err = function(...) capture("error", ...) end,
    }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_self, block, total)
            timeout_calls[#timeout_calls + 1] = { block, total }
        end,
        reset_timeout = function()
            reset_count = reset_count + 1
        end,
        table_sink = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(options)
            requests[#requests + 1] = options
            local response = table.remove(responses, 1)
            if response.raise then error(response.raise) end
            if options.sink then options.sink(response.body or "") end
            return 1, response.code, response.headers or {}, response.status
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return {
        USER_AGENT = "WeRead client spec",
        SKILL_VERSION = "test-skill",
        is_success_response = function(result, field)
            if type(result) ~= "table" then return false end
            local value = result[field or "succ"]
            return value == true or tonumber(value) == 1
        end,
        urlencode = function(value)
            return tostring(value):gsub("([^%w%-_%.~])", function(ch)
                return string.format("%%%02X", ch:byte())
            end)
        end,
    }
end

local Client = require("weread.lib.client")
local SessionState = require("weread.lib.session_state")
local merged_cookies = {}
local settings = {
    get = function(_self, key, default)
        if key == "cookies" then
            return { wr_skey = "XXX-cookie-value" }
        end
        return default
    end,
    merge_set_cookie = function(_self, value)
        merged_cookies[#merged_cookies + 1] = value
    end,
}
local client = Client:new(settings)

local mock = Client:new({
    mock_endpoint = "http://192.168.31.111:8765",
    get = settings.get,
    merge_set_cookie = function() error("mock must not persist server credentials") end,
})
responses[#responses + 1] = { body = "mock", code = 200, headers = { ["set-cookie"] = "ignored=value" } }
mock:request({ url = "https://weread.qq.com/web/test", headers = {
    Authorization = "Bearer sentinel", ["x-wr-ticket"] = "sentinel", ["x-wrpa-0"] = "sentinel",
    ["Content-Type"] = "application/json", Cookie = "sentinel=value", Host = "weread.qq.com",
} })
expect(requests[1].url == "http://192.168.31.111:8765/__proxy?url=https%3A%2F%2Fweread.qq.com%2Fweb%2Ftest",
    "mock did not route to the LAN endpoint")
expect(requests[1].headers.Authorization == nil and requests[1].headers.Cookie == nil
    and requests[1].headers["x-wr-ticket"] == nil and requests[1].headers["x-wrpa-0"] == nil
    and requests[1].headers.Host == nil, "credentials or original Host leaked to mock")
expect(requests[1].headers["Content-Type"] == "application/json" and requests[1].redirect == false,
    "mock changed payload type or allowed redirects")
expect(requests[1].proxy == mock.settings.mock_endpoint, "mock inherited the global HTTP proxy")
responses[#responses + 1] = { raise = "connection refused" }
local mock_ok = pcall(mock.request, mock, { url = "https://weread.qq.com/web/test" })
expect(not mock_ok and #requests == 2 and requests[2].url:find("192.168.31.111", 1, true),
    "mock failure fell back to production")
requests, timeout_calls, reset_count = {}, {}, 0

responses[#responses + 1] = {
    body = "ok",
    code = 200,
    headers = { ["Set-Cookie"] = "wr_ticket=new-ticket; Path=/" },
}
local body, code = client:request({
    url = "https://weread.qq.com/web/test",
    timeout = { 3, 7 },
})
expect(body == "ok" and code == 200, "basic request result was wrong")
expect(requests[1].headers.Cookie == "wr_skey=XXX-cookie-value",
    "WeRead cookie was not attached")
expect(timeout_calls[1][1] == 3 and timeout_calls[1][2] == 7,
    "request timeout was not applied")
expect(reset_count == 1, "timeout was not reset after successful request")
expect(merged_cookies[1] == "wr_ticket=new-ticket; Path=/",
    "response cookies were not persisted")

responses[#responses + 1] = { body = "public", code = 200 }
client:request({ url = "https://example.com/public" })
expect(requests[2].headers.Cookie == nil,
    "WeRead cookie leaked to a non-WeRead host")

responses[#responses + 1] = { raise = "transport failed" }
local ok, err = pcall(function()
    client:request({ url = "https://weread.qq.com/web/fail" })
end)
expect(not ok and tostring(err):find("transport failed", 1, true),
    "transport error was not propagated")
expect(reset_count == 3, "timeout was not reset after transport error")

responses[#responses + 1] = {
    body = "",
    code = 303,
    headers = { location = "https://cdn.example.net/book" },
}
responses[#responses + 1] = { body = "book", code = 200 }
local redirected, redirected_code, _, _, final_url = client:request_follow({
    url = "https://weread.qq.com/web/export",
    method = "POST",
    body = "{}",
    headers = {
        Authorization = "Bearer secret",
        Cookie = "manual=secret",
        Origin = "https://weread.qq.com",
        ["Content-Length"] = "2",
    },
})
expect(redirected == "book" and redirected_code == 200,
    "redirected response was not returned")
expect(final_url == "https://cdn.example.net/book",
    "final redirect URL was wrong")
local redirected_request = requests[#requests]
expect(redirected_request.method == "GET" and redirected_request.body == nil,
    "303 redirect did not switch POST to GET")
for key in pairs(redirected_request.headers) do
    local lower = tostring(key):lower()
    expect(lower ~= "authorization" and lower ~= "cookie"
        and lower ~= "origin" and lower ~= "content-length",
        "sensitive/entity header survived a cross-origin 303: " .. lower)
end

responses[#responses + 1] = {
    body = "",
    code = 302,
    headers = { location = "/again" },
}
responses[#responses + 1] = {
    body = "",
    code = 302,
    headers = { location = "/again" },
}
ok, err = pcall(function()
    client:request_follow({ url = "https://weread.qq.com/start" }, 1)
end)
expect(not ok and tostring(err):find("Too many redirects", 1, true),
    "redirect limit was not enforced")

logs = {}
responses[#responses + 1] = {
    body = "{\"errcode\":-202,\"errmsg\":\"raw response\"}",
    code = 499,
    headers = { ["content-type"] = "application/json" },
}
ok, err = pcall(function()
    client:get_text("https://weread.qq.com/web/failing-api")
end)
expect(not ok and tostring(err):find("HTTP 499", 1, true),
    "HTTP error details were not preserved")
local raw_response_log = table.concat(logs, "\n")
expect(raw_response_log:find(
    'response_body= {"errcode":-202,"errmsg":"raw response"}',
    1,
    true
), "HTTP failure log omitted the raw response body")

logs = {}
local gateway_settings = {
    get = function(_self, key, default)
        if key == "api_key" then return "private-api-key" end
        return default
    end,
    merge_set_cookie = function() end,
}
local gateway_client = Client:new(gateway_settings)
gateway_client.json_encode = function() return "{}" end
gateway_client.json_decode = function()
    return { errcode = -202, errmsg = "-202" }
end
responses[#responses + 1] = {
    body = '{"errcode":-202,"errmsg":"-202"}',
    code = 499,
    headers = { ["content-type"] = "application/json" },
}
ok = pcall(function()
    gateway_client:gateway("/shelf/sync", {})
end)
expect(not ok, "gateway HTTP failure was not propagated")
local gateway_failure_log = table.concat(logs, "\n")
expect(gateway_failure_log:find("api= /shelf/sync", 1, true),
    "gateway failure log omitted the logical API name")
expect(requests[#requests].diagnostic_api == nil,
    "diagnostic API metadata leaked into the HTTP request options")

logs = {}
client.json_decode = function(_self, _text)
    return { errcode = -300, errmsg = "application failure" }
end
local application_result = client:decode_http_json(
    '{"errcode":-300,"errmsg":"application failure"}',
    {
        method = "POST",
        url = "https://i.weread.qq.com/api/agent/gateway",
        code = 200,
        headers = { ["content-type"] = "application/json" },
    }
)
expect(application_result.errcode == -300,
    "application error response was not returned to the caller")
local application_error_log = table.concat(logs, "\n")
expect(application_error_log:find(
    'response_body= {"errcode":-300,"errmsg":"application failure"}',
    1,
    true
), "application failure log omitted the raw response body")

logs = {}
client.json_decode = function()
    error("invalid JSON")
end
ok, err = pcall(function()
    client:decode_http_json("<not-json>", {
        method = "GET",
        url = "https://weread.qq.com/web/invalid-json",
        code = 200,
    })
end)
expect(not ok and tostring(err):find("invalid JSON", 1, true),
    "JSON decode failure was not preserved")
local decode_failure_log = table.concat(logs, "\n")
expect(decode_failure_log:find("response_body= <not-json>", 1, true),
    "JSON decode failure log omitted the raw response body")

local shelf_client = Client:new(settings)
shelf_client.gateway = function(_self, api_name, params)
    expect(api_name == "/shelf/sync", "shelf helper used the wrong endpoint")
    expect(type(params) == "table" and next(params) == nil,
        "shelf helper unexpectedly sent parameters")
    return {
        books = { { bookId = "private-book-id", title = "Private title" } },
        archive = {},
        albums = {},
        mp = {},
    }, 200, {}
end
local shelf = shelf_client:get_shelf()
expect(#shelf.books == 1, "shelf helper did not return the response")
local success_log = table.concat(logs, "\n")
expect(success_log:find("api=/shelf/sync", 1, true),
    "shelf diagnostics omitted the endpoint")
expect(success_log:find("skill_version= test-skill", 1, true),
    "shelf diagnostics omitted the skill version")
expect(success_log:find("books= table(1)", 1, true),
    "shelf diagnostics omitted the response shape")
expect(not success_log:find("private-book-id", 1, true)
    and not success_log:find("Private title", 1, true),
    "shelf diagnostics leaked response contents")

logs = {}
shelf_client.gateway = function()
    error("HTTP 499, error_code=-202, error_message=-202")
end
ok, err = pcall(function()
    shelf_client:get_shelf()
end)
expect(not ok and tostring(err):find("error_code=-202", 1, true),
    "shelf helper did not preserve the gateway error")
local failure_log = table.concat(logs, "\n")
expect(failure_log:find("shelf sync failed", 1, true),
    "shelf failure diagnostics were not written")

local review_client = Client:new(settings)
local ok_review, data_review, err_review
ok_review, _, err_review = review_client:get_review_comments("")
expect(not ok_review and err_review == "empty review_id",
    "review comments rejected an empty review_id")

responses[#responses + 1] = {
    body = '{"reviewId":"r1","comments":[{"content":"hi"}],"commentsCount":1}',
    code = 200,
    headers = { ["content-type"] = "application/json" },
}
review_client.json_decode = function(_self, text)
    return { reviewId = "r1", comments = { { content = "hi" } }, commentsCount = 1, _raw = text }
end
local review_request_index = #requests + 1
ok_review, data_review, err_review = review_client:get_review_comments("r1", 60)
expect(ok_review and type(data_review) == "table"
    and data_review.commentsCount == 1 and err_review == nil,
    "review comments did not return parsed data")
local review_request = requests[review_request_index]
local review_url = review_request and review_request.url or ""
expect(review_url:find("/web/review/single?", 1, true)
    and review_url:find("reviewId=r1", 1, true)
    and review_url:find("commentsCount=60", 1, true)
    and review_url:find("commentsDirection=0", 1, true)
    and review_url:find("likesCount=0", 1, true)
    and review_url:find("synckey=0", 1, true),
    "review comments built the wrong URL: " .. tostring(review_url))

responses[#responses + 1] = { body = "not-json", code = 200 }
review_client.json_decode = function()
    error("invalid JSON")
end
ok_review, data_review, err_review = review_client:get_review_comments("r2")
expect(not ok_review and data_review == "not-json" and err_review == "invalid JSON",
    "review comments did not surface JSON decode failures")

responses[#responses + 1] = { body = "", code = 200 }
ok_review, _, err_review = review_client:get_review_comments("r3")
expect(not ok_review and err_review == "empty response",
    "review comments did not reject an empty body")

local download_path = os.tmpname()
os.remove(download_path)
responses[#responses + 1] = {
    body = "redirect-body-must-be-discarded",
    code = 302,
    headers = { location = "https://cdn.example.net/asset" },
}
responses[#responses + 1] = { body = "streamed-asset", code = 200 }
local saved_path, saved_bytes = client:download_to_file(
    "https://weread.qq.com/resource", download_path, { max_bytes = 1024 })
local saved_file = assert(io.open(saved_path, "rb"))
local saved_body = saved_file:read("*a")
saved_file:close()
expect(saved_body == "streamed-asset" and saved_bytes == #saved_body,
    "file download retained a redirect body or returned the wrong size")
os.remove(download_path)

responses[#responses + 1] = { body = "too-large", code = 200 }
ok = pcall(function()
    client:download_to_file(
        "https://weread.qq.com/large", download_path, { max_bytes = 2 })
end)
expect(not ok and io.open(download_path .. ".part", "rb") == nil,
    "oversized file download did not remove its partial output")

-- --- Auth error classification -------------------------------------------

responses, logs = {}, {}
client.json_decode = function() return { errCode = -2013, errMsg = "鉴权失败" } end
local classified = client:decode_http_json('{"errCode":-2013,"errMsg":"鉴权失败"}', {
    method = "POST",
    url = "https://weread.qq.com/web/book/read",
    code = 200,
    headers = { ["content-type"] = "application/json" },
})
expect(classified._auth_kind == "session_replaced",
    "session replacement was not classified")
expect(SessionState.is_invalid() == true
    and SessionState.reason() == "session_replaced",
    "classified session error did not mark the session invalid")
expect(client:auth_error_kind(-2013) == "session_replaced"
    and client:auth_error_kind(-2010) == "credential_invalid"
    and client:auth_error_kind(-2012) == "login_timeout"
    and client:auth_error_kind(-12013) == "wechat_auth_expired",
    "known auth error codes were misclassified")
expect(client:auth_error_kind(-9999) == nil and client:auth_error_kind(nil) == nil,
    "unknown auth codes must stay unclassified")
local classification_log = table.concat(logs, "\n")
expect(classification_log:find("auth error classified", 1, true)
    and classification_log:find("session_replaced", 1, true),
    "auth classification was not logged")

logs = {}
client.json_decode = function() return { errCode = -9999, errMsg = "unknown" } end
local unknown_result = client:decode_http_json('{"errCode":-9999}', {
    method = "GET", url = "https://weread.qq.com/web/x", code = 200,
})
expect(unknown_result._auth_kind == nil and unknown_result.errCode == -9999,
    "unknown error code must not be classified")

-- --- Cookie renewal hardening --------------------------------------------

local function new_renew_settings(initial)
    local values = initial or {}
    return {
        values = values,
        update_calls = {},
        get = function(self, key, default)
            local value = self.values[key]
            if value == nil then return default end
            return value
        end,
        set = function(self, key, value) self.values[key] = value end,
        flush = function(self) self.flush_count = (self.flush_count or 0) + 1 end,
        update_auth = function(self, credentials, options)
            self.update_calls[#self.update_calls + 1] = {
                credentials = credentials, options = options,
            }
            for key, value in pairs(credentials) do
                self.values[key] = value
            end
        end,
    }
end

responses = {}
local adopt_settings = new_renew_settings({
    session_generation = 2,
    cookies = { wr_skey = "old-key-12345678", wr_vid = "999" },
})
local adopt_client = Client:new(adopt_settings)
adopt_client.json_encode = function() return "{}" end
adopt_client.json_decode = function() return { errCode = -2013, errMsg = "鉴权失败" } end
responses[#responses + 1] = {
    body = '{"errCode":-2013}',
    code = 200,
    headers = { ["set-cookie"] = "wr_skey=XXX-replacement-key-12345; Path=/; HttpOnly" },
}
local adopted_ok, adopted_result = pcall(function()
    return adopt_client:renew_cookie()
end)
expect(adopted_ok and type(adopted_result) == "table" and adopted_result.errCode == -2013,
    "replacement-key renewal was not adopted as success")
expect(#adopt_settings.update_calls == 1
    and adopt_settings.update_calls[1].options.replace_cookies == true,
    "replacement credentials were not persisted atomically")
expect(adopt_settings.values.cookies.wr_skey == "XXX-replacement-key-12345"
    and adopt_settings.values.cookies.wr_vid == "999",
    "replacement credentials did not merge into the credential set")
expect(adopt_settings.values.session_generation == 3,
    "session generation was not bumped after adoption")
expect(SessionState.is_invalid() == false and SessionState.reason() == nil,
    "adopted renewal did not clear the invalid session state")

local body_settings = new_renew_settings({
    session_generation = 0,
    cookies = { wr_skey = "old-key-12345678" },
})
local body_client = Client:new(body_settings)
body_client.json_encode = function() return "{}" end
body_client.json_decode = function()
    return { errCode = -2013, skey = "body-replacement-98765" }
end
responses[#responses + 1] = { body = '{"errCode":-2013,"skey":"body-replacement-98765"}', code = 200 }
pcall(function() return body_client:renew_cookie() end)
expect(body_settings.values.cookies.wr_skey == "body-replacement-98765",
    "body replacement session key was not adopted")

local fail_settings = new_renew_settings({
    session_generation = 1,
    cookies = { wr_skey = "old-key-12345678" },
})
local fail_client = Client:new(fail_settings)
fail_client.json_encode = function() return "{}" end
fail_client.json_decode = function() return { errCode = -2013, errMsg = "鉴权失败" } end
responses[#responses + 1] = { body = '{"errCode":-2013}', code = 200 }
local fail_ok = pcall(function() return fail_client:renew_cookie() end)
expect(not fail_ok, "rejected renewal without replacement did not fail")
expect(#fail_settings.update_calls == 0
    and fail_settings.values.cookies.wr_skey == "old-key-12345678",
    "rejected renewal without a clear instruction polluted credentials")

-- A kicked rejection empties the login cookies; obey it, then still fail.
local kick_settings = new_renew_settings({
    session_generation = 4,
    cookies = {
        wr_skey = "old-key-12345678",
        wr_vid = "old-vid",
        wr_rt = "old-refresh",
    },
    wr_ticket = "keep-ticket",
    wr_wrpa = "keep-wrpa",
})
local kick_client = Client:new(kick_settings)
kick_client.json_encode = function() return "{}" end
kick_client.json_decode = function() return { errCode = -2013, errMsg = "鉴权失败" } end
responses[#responses + 1] = {
    body = '{"errCode":-2013}',
    code = 200,
    headers = { ["set-cookie"] = {
        "wr_pf=; Path=/; Domain=.weread.qq.com",
        "wr_rt=; Path=/; Domain=.weread.qq.com",
        "wr_skey=; Path=/; Domain=.weread.qq.com",
        "wr_vid=; Path=/; Domain=.weread.qq.com",
    } },
}
local kick_ok = pcall(function() return kick_client:renew_cookie() end)
expect(not kick_ok, "a clearing rejection must still fail the renewal")
expect(kick_settings.values.cookies.wr_skey == nil
    and kick_settings.values.cookies.wr_vid == nil
    and kick_settings.values.cookies.wr_rt == nil,
    "revoked cookies were not removed from the credential set")
expect(kick_settings.values.wr_ticket == "keep-ticket"
    and kick_settings.values.wr_wrpa == "keep-wrpa",
    "clearing cookies must not touch wr_ticket/wr_wrpa")
expect(SessionState.is_invalid() == true,
    "a clearing rejection must mark the session invalid")

local stale_settings = new_renew_settings({ cookies = { wr_skey = "old-key-12345678" } })
local generation_reads = { 5, 6 }
stale_settings.get = function(self, key, default)
    if key == "session_generation" then
        local value = table.remove(generation_reads, 1)
        if value == nil then return default end
        return value
    end
    local value = self.values[key]
    if value == nil then return default end
    return value
end
local stale_client = Client:new(stale_settings)
stale_client.json_encode = function() return "{}" end
stale_client.json_decode = function() return { succ = 1 } end
responses[#responses + 1] = {
    body = '{"succ":1}',
    code = 200,
    headers = { ["set-cookie"] = "wr_skey=XXX-stale-replacement-12345; Path=/" },
}
local stale_ok, stale_result, stale_err = pcall(function()
    return stale_client:renew_cookie()
end)
expect(stale_ok and stale_result == nil and stale_err == "stale",
    "stale renewal response was not ignored")
expect(#stale_settings.update_calls == 0
    and stale_settings.values.cookies.wr_skey == "old-key-12345678",
    "stale renewal overwrote or mutated credentials")

-- A stale clearing rejection must write nothing, not even the clearing Set-Cookie.
local stale_clear_settings = new_renew_settings({
    cookies = { wr_skey = "old-key-12345678", wr_vid = "old-vid", wr_rt = "old-refresh" },
})
local stale_clear_reads = { 7, 8 }
stale_clear_settings.get = function(self, key, default)
    if key == "session_generation" then
        local value = table.remove(stale_clear_reads, 1)
        if value == nil then return default end
        return value
    end
    local value = self.values[key]
    if value == nil then return default end
    return value
end
local stale_clear_client = Client:new(stale_clear_settings)
stale_clear_client.json_encode = function() return "{}" end
stale_clear_client.json_decode = function() return { errCode = -2013, errMsg = "鉴权失败" } end
responses[#responses + 1] = {
    body = '{"errCode":-2013}',
    code = 200,
    headers = { ["set-cookie"] = {
        "wr_skey=; Path=/; Domain=.weread.qq.com",
        "wr_vid=; Path=/; Domain=.weread.qq.com",
        "wr_rt=; Path=/; Domain=.weread.qq.com",
    } },
}
local clear_stale_ok, clear_stale_result, clear_stale_err = pcall(function()
    return stale_clear_client:renew_cookie()
end)
expect(clear_stale_ok and clear_stale_result == nil and clear_stale_err == "stale",
    "a stale clearing rejection must be ignored as stale")
expect(#stale_clear_settings.update_calls == 0,
    "a stale clearing rejection must not write credentials")
expect(stale_clear_settings.values.cookies.wr_skey == "old-key-12345678"
    and stale_clear_settings.values.cookies.wr_vid == "old-vid"
    and stale_clear_settings.values.cookies.wr_rt == "old-refresh",
    "a stale clearing rejection must leave credentials intact")

-- A successful renewal clears a session that was marked invalid.
SessionState.mark_invalid("login_timeout")
local clear_settings = new_renew_settings({
    session_generation = 0,
    cookies = { wr_skey = "old-key-12345678" },
})
local clear_client = Client:new(clear_settings)
clear_client.json_encode = function() return "{}" end
clear_client.json_decode = function() return { succ = 1 } end
responses[#responses + 1] = {
    body = '{"succ":1}',
    code = 200,
    headers = { ["set-cookie"] = "wr_skey=XXX-renewed-key-12345678; Path=/" },
}
local clear_ok = pcall(function() return clear_client:renew_cookie() end)
expect(clear_ok, "successful renewal raised an error")
expect(SessionState.is_invalid() == false and SessionState.reason() == nil,
    "a successful renewal did not clear the invalid session state")

print(("client_spec: %d checks"):format(checks))
