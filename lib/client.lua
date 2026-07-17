local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local http = require("socket.http")
local Cookie = require("lib.cookie")
local WeRead = require("lib.weread")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local unpack_args = unpack or table.unpack

local Client = {}
Client.__index = Client

local function header_value(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then return nil end
    if headers[name] ~= nil then return headers[name] end
    local target = name:lower()
    if headers[target] ~= nil then return headers[target] end
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then return value end
    end
    return nil
end

local function scalar_header_value(headers, name)
    local value = header_value(headers, name)
    if type(value) == "table" then
        if value[1] == nil then return nil end
        return tostring(value[1])
    end
    return value
end

local function http_error(client, code, text, headers)
    text = text or ""
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function merge_req_opts(default_opts, user_opts)
    default_opts = default_opts or {}
    if not user_opts then 
        return deepcopy(default_opts)
    end
    local result = deepcopy(default_opts)
    for k, v in pairs(user_opts) do
        if k == "headers" and type(v) == "table" then
            result.headers = result.headers or {}
            for hk, hv in pairs(v) do
                local target = hk:lower()
                for existing_k, _ in pairs(result.headers) do
                    if type(existing_k) == "string" and existing_k:lower() == target then
                        result.headers[existing_k] = nil
                    end
                end
                result.headers[hk] = deepcopy(hv)
            end
        else
            result[k] = deepcopy(v) 
        end
    end 
    return result
end

local function is_weread_url(url)
    local authority = tostring(url or ""):match("^https?://([^/]+)")
    if not authority then
        return false
    end
    local host = authority:lower():gsub(":%d+$", "")
    return host == "weread.qq.com" or host:sub(-#".weread.qq.com") == ".weread.qq.com"
end

function Client:new(settings)
    return setmetatable({
        settings = settings,
    }, self)
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:request(opts)
    opts = opts or {}
    local body = opts.body
    local response
    local headers = {
        ["User-Agent"] = WeRead.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*"
    }
    local is_handle_cookie = not opts.skip_cookie and is_weread_url(opts.url)

    if is_handle_cookie then
        local cookies = self.settings:get("cookies", {})
        local cookie_header = Cookie.to_header(cookies)
        if cookie_header ~= "" then 
            headers["Cookie"] = cookie_header 
        end
    end

    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local sink_to_use = opts.sink
    if not sink_to_use then
        response = {}
        sink_to_use = socketutil.table_sink(response)
    end

    local req_opts = merge_req_opts({
        method = body and "POST" or "GET",
        source = body and ltn12.source.string(body) or nil,
        sink = sink_to_use,
        headers = headers
    }, opts)

    if type(opts.timeout) == "table" and opts.timeout[1] then
        local t1 = opts.timeout[1]
        local t2 = opts.timeout[2] or t1
        socketutil:set_timeout(t1, t2)
    end
    
    local _, code, resp_headers, status = http.request(req_opts)
    if opts.timeout then socketutil:reset_timeout() end

    if not opts.sink then response = table.concat(response) end
    if is_handle_cookie then
        local set_cookie = header_value(resp_headers, "set-cookie")
        if set_cookie then
            local cookies = self.settings:get("cookies", {})
            self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
            self.settings:flush()
        end
    end

    return response, tonumber(code), resp_headers or {}, status
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local referer = header_value(opts.headers, "Referer") or opts.referer
    local req_opts = merge_req_opts(opts, {
        url = url,
        method = "POST",
        body = self:json_encode(data),
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = referer or "https://weread.qq.com/",
        }})
    local text, code, resp_headers = self:request(req_opts)
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_text(url, opts)
    opts = opts or {}
    local accept = header_value(opts.headers, "Accept") or opts.accept
    local referer = header_value(opts.headers, "Referer") or opts.referer
    local req_opts = merge_req_opts(opts, {
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = referer or "https://weread.qq.com/",
        }})
    local text, code, resp_headers = self:request(req_opts)
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_public_text(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://mp.weixin.qq.com/",
        }
    })
    local text, code, resp_headers = self:get_text(url, req_opts)
    return text, {
        code = code,
        content_type = header_value(resp_headers, "content-type"),
        length = #(text or ""),
        url = url,
    }
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "*/*",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://weread.qq.com/",
        }
    })
    return self:get_text(url, req_opts)
