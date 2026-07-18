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

local function absolute_url(base_url, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    if location:match("^https?://") then
        return location
    end
    local scheme, host = tostring(base_url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

local function url_origin(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return nil
    end
    return scheme:lower() .. "://" .. authority:lower()
end

local function clear_cross_origin_headers(headers)
    for key in pairs(headers or {}) do
        local name = tostring(key):lower()
        if name == "authorization" or name == "cookie" or name == "origin" then
            headers[key] = nil
        end
    end
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
    local block_timeout = DEFAULT_TIMEOUT_SECONDS
    local total_timeout = -1
    if type(opts.timeout) == "table" and opts.timeout[1] then
        block_timeout = opts.timeout[1]
        total_timeout = opts.timeout[2] or block_timeout
    elseif type(opts.timeout) == "number" then
        block_timeout = opts.timeout
    end
    socketutil:set_timeout(block_timeout, total_timeout)

    local sink_to_use = opts.sink
    if not sink_to_use then
        response = {}
        sink_to_use = socketutil.table_sink(response)
    end

    local req_opts = merge_req_opts({
        method = body and "POST" or "GET",
        source = body and ltn12.source.string(body) or nil,
        sink = sink_to_use,
        headers = headers,
    }, opts)
    -- Redirects are handled explicitly by request_follow so credentials can be
    -- rebuilt for every destination instead of being copied across origins.
    req_opts.redirect = false

    local results = { pcall(http.request, req_opts) }
    socketutil:reset_timeout()
    if not results[1] then
        error(results[2])
    end
    local _, raw_code, resp_headers, status = results[2], results[3], results[4], results[5]
    if status == nil and type(raw_code) == "string" then
        status = raw_code
    end

    if not opts.sink then response = table.concat(response) end
    if is_handle_cookie and opts.persist_response_cookies ~= false then
        local set_cookie = header_value(resp_headers, "set-cookie")
        if set_cookie then
            self.settings:merge_set_cookie(set_cookie)
        end
    end

    return response, tonumber(raw_code), resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    local request_opts = deepcopy(opts or {})
    max_redirects = max_redirects or request_opts.maxredirects or 5
    request_opts.maxredirects = nil
    local url = request_opts.url

    for _redirect_index = 0, max_redirects do
        request_opts.url = url
        local text, code, headers, status = self:request(request_opts)
        local is_redirect = code == 301 or code == 302 or code == 303
            or code == 307 or code == 308
        if not is_redirect then
            return text, code, headers, status, url
        end

        local next_url = absolute_url(url, header_value(headers, "location"))
        if not next_url then
            return text, code, headers, status, url
        end
        if url_origin(url) ~= url_origin(next_url) then
            clear_cross_origin_headers(request_opts.headers)
        end
        if code == 303 or ((code == 301 or code == 302)
            and request_opts.method ~= "GET" and request_opts.method ~= "HEAD") then
            request_opts.method = "GET"
            request_opts.body = nil
            request_opts.source = nil
            if request_opts.headers then
                for key in pairs(request_opts.headers) do
                    if tostring(key):lower() == "content-length" then
                        request_opts.headers[key] = nil
                    end
                end
            end
        end
        url = next_url
    end
    error("Too many redirects")
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
    local text, code, resp_headers, _status, final_url = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if not code or code < 200 or code >= 300 then
        error(http_error(self, code, text, resp_headers))
    end
    return text, {
        code = code,
        content_type = header_value(resp_headers, "content-type"),
        length = #(text or ""),
        url = final_url or url,
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
    local text, code, resp_headers = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:renew_cookie()
    local result, code, resp_headers = self:post_json("https://weread.qq.com/web/login/renewal", {
        rq = "%2Fweb%2Fbook%2Fread",
        ql = false,
    }, {
        -- Do not persist renewal cookies until the response explicitly confirms
        -- success; failed renewals must leave the current credential set intact.
        persist_response_cookies = false,
    })
    if not WeRead.is_success_response(result) then
        error("Cookie renewal response did not include succ=1")
    end
    local updates = {}
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        updates.cookies = Cookie.merge_set_cookie(
            self.settings:get("cookies", {}),
            set_cookie
        )
    end
    local wr_ticket = scalar_header_value(resp_headers, "x-wr-ticket")
    if wr_ticket and wr_ticket ~= "" then
        updates.wr_ticket = wr_ticket
    end
    local wr_wrpa = scalar_header_value(resp_headers, "x-wrpa-0")
    if wr_wrpa and wr_wrpa ~= "" then
        updates.wr_wrpa = wr_wrpa
    end
    self.settings:update_auth(updates, { replace_cookies = true })
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

-- Reading statistics detail.
-- mode: "weekly" | "monthly" | "annually" | "overall"
-- base_time: optional Unix timestamp; server normalizes it to the period start
--            (Monday / 1st of month / Jan 1st). Pass 0/nil for the current period.
function Client:get_read_stats(mode, base_time)
    local params = { mode = mode or "monthly" }
    if base_time and tonumber(base_time) and tonumber(base_time) > 0 then
        params.baseTime = tonumber(base_time)
    end
    return self:gateway("/readdata/detail", params)
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
