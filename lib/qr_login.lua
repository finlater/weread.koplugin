local Cookie = require("lib.cookie")
local Device = require("device")
local I18n = require("lib.i18n")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local QRMessage = require("ui/widget/qrmessage")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local WeRead = require("lib.weread")

local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead][QRLogin]"
local BASE_URL = "https://weread.qq.com"
local SKILLS_PAGE_URL = BASE_URL .. "/r/weread-skills"
local LOGIN_UID_URL = BASE_URL .. "/api/auth/getLoginUid"
local LOGIN_INFO_URL = BASE_URL .. "/api/auth/getLoginInfo"
local USER_INFO_URL = BASE_URL .. "/api/userInfo"
local API_KEY_URL = BASE_URL .. "/api/skills/apikeyGet?only_show=1"
local LOGIN_SESSION_TIMEOUT_SECONDS = 300
local POLL_BLOCK_TIMEOUT_SECONDS = 5
local POLL_TOTAL_TIMEOUT_SECONDS = 8

local QRLogin = {}
QRLogin.__index = QRLogin

local function header_value(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then
            return value
        end
    end
    return nil
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deepcopy(item)
    end
    return copy
end

local function merge_response_cookies(cookies, headers)
    local set_cookie = header_value(headers, "set-cookie")
    if set_cookie then
        return Cookie.merge_set_cookie(cookies or {}, set_cookie)
    end
    return cookies or {}
end

local function error_text(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function is_timeout_error(err)
    local text = tostring(err or ""):lower()
    return text:find("timeout", 1, true) ~= nil
        or text:find("wantread", 1, true) ~= nil
end

local function sleep_seconds(seconds)
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket.sleep then
        socket.sleep(seconds)
    end
end

function QRLogin:new(host, client, settings)
    return setmetatable({
        host = host,
        client = client,
        settings = settings,
        generation = 0,
        login_cookies = nil,
        qr_dialog = nil,
        programmatic_close = false,
        started_at = nil,
    }, self)
end

function QRLogin:_request_json(url, opts, stage)
    opts = opts or {}
    stage = stage or "request"
    opts.url = url
    opts.skip_cookie = true
    local text, code, headers, status = self.client:request(opts)
    if not code then
        return nil, headers, status or "request failed"
    end
    if code < 200 or code >= 300 then
        local request_headers = opts.headers or {}
        local cookie_header = header_value(request_headers, "cookie")
        local vid_header = header_value(request_headers, "x-vid")
        local skey_header = header_value(request_headers, "x-skey")
        logger.warn(
            LOG_MODULE,
            stage, "rejected:", "HTTP", tostring(code),
            "cookie_bytes=", tostring(#tostring(cookie_header or "")),
            "x_vid_bytes=", tostring(#tostring(vid_header or "")),
            "x_skey_bytes=", tostring(#tostring(skey_header or ""))
        )
        error(stage .. " failed: HTTP " .. tostring(code))
    end
    local data = self.client:json_decode(text)
    if type(data) ~= "table" then
        error("WeRead returned an invalid JSON response")
    end
    return data, headers
end

function QRLogin:_begin_protocol()
    local login_cookies = {}
    local _, page_code, page_headers = self.client:request_follow({
        url = SKILLS_PAGE_URL,
        method = "GET",
        skip_cookie = true,
        maxredirects = 5,
        timeout = { 10, 20 },
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = BASE_URL .. "/",
        },
    })
    login_cookies = merge_response_cookies(login_cookies, page_headers)
    if not page_code or page_code < 200 or page_code >= 300 then
        error("Unable to open WeRead login page (HTTP " .. tostring(page_code) .. ")")
    end

    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
    }
    local cookie_header = Cookie.to_header(login_cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end

    local data, response_headers = self:_request_json(LOGIN_UID_URL, {
        method = "GET",
        timeout = { 10, 20 },
        headers = headers,
    }, "getLoginUid")
    login_cookies = merge_response_cookies(login_cookies, response_headers)
    if type(data.uid) ~= "string" or data.uid == "" then
        error("WeRead did not return a valid login UID")
    end

    self.login_cookies = login_cookies
    return data.uid
end

function QRLogin:_poll_protocol(uid, otp)
    if type(uid) ~= "string" or uid == "" then
        error("Missing QR login UID")
    end

    local url = LOGIN_INFO_URL .. "?uid=" .. WeRead.urlencode(uid) .. "&otp"
    if type(otp) == "string" and otp ~= "" then
        url = url .. "=" .. WeRead.urlencode(otp)
    end

    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
    }
    local cookie_header = Cookie.to_header(self.login_cookies or {})
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end

    local data, response_headers, request_error = self:_request_json(url, {
        method = "GET",
        timeout = { POLL_BLOCK_TIMEOUT_SECONDS, POLL_TOTAL_TIMEOUT_SECONDS },
        headers = headers,
    }, "getLoginInfo")
    if not data then
        if is_timeout_error(request_error) or request_error == "request failed" then
            return { transport_pending = true }
        end
        error(request_error)
    end
    self.login_cookies = merge_response_cookies(self.login_cookies, response_headers)
    return data
end

function QRLogin:_authenticated_get(url, cookies, web_login_vid, access_token, stage)
    for attempt = 1, 3 do
        local ok, data, response_headers = pcall(function()
            return self:_request_json(url, {
                method = "GET",
                timeout = { 10, 20 },
                headers = {
                    ["Accept"] = "application/json, text/plain, */*",
                    ["Referer"] = SKILLS_PAGE_URL,
                    ["Cookie"] = Cookie.to_header(cookies),
                    ["X-Vid"] = web_login_vid,
                    ["X-Skey"] = access_token,
                },
            }, stage)
        end)
        if ok then
            return data, merge_response_cookies(cookies, response_headers)
        end
        local retryable = tostring(data):find("HTTP 401", 1, true) ~= nil
        if not retryable or attempt == 3 then
            error(data)
        end
        logger.warn(LOG_MODULE, stage, "temporarily unauthorized; retrying:", tostring(attempt))
        sleep_seconds(0.5)
    end
end

function QRLogin:_complete_protocol(login_result, generation)
    if type(login_result) ~= "table" or login_result.succeed ~= true then
        error("QR login has not succeeded")
    end

    local web_login_vid = tostring(login_result.webLoginVid or "")
    local access_token = tostring(login_result.accessToken or "")
    local refresh_token = tostring(login_result.refreshToken or "")
    if web_login_vid == "" or access_token == "" then
        error("QR login response is missing account credentials")
    end

    -- A QR login represents a complete account switch. Build a fresh jar from
    -- this login session so credentials from a previously signed-in account
    -- cannot leak into the new session.
    local cookies = deepcopy(self.login_cookies or {})
    cookies.wr_vid = web_login_vid
    cookies.wr_skey = access_token
    cookies.wr_ql = "0"
    if refresh_token ~= "" then
        cookies.wr_rt = WeRead.urlencode(refresh_token)
    end

    local user_url = USER_INFO_URL .. "?userVid=" .. WeRead.urlencode(web_login_vid)
    local user_info
    user_info, cookies = self:_authenticated_get(
        user_url,
        cookies,
        web_login_vid,
        access_token,
        "userInfo"
    )

    local api_result
    local api_key = ""
    for attempt = 1, 3 do
        api_result, cookies = self:_authenticated_get(
            API_KEY_URL,
            cookies,
            web_login_vid,
            access_token,
            "apikeyGet"
        )
        api_key = type(api_result.apikey) == "string" and api_result.apikey or ""
        if api_key ~= "" then
            break
        end
        if attempt < 3 then
            sleep_seconds(0.5)
        end
    end
    if api_key == "" then
        error(_("No official API key was returned. This account has not enabled WeRead Skill.\n\nOpen WeRead app → Me → Settings → WeRead Skill → Get API Key, then scan again."))
    end
    if generation ~= self.generation then
        error("QR login was cancelled")
    end

    local account = {
        name = type(user_info.name) == "string" and user_info.name or "",
        user_vid = web_login_vid,
        login_method = "qr",
        login_time = os.time(),
    }
    self.settings:update_auth({
        cookies = cookies,
        api_key = api_key,
        wr_ticket = "",
        wr_wrpa = "",
        account = account,
    }, { replace_cookies = true })
    self.login_cookies = nil
    return account
end

function QRLogin:_close_qr_dialog(programmatic)
    local dialog = self.qr_dialog
    if not dialog then
        return
    end
    self.qr_dialog = nil
    self.programmatic_close = programmatic == true
    UIManager:close(dialog)
    self.programmatic_close = false
end

function QRLogin:cancel()
    self.generation = self.generation + 1
    self.login_cookies = nil
    self.started_at = nil
    self:_close_qr_dialog(true)
end

function QRLogin:start()
    if not self.host:isNetworkOnline() then
        self.host:showOffline(_("QR login"))
        return
    end

    self:cancel()
    local generation = self.generation
    self.started_at = os.time()
    self.host:showBusy(_("Getting login QR code..."))
    self.host:runOnlineTask(_("QR login"), function()
        local ok, uid_or_error = pcall(function()
            return self:_begin_protocol()
        end)
        self.host:closeBusy()
        if generation ~= self.generation then
            return
        end
        if not ok then
            logger.err(LOG_MODULE, "get login UID failed:", error_text(uid_or_error))
            self.host:showInfo(T(_("QR login failed:\n%1"), error_text(uid_or_error)))
            return
        end
        self:_show_qr(uid_or_error, generation)
    end)
end

function QRLogin:_show_qr(uid, generation)
    local screen_width = Device.screen:getWidth()
    local screen_height = Device.screen:getHeight()
    local qr_size = math.floor(math.min(screen_width, screen_height) * 0.72)
    local dialog
    dialog = QRMessage:new{
        text = BASE_URL .. "/web/confirm?uid=" .. WeRead.urlencode(uid),
        -- QRMessage centers its framed content on the screen. Keeping the frame
        -- smaller than the viewport makes it a dismissible popup instead of a
        -- full-screen QR surface; tapping the modal surface (or pressing a key)
        -- cancels the login flow through dismiss_callback.
        width = qr_size,
        height = qr_size,
        dismiss_callback = function()
            if self.qr_dialog == dialog then
                self.qr_dialog = nil
            end
            if not self.programmatic_close and generation == self.generation then
                self:cancel()
                self.host:showTransientInfo(_("QR login cancelled."), 2)
            end
        end,
        scale_factor = 0.9,
    }
    self.qr_dialog = dialog
    UIManager:show(dialog)
    self.host:refreshUI()

    UIManager:scheduleIn(0.5, function()
        if generation == self.generation and self.qr_dialog == dialog then
            self:_poll(uid, generation)
        end
    end)
end

function QRLogin:_schedule_poll(uid, generation)
    UIManager:scheduleIn(0.5, function()
        if generation == self.generation and self.qr_dialog then
            self:_poll(uid, generation)
        end
    end)
end

function QRLogin:_poll(uid, generation, otp)
    if os.time() - (self.started_at or os.time()) > LOGIN_SESSION_TIMEOUT_SECONDS then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The QR code has expired. Please try again."))
        return
    end

    local ok, result = pcall(function()
        return self:_poll_protocol(uid, otp or "")
    end)
    if generation ~= self.generation then
        return
    end
    if not ok then
        if is_timeout_error(result) then
            self:_schedule_poll(uid, generation)
            return
        end
        self:_close_qr_dialog(true)
        self:cancel()
        logger.err(LOG_MODULE, "login polling failed:", error_text(result))
        self.host:showInfo(T(_("QR login failed:\n%1"), error_text(result)))
        return
    end
    if result.transport_pending then
        self:_schedule_poll(uid, generation)
        return
    end
    if result.succeed == true then
        self:_close_qr_dialog(true)
        self:_complete(result, generation)
        return
    end

    local logic_code = tostring(result.logicCode or "")
    if logic_code == "NEED_OTP" then
        self:_close_qr_dialog(true)
        self:_show_otp(uid, generation)
    elseif logic_code == "LOGIN_TIMEOUT" then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The QR code has expired. Please try again."))
    elseif logic_code == "OTP_EXPIRED" then
        self:_close_qr_dialog(true)
        self:cancel()
        self.host:showInfo(_("The verification code has expired. Please try again."))
    elseif logic_code == "OTP_NOT_MATCH" then
        self:_close_qr_dialog(true)
        self:_show_otp(uid, generation, _("Incorrect verification code."))
    else
        self:_close_qr_dialog(true)
        self:cancel()
        local message = logic_code ~= "" and logic_code or _("Unknown login response")
        self.host:showInfo(T(_("QR login failed:\n%1"), message))
    end
end

function QRLogin:_show_otp(uid, generation, error_message)
    local description = _("Enter the four-digit verification code shown on your phone.")
    if error_message and error_message ~= "" then
        description = error_message .. "\n\n" .. description
    end

    local dialog
    dialog = InputDialog:new{
        title = _("Verification code required"),
        input = "",
        input_type = "text",
        description = description,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        self:cancel()
                    end,
                },
                {
                    text = _("Verify"),
                    is_enter_default = true,
                    callback = function()
                        local otp = tostring(dialog:getInputText() or "")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                        if not otp:match("^%d%d%d%d$") then
                            self.host:showInfo(_("The verification code must contain four digits."))
                            return
                        end
                        UIManager:close(dialog)
                        self.host:showBusy(_("Verifying login..."))
                        self.host:runOnlineTask(_("QR login"), function()
                            local ok, result = pcall(function()
                                return self:_poll_protocol(uid, otp)
                            end)
                            self.host:closeBusy()
                            if generation ~= self.generation then
                                return
                            end
                            if not ok then
                                if is_timeout_error(result) then
                                    self:_show_otp(uid, generation, _("Verification timed out. Please try again."))
                                else
                                    logger.err(LOG_MODULE, "OTP verification failed:", error_text(result))
                                    self:cancel()
                                    self.host:showInfo(T(_("QR login failed:\n%1"), error_text(result)))
                                end
                            elseif result.transport_pending then
                                self:_show_otp(uid, generation, _("Verification timed out. Please try again."))
                            elseif result.succeed == true then
                                self:_complete(result, generation)
                            else
                                local code = tostring(result.logicCode or "")
                                if code == "OTP_NOT_MATCH" or code == "NEED_OTP" then
                                    self:_show_otp(uid, generation, _("Incorrect verification code."))
                                elseif code == "OTP_EXPIRED" then
                                    self:cancel()
                                    self.host:showInfo(_("The verification code has expired. Please try again."))
                                else
                                    self:cancel()
                                    local message = code ~= "" and code or _("Unknown login response")
                                    self.host:showInfo(T(_("QR login failed:\n%1"), message))
                                end
                            end
                        end)
                    end,
                },
            },
        },
    }
    self.host:showInputDialog(dialog)
end

function QRLogin:_complete(login_result, generation)
    self.host:showBusy(_("Completing WeRead login..."))
    self.host:runOnlineTask(_("QR login"), function()
        local ok, account_or_error = pcall(function()
            return self:_complete_protocol(login_result, generation)
        end)
        self.host:closeBusy()
        if generation ~= self.generation then
            return
        end
        if not ok then
            logger.err(LOG_MODULE, "complete login failed:", error_text(account_or_error))
            self:cancel()
            self.host:showInfo(T(_("QR login failed:\n%1"), error_text(account_or_error)))
            return
        end

        local account_name = account_or_error.name
        if type(account_name) ~= "string" or account_name == "" then
            account_name = _("Unknown account")
        end
        logger.info(LOG_MODULE, "login completed")
        self.host:refreshLoginMenu()
        self.host:showInfo(T(
            _("WeRead login successful.\n\nAccount: %1\nCookie: %2\nOfficial API key: %3"),
            account_name,
            _("configured"),
            _("configured")
        ))
    end)
end

return QRLogin