end

function Client:renew_cookie()
    local result, code, resp_headers = self:post_json("https://weread.qq.com/web/login/renewal", {
        rq = "%2Fweb%2Fbook%2Fread",
        ql = false,
    })
    local changed = false
    local wr_ticket = scalar_header_value(resp_headers, "x-wr-ticket")
    if wr_ticket and wr_ticket ~= "" then
        self.settings:set("wr_ticket", wr_ticket)
        changed = true
    end
    local wr_wrpa = scalar_header_value(resp_headers, "x-wrpa-0")
    if wr_wrpa and wr_wrpa ~= "" then
        self.settings:set("wr_wrpa", wr_wrpa)
        changed = true
    end
    if changed then
        self.settings:flush()
    end
    return result, code, resp_headers
end

function Client:gateway(api_name, params)
    local payload = merge_req_opts({
        api_name = api_name,
        skill_version = (params and params.skill_version) or WeRead.SKILL_VERSION
    }, params) 
    
    local api_key = self.settings:get("api_key", "")
    if api_key == "" then
        error("WeRead API key is not configured")
    end
    return self:post_json("https://i.weread.qq.com/api/agent/gateway", payload, {
        skip_cookie = true,
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
        },
    })
end

function Client:get_book_info(book_id)
    return self:gateway("/book/info", { bookId = book_id })
end

function Client:get_progress(book_id)
    return self:gateway("/book/getprogress", { bookId = book_id })
end

function Client:get_mp_articles(book_id, max_idx, count, wr_ticket)
    local url = string.format(
        "https://weread.qq.com/web/mp/articles?bookId=%s&maxIdx=%d&count=%d",
        WeRead.urlencode(book_id),
        max_idx or 0,
        count or 100
    )

    local custom_headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = "https://weread.qq.com/",
    }

    if wr_ticket and wr_ticket ~= "" then
        custom_headers["x-wr-ticket"] = wr_ticket
    end
    
    local wrpa = self.settings:get("wr_wrpa", "")
    if wrpa ~= "" then
        custom_headers["x-wrpa-0"] = wrpa
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = custom_headers,
    })

    if code and code >= 200 and code < 300 then
        local data = self:json_decode(text)
        if data.errCode and data.errCode ~= 0 then
            return nil, data.errCode
        end
        return data, nil
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_mp_content(review_id, opts)
    opts = opts or {}
    local url = "https://weread.qq.com/web/mp/content?reviewId=" .. WeRead.urlencode(review_id)
    
    local custom_headers = {
        ["Accept"] = "text/html,application/xhtml+xml,*/*",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }
    if not opts.skip_mp_auth_headers then
        local wr_ticket = self.settings:get("wr_ticket", "")
        if wr_ticket ~= "" then custom_headers["x-wr-ticket"] = wr_ticket end
        
        local wrpa = self.settings:get("wr_wrpa", "")
        if wrpa ~= "" then custom_headers["x-wrpa-0"] = wrpa end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = custom_headers,
        timeout = opts.timeout,
    })

    if code and code >= 200 and code < 300 then
        return text, {
            code = code,
            content_type = header_value(resp_headers, "content-type"),
            length = #(text or ""),
            url = url,
        }
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:report_read(payload, referer)
    return self:post_json("https://weread.qq.com/web/book/read", payload, {
        referer = referer or "https://weread.qq.com/",
    })
end

local SIMPLE_API_URL = "https://weread.qq.com/wrwebsimplenjlogic/api/%s?platform=desktop"
local SIMPLE_LOGIN_HEADERS = {
    ["Referer"] = "https://weread.qq.com/wrwebsimplenjlogic/login",
    ["User-Agent"] = WeRead.SIMPLE_USER_AGENT,
}
local get_simple_api =function(method)
    return string.format(SIMPLE_API_URL, method)
end

function Client:_report_kv(payload)
    local url = get_simple_api("kvlog")
    return self:post_json(url, payload, {
        headers = SIMPLE_LOGIN_HEADERS,
        timeout = {5, 8},
    })
