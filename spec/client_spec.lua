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
        urlencode = function(value)
            return tostring(value):gsub("([^%w%-_%.~])", function(ch)
                return string.format("%%%02X", ch:byte())
            end)
        end,
    }
end

local Client = require("weread.lib.client")
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
local ok_review, data_review, err_review = review_client:get_review_comments("")
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
ok_review, data_review, err_review = review_client:get_review_comments("r3")
expect(not ok_review and err_review == "empty response",
    "review comments did not reject an empty body")

print(("client_spec: %d checks"):format(checks))