end

function Client:generate_cgi_key()
    math.randomseed(os.time())
    return tostring(math.random(100, 999))    
end

function Client:generate_wr_fp()
    local device_id = G_reader_settings and G_reader_settings:readSetting("device_id") or ""
    if type(device_id) ~= "string" or device_id == "" then
        return tostring(math.random(100000000, 2147483647))
    end
    local h = 0
    local MAX_UINT32 = 4294967296 -- 2^32
    for i = 1, #device_id do
        h = (h * 31 + string.byte(device_id, i)) % MAX_UINT32
    end
    return tostring(math.floor(h))
end

function Client:get_confirm_url()
    local url = get_simple_api("getuid")
    local text = self:get_text(url, {
        headers = SIMPLE_LOGIN_HEADERS,
        timeout = {5, 10},
    })
    self:_report_kv({
        vid = 0,
        itemNames = {
            global = { "WebSimple_Enter" }
        }
    })
    local res = self:json_decode(text)
    if res and res.uid then
        return {
            url = string.format("https://weread.qq.com/web/confirm?pf=2&uid=%s", res.uid),
            uid = res.uid
        }
    end
    return res
end

function Client:get_login_info(uid, cgi_key)
    local url = get_simple_api("getlogininfo")
    local data = {
        uid = uid,
        cgiKey = tostring(cgi_key),
    }
    return self:post_json(url, data, {
        headers = SIMPLE_LOGIN_HEADERS,
        timeout = {5, 10},
    })
end

function Client:web_login(payload)
    local url = get_simple_api("weblogin")
    return self:post_json(url, payload, {
        headers = SIMPLE_LOGIN_HEADERS,
        timeout = {5, 10},
    })
end

function Client:get_user_info(user_vid)
    local url = WeRead.user_info_url(user_vid)
    local text = self:get_text(url, {headers = SIMPLE_LOGIN_HEADERS,timeout = {5, 10}})
    return self:json_decode(text)
end

function Client:get_skills_key()
    local url = WeRead.skills_key_url()
    local text = self:get_text(url, {timeout = {5, 10}})
    return self:json_decode(text)
end

function Client:get_chapter_underlines(book_id, chapter_uid)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end

    local ok, result = pcall(function()
        return self:gateway("/book/underlines", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" then
        return false, nil, "underlines: gateway returned non-table"
    end
    return true, result
end

function Client:build_chapter_review_batches(ranges)
    local BATCH_SIZE = 5
    local batches = {}
    for batch_start = 1, #(ranges or {}), BATCH_SIZE do
        local batch = {}
        for index = batch_start, math.min(batch_start + BATCH_SIZE - 1, #ranges) do
            batch[#batch + 1] = {
                range = ranges[index],
                maxIdx = 0,
                count = 30,
                synckey = 0,
            }
        end
        batches[#batches + 1] = batch
    end
    return batches
end

function Client:get_chapter_reviews_batch(book_id, chapter_uid, batch)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end
    if type(batch) ~= "table" or #batch == 0 then
        return true, { reviews = {} }
    end

    local ok, result = pcall(function()
        return self:gateway("/book/readreviews", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
            reviews = batch,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" or type(result.reviews) ~= "table" then
        return false, nil, "readreviews: gateway returned invalid data"
    end
    return true, result
end

function Client:get_chapter_reviews(book_id, chapter_uid, ranges)
    if type(ranges) ~= "table" or #ranges == 0 then
        return true, { reviews = {} }
    end

    local all_reviews = {}
    local batches = self:build_chapter_review_batches(ranges)
    local socket_ok, socket = pcall(require, "socket")

    for batch_index, batch in ipairs(batches) do
        local ok, result = self:get_chapter_reviews_batch(book_id, chapter_uid, batch)
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            for _, review in ipairs(result.reviews) do
                all_reviews[#all_reviews + 1] = review
            end
        end

        if batch_index < #batches and socket_ok and socket.sleep then
            socket.sleep(0.3)
        end
    end

    return true, { reviews = all_reviews }
end

return Client
