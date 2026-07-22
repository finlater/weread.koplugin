local Content = require("lib.content")
local WeRead = require("lib.weread")

local ok_logger, logger = pcall(require, "logger")
if not ok_logger then
    logger = nil
end

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
if not ok_ffiutil then
    ffiutil = nil
end

local LOG_MODULE = "[WeRead][ReadReport]"
local DEFAULT_INTERVAL_SECONDS = 30
local MIN_INTERVAL_SECONDS = 10
local CONTEXT_TTL_SECONDS = 15 * 60
local RENEWAL_COOLDOWN_SECONDS = 10 * 60
local JOB_POLL_INITIAL_SECONDS = 0.25
local JOB_POLL_MAX_SECONDS = 2
local JOB_TIMEOUT_SECONDS = 180
local JOB_COLLECT_INTERVAL_SECONDS = 2

-- Context fields that the subprocess sends back for the parent to persist.
-- Mirrors the scalar reading-state fields stored by BookStore; the chapter
-- catalog itself stays in the on-disk catalog cache written by the child.
local CONTEXT_FIELDS = {
    "title", "reader_url", "app_id", "psvts", "pclts", "token",
    "chapter_uid", "chapter_idx", "chapter_offset", "progress", "summary",
    "read_context_updated_at",
}

local ReadReport = {}
ReadReport.__index = ReadReport

local function log(level, ...)
    if logger and type(logger[level]) == "function" then
        logger[level](LOG_MODULE, ...)
    end
end

local function make_subprocess_runner()
    if not ffiutil or type(ffiutil.runInSubProcess) ~= "function" then
        return nil
    end
    return {
        -- Returns pid, parent_read_fd on success; false, error message on failure.
        run = function(child_func)
            return ffiutil.runInSubProcess(child_func, true)
        end,
        -- Blocking write from inside the child; closes the fd when done.
        write_all = function(fd, data)
            return ffiutil.writeToFD(fd, data, true)
        end,
        -- Non-blocking waitpid; also reaps the child once it has exited.
        is_done = function(pid)
            return ffiutil.isSubProcessDone(pid)
        end,
        terminate = function(pid)
            ffiutil.terminateSubProcess(pid)
        end,
        -- Non-blocking readable-size probe (0 when nothing is buffered).
        read_size = function(fd)
            return ffiutil.getNonBlockingReadSize(fd)
        end,
        -- Reads until EOF and closes the fd.
        read_all = function(fd)
            return ffiutil.readAllFromFD(fd)
        end,
    }
end

local function book_record(books, book_id)
    if type(books) ~= "table" then
        return nil
    end
    return books[tostring(book_id)] or books[book_id]
end

local function response_body(result)
    if type(result) ~= "table" then
        return result
    end
    if result.succ ~= nil or result.synckey ~= nil then
        return result
    end
    if type(result.data) == "table" then
        return result.data
    end
    if type(result.result) == "table" then
        return result.result
    end
    return result
end

local function table_keys(value)
    if type(value) ~= "table" then
        return ""
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    return table.concat(keys, "|")
end

local function response_accepted(result, http_code)
    local body = response_body(result)
    if WeRead.is_success_response(body) then
        return true, body
    end
    if type(body) ~= "table" then
        return false, body
    end
    if body.synckey ~= nil then
        return true, body
    end
    local error_code = body.errCode or body.errcode or body.errorCode
        or result.errCode or result.errcode or result.errorCode
    if error_code ~= nil then
        return false, body
    end
    return false, body
end

local function full_response_body(client, result)
    if type(result) == "table" and client and type(client.json_encode) == "function" then
        local ok, encoded = pcall(function()
            return client:json_encode(result)
        end)
        if ok then
            return encoded
        end
    end
    return tostring(result)
end

local function response_summary(client, result, http_code)
    if type(result) ~= "table" then
        return "non_table_response, http=" .. tostring(http_code)
            .. ", response_body=" .. full_response_body(client, result)
    end
    local body = response_body(result)
    local parts = {
        "http=" .. tostring(http_code),
        "keys=" .. table_keys(result),
        "body_keys=" .. table_keys(body),
        "succ=" .. tostring(type(body) == "table" and body.succ or nil),
        "has_synckey=" .. tostring(type(body) == "table" and body.synckey ~= nil or false),
    }
    local code = type(body) == "table" and (body.errCode or body.errcode or body.code)
        or result.errCode or result.errcode or result.code
    local message = type(body) == "table" and (body.errMsg or body.errmsg or body.message or body.msg)
        or result.errMsg or result.errmsg or result.message or result.msg
    if code ~= nil then
        parts[#parts + 1] = "error_code=" .. tostring(code)
    end
    if message ~= nil then
        parts[#parts + 1] = "error_message="
            .. tostring(message):gsub("[%c]+", " "):sub(1, 160)
    end
    -- Only rejected reading reports call this function. Keep the complete
    -- decoded response in the failure log so unexpected server replies can be
    -- diagnosed without enabling verbose logging for successful reports.
    parts[#parts + 1] = "response_body=" .. full_response_body(client, result)
    return table.concat(parts, ", ")
end

function ReadReport:new(options)
    options = options or {}
    assert(options.settings, "read report settings are required")
    assert(options.client, "read report client is required")
    assert(options.scheduler, "read report scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        get_document = options.get_document,
        detect_book = options.detect_book,
        is_online = options.is_online or function() return true end,
        now = options.now or os.time,
        subprocess = options.subprocess or make_subprocess_runner(),
        state = "stopped",
        generation = 0,
        count = 0,
        failure_count = 0,
        consecutive_failures = 0,
    }
    return setmetatable(object, self)
end

function ReadReport:_config()
    return self.settings:get("read_report")
end

function ReadReport:_interval()
    local interval = tonumber(self:_config().interval_seconds) or DEFAULT_INTERVAL_SECONDS
    return math.max(MIN_INTERVAL_SECONDS, interval)
end

function ReadReport:status()
    return {
        running = self.task ~= nil,
        state = self.state,
        count = self.count or 0,
        failure_count = self.failure_count or 0,
        consecutive_failures = self.consecutive_failures or 0,
        last_time = self.last_time,
        last_error = self.last_error,
        last_error_kind = self.last_error_kind,
        stop_reason = self.stop_reason,
        target_book_id = self.current_book_id,
        target_book_title = self.current_book_title,
        target_source = self.current_book_source,
    }
end

function ReadReport:resolve_target()
    local config = self:_config()
    local has_document = self.get_document() ~= nil
    if config.mode == "manual"
        and tostring(config.book_id or "") ~= ""
        and (has_document or config.report_on_open == false) then
        return tostring(config.book_id),
            tostring(config.book_title or "") ~= "" and config.book_title or tostring(config.book_id),
            "manual"
    end

    if not has_document then
        return nil, nil, "no_document"
    end

    local detected_id = self.detect_book()
    if detected_id then
        detected_id = tostring(detected_id)
        -- Avoid reloading every book record from disk on each tick just for
        -- the title; reuse the cached one while the target stays the same.
        if detected_id == self.current_book_id
            and tostring(self.current_book_title or "") ~= "" then
            return detected_id, self.current_book_title, "current_document"
        end
        local book = book_record(self.settings:get("books", {}), detected_id)
        return detected_id,
            type(book) == "table" and book.title or detected_id,
            "current_document"
    end
    return nil, nil, "document_not_weread"
end

function ReadReport:_set_error(err, kind, prefix)
    local message = tostring(err)
    self.last_error = message
    self.last_error_kind = kind or "error"
    self.failure_count = (self.failure_count or 0) + 1
    self.consecutive_failures = (self.consecutive_failures or 0) + 1
    self.state = "error"
    if self.logged_error ~= message then
        log("warn", prefix or "read report error:", message)
        self.logged_error = message
    end
end

function ReadReport:_record_success(result)
    local recovered = self.last_error ~= nil
    self.count = (self.count or 0) + 1
    self.last_time = self.now()
    self.last_error = nil
    self.last_error_kind = nil
    self.logged_error = nil
    self.last_skip = nil
    self.consecutive_failures = 0
    self.state = "active"
    if recovered or self.count == 1 or self.count % 20 == 0 then
        log("info", "read report success:",
            "count=", self.count,
            "has_synckey=", type(result) == "table" and result.synckey ~= nil or false)
    end
end

function ReadReport:_log_skip(reason)
    if self.last_skip ~= reason then
        log("info", "read report skipped:", reason)
        self.last_skip = reason
    end
end

function ReadReport:maybe_start(reason)
    local config = self:_config()
    if not config.enabled then
        self:_log_skip("disabled")
        return false, nil, "disabled"
    end
    if self.suspended then
        self.state = "suspended"
        self:_log_skip("suspended")
        return false, nil, "suspended"
    end
    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        self:_log_skip(source)
        return false, nil, source
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    if self.task then
        return true, title, source
    end
    return self:start(reason), title, source
end

function ReadReport:start(reason)
    if self.task then
        return true
    end
    local book_id, title, source = self:resolve_target()
    if not self:_config().enabled or self.suspended or not book_id then
        return false
    end

    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    self.state = "waiting"
    self.stop_reason = nil
    self.last_skip = nil

    local task
    task = function()
        if self.generation ~= generation or self.task ~= task then
            return
        end
        self:_tick(generation, task)
    end
    self.task = task
    self.scheduler:scheduleIn(self:_interval(), task)
    log("info", "reading time report started:",
        "reason=", reason or "unknown",
        "book_id=", book_id,
        "source=", source)
    return true
end

function ReadReport:stop(reason)
    reason = reason or "unspecified"
    local had_task = self.task ~= nil
    self.generation = self.generation + 1
    if self.task then
        self.scheduler:unschedule(self.task)
        self.task = nil
    end
    if self.job then
        self:_abandon_job(self.job)
    end
    self.state = reason == "suspend" and "suspended"
        or "stopped"
    self.stop_reason = reason
    if had_task then
        log("info", "reading time report stopped:",
            "reason=", reason,
            "success_count=", self.count or 0,
            "failure_count=", self.failure_count or 0)
    end
end

function ReadReport:on_reader_ready()
    self.suspended = false
    return self:maybe_start("reader_ready")
end

function ReadReport:on_suspend()
    self.suspended = true
    self:stop("suspend")
end

function ReadReport:on_resume()
    self.suspended = false
    return self:maybe_start("resume")
end

function ReadReport:on_close_document()
    local config = self:_config()
    if config.report_on_open ~= false or config.mode == "auto" then
        self:stop("document_closed")
        self.current_book_id = nil
        self.current_book_title = nil
        self.current_book_source = nil
        return
    end
    self:maybe_start("document_closed_background")
end

-- ------------------------------------------------------------------
-- Scheduled tick: cheap parent-side checks, then hand the network
-- pipeline to a subprocess (or run it inline as a fallback).
-- ------------------------------------------------------------------

function ReadReport:_schedule_next(generation, task)
    if self.generation == generation and self.task == task then
        self.scheduler:scheduleIn(self:_interval(), task)
    end
end

function ReadReport:_tick(generation, task)
    local ok, err = pcall(function()
        local proceed, book_id = self:_precheck()
        if not proceed then
            self:_schedule_next(generation, task)
            return
        end
        if self.job then
            -- Previous report is still in flight; keep the cadence and let
            -- the poller reschedule once it completes.
            self:_schedule_next(generation, task)
            return
        end
        local allow_renewal = self:_renewal_allowed()
        local spawned, spawn_err = self:_start_job(book_id, allow_renewal, generation, task)
        if spawned then
            return
        end
        if not self.logged_inline_fallback then
            log("warn", "read report subprocess unavailable, reporting inline:",
                tostring(spawn_err))
            self.logged_inline_fallback = true
        end
        local outcome = self:_run_pipeline(book_id, { allow_renewal = allow_renewal })
        self:_apply_outcome(outcome)
        self:_schedule_next(generation, task)
    end)
    if not ok then
        self:_set_error(err, "task", "read report task failed:")
        self:_schedule_next(generation, task)
    end
end

-- Parent-side gate before any network work. Returns true, book_id when a
-- report should be attempted. Must stay cheap: it runs on the UI loop.
function ReadReport:_precheck()
    local config = self:_config()
    if not config.enabled then
        self:stop("disabled")
        return false
    end
    if self.suspended then
        self:stop("suspend")
        return false
    end

    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        return false
    end
    if self.current_book_id and self.current_book_id ~= book_id then
        self:stop("document_changed")
        self:maybe_start("document_changed")
        return false
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source

    if not self.settings:is_cookie_configured() then
        self:_set_error("cookie not configured", "authentication", "read report skipped:")
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        self:_log_skip("offline")
        return false
    end
    return true, book_id
end

function ReadReport:_renewal_allowed()
    return self.now() - (self.last_renew_attempt or 0) >= RENEWAL_COOLDOWN_SECONDS
end

function ReadReport:_auth_fingerprint()
    local cookies = self.settings:get("cookies", {}) or {}
    local keys = {}
    for key in pairs(cookies) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for _i, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. tostring(cookies[key])
    end
    parts[#parts + 1] = "ticket=" .. tostring(self.settings:get("wr_ticket", ""))
    parts[#parts + 1] = "wrpa=" .. tostring(self.settings:get("wr_wrpa", ""))
    return table.concat(parts, ";")
end

-- ------------------------------------------------------------------
-- Subprocess job management (parent side)
-- ------------------------------------------------------------------

function ReadReport:_start_job(book_id, allow_renewal, generation, task)
    local runner = self.subprocess
    if not runner then
        return false, "no subprocess support"
    end
    local pid, read_fd = runner.run(function(_pid, child_write_fd)
        local outcome = self:_child_report(book_id, allow_renewal)
        local ok, encoded = pcall(function()
            return self.client:json_encode(outcome)
        end)
        if not ok or type(encoded) ~= "string" then
            encoded = '{"accepted":false,"error":"failed to serialize report outcome",'
                .. '"error_kind":"job"}'
        end
        runner.write_all(child_write_fd, encoded)
    end)
    if not pid then
        return false, tostring(read_fd)
    end

    local job = {
        pid = pid,
        read_fd = read_fd,
        book_id = book_id,
        started_at = self.now(),
        poll_interval = JOB_POLL_INITIAL_SECONDS,
        auth_fingerprint = self:_auth_fingerprint(),
    }
    job.poll = function()
        self:_poll_job(job, generation, task)
    end
    self.job = job
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
    return true
end

function ReadReport:_poll_job(job, generation, task)
    if self.job ~= job then
        return
    end
    local runner = self.subprocess
    local done = runner.is_done(job.pid)
    local readable = job.read_fd and runner.read_size(job.read_fd)
    if done or (readable and readable > 0) then
        local payload
        if job.read_fd then
            payload = runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.job = nil
        if not done then
            -- Output was read while the child was still exiting; reap it in
            -- the background so it does not linger as a zombie.
            self:_collect_pid(job.pid)
        end
        self:_apply_job_outcome(job, self:_decode_outcome(payload))
        self:_schedule_next(generation, task)
        return
    end
    if self.now() - job.started_at > JOB_TIMEOUT_SECONDS then
        log("warn", "read report job timed out, terminating:", "pid=", job.pid)
        self:_abandon_job(job)
        self:_set_error("report job timed out", "transport", "read report job failed:")
        self:_schedule_next(generation, task)
        return
    end
    job.poll_interval = math.min(job.poll_interval * 2, JOB_POLL_MAX_SECONDS)
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
end

-- Kill a running job and keep reaping until the child is collected, so a
-- stopped or timed-out report can never leave a zombie behind.
function ReadReport:_abandon_job(job)
    job = job or self.job
    if not job then
        return
    end
    if self.job == job then
        self.job = nil
    end
    local runner = self.subprocess
    if job.poll then
        self.scheduler:unschedule(job.poll)
    end
    runner.terminate(job.pid)
    local collect
    collect = function()
        if runner.is_done(job.pid) then
            if job.read_fd then
                runner.read_all(job.read_fd)
                job.read_fd = nil
            end
            return
        end
        if job.read_fd and (runner.read_size(job.read_fd) or 0) ~= 0 then
            -- Drain the pipe so a child blocked on write() can exit.
            runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
    end
    collect()
end

function ReadReport:_collect_pid(pid)
    local runner = self.subprocess
    local collect
    collect = function()
        if not runner.is_done(pid) then
            self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
        end
    end
    self.scheduler:scheduleIn(1, collect)
end

function ReadReport:_decode_outcome(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return self.client:json_decode(payload)
    end)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

-- ------------------------------------------------------------------
-- Outcome application (parent side)
-- ------------------------------------------------------------------

function ReadReport:_apply_job_outcome(job, outcome)
    local book_id = job.book_id
    if type(outcome) == "table" then
        if type(outcome.auth) == "table" then
            if self:_auth_fingerprint() ~= job.auth_fingerprint then
                log("info", "skip renewed auth write-back: parent auth changed during job")
            else
                local ok, err = pcall(function()
                    self.settings:update_auth({
                        cookies = outcome.auth.cookies,
                        wr_ticket = outcome.auth.wr_ticket,
                        wr_wrpa = outcome.auth.wr_wrpa,
                    }, { replace_cookies = true })
                end)
                if not ok then
                    log("warn", "persist renewed auth failed:", tostring(err))
                end
            end
        end
        if type(outcome.book) == "table" then
            local ok, err = pcall(function()
                self:_persist_context(book_id, outcome.book)
            end)
            if not ok then
                log("warn", "persist report context failed:", tostring(err))
            end
        end
    end
    return self:_apply_outcome(outcome)
end

function ReadReport:_apply_outcome(outcome)
    if type(outcome) ~= "table" then
        self:_set_error("report job returned no result", "job", "read report job failed:")
        return false
    end
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if outcome.accepted then
        self:_record_success({ synckey = outcome.has_synckey and true or nil })
        return true
    end
    self:_set_error(outcome.error or "unknown report failure",
        outcome.error_kind or "error",
        outcome.error_prefix)
    return false
end

function ReadReport:_context_snapshot(book)
    local snapshot = { book_id = book.book_id }
    for _i, field in ipairs(CONTEXT_FIELDS) do
        snapshot[field] = book[field]
    end
    return snapshot
end

function ReadReport:_persist_context(book_id, snapshot)
    local books = self.settings:get("books", {})
    local book = book_record(books, book_id) or { book_id = book_id }
    local changed = false
    -- Replace semantics, not merge: a refreshed context may legitimately
    -- clear session fields (notably pclts), and the old wholesale record
    -- overwrite dropped them too. JSON strips nils from the outcome, so a
    -- missing snapshot field means "cleared".
    for _i, field in ipairs(CONTEXT_FIELDS) do
        local value = snapshot[field]
        if book[field] ~= value then
            book[field] = value
            changed = true
        end
    end
    if not changed then
        return
    end
    book.book_id = book.book_id or book_id
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
end

-- ------------------------------------------------------------------
-- Report pipeline (runs in the subprocess, or inline as fallback)
-- ------------------------------------------------------------------

-- Child entry point. Neuters settings persistence inside the fork and
-- captures auth changes (Set-Cookie merges, cookie renewal) so the parent
-- can persist them from the outcome.
function ReadReport:_child_report(book_id, allow_renewal)
    self._no_persist = true
    self.settings.flush = function() end
    local auth_changed = false
    local original_update_auth = self.settings.update_auth
    self.settings.update_auth = function(settings_obj, credentials, options)
        auth_changed = true
        options = options or {}
        options.flush = false
        return original_update_auth(settings_obj, credentials, options)
    end

    local ok, outcome = pcall(function()
        return self:_run_pipeline(book_id, { allow_renewal = allow_renewal })
    end)
    if not ok then
        outcome = {
            accepted = false,
            error = tostring(outcome),
            error_kind = "task",
            error_prefix = "read report task failed:",
        }
    end
    if auth_changed then
        outcome.auth = {
            cookies = self.settings:get("cookies", {}),
            wr_ticket = self.settings:get("wr_ticket", ""),
            wr_wrpa = self.settings:get("wr_wrpa", ""),
        }
    end
    return outcome
end

-- Full report attempt: context, send, refresh-retry, renewal, final retry.
-- Pure with respect to the parent state machine: everything the caller needs
-- is described by the returned outcome table.
function ReadReport:_run_pipeline(book_id, opts)
    opts = opts or {}
    local outcome = { accepted = false, renew_attempted = false }

    local context_ok, book = pcall(function()
        return self:ensure_context(book_id, false)
    end)
    if not context_ok then
        outcome.error = tostring(book)
        outcome.error_kind = "context"
        outcome.error_prefix = "read report context initialization failed:"
        return outcome
    end
    outcome.book = self:_context_snapshot(book)

    local ok, result, http_code = pcall(function()
        return self:_send(book_id, book)
    end)
    local accepted, accepted_body = response_accepted(result, http_code)
    if ok and accepted then
        outcome.accepted = true
        outcome.has_synckey = type(accepted_body) == "table"
            and accepted_body.synckey ~= nil or false
        return outcome
    end
    if not ok then
        outcome.error = tostring(result)
        outcome.error_kind = "transport"
        outcome.error_prefix = "read report request failed:"
        return outcome
    end

    local failure = response_summary(self.client, result, http_code)
    local refresh_ok, refreshed = pcall(function()
        return self:ensure_context(book_id, true)
    end)
    if refresh_ok then
        outcome.book = self:_context_snapshot(refreshed)
        local retry_ok, retry_result, retry_code = pcall(function()
            return self:_send(book_id, refreshed)
        end)
        local retry_accepted, retry_body = response_accepted(retry_result, retry_code)
        if retry_ok and retry_accepted then
            outcome.accepted = true
            outcome.has_synckey = type(retry_body) == "table"
                and retry_body.synckey ~= nil or false
            return outcome
        end
        failure = "initial=" .. failure .. "; refreshed="
            .. (retry_ok and response_summary(self.client, retry_result, retry_code)
                or tostring(retry_result))
    else
        failure = failure .. "; context_refresh=" .. tostring(refreshed)
    end

    if not opts.allow_renewal then
        outcome.error = failure
        outcome.error_kind = "server"
        outcome.error_prefix = "read report server rejected:"
        return outcome
    end
    outcome.renew_attempted = true

    local renew_ok, renew_result = pcall(function()
        return self.client:renew_cookie()
    end)
    if not renew_ok or not WeRead.is_success_response(renew_result) then
        outcome.error = failure .. "; renewal=" .. (renew_ok
            and response_summary(self.client, renew_result)
            or tostring(renew_result))
        outcome.error_kind = "authentication"
        outcome.error_prefix = "read report cookie renewal failed:"
        return outcome
    end

    local final_context_ok, final_book = pcall(function()
        return self:ensure_context(book_id, true)
    end)
    if not final_context_ok then
        outcome.error = failure .. "; final_context=" .. tostring(final_book)
        outcome.error_kind = "context"
        outcome.error_prefix = "read report final context refresh failed:"
        return outcome
    end
    outcome.book = self:_context_snapshot(final_book)
    local final_ok, final_result, final_code = pcall(function()
        return self:_send(book_id, final_book)
    end)
    local final_accepted, final_body = response_accepted(final_result, final_code)
    if final_ok and final_accepted then
        outcome.accepted = true
        outcome.has_synckey = type(final_body) == "table"
            and final_body.synckey ~= nil or false
        return outcome
    end
    outcome.error = failure .. "; final=" .. (final_ok
        and response_summary(self.client, final_result, final_code)
        or tostring(final_result))
    outcome.error_kind = final_ok and "server" or "transport"
    outcome.error_prefix = "read report final retry failed:"
    return outcome
end

-- Inline (blocking) report used when subprocess support is unavailable.
function ReadReport:report_once()
    local proceed, book_id = self:_precheck()
    if not proceed then
        return false
    end
    local outcome = self:_run_pipeline(book_id, {
        allow_renewal = self:_renewal_allowed(),
    })
    return self:_apply_outcome(outcome)
end

-- ------------------------------------------------------------------
-- Report context
-- ------------------------------------------------------------------

function ReadReport:_merge_remote_progress(book_id, book)
    local ok, result = pcall(function()
        return self.client:get_progress(book_id)
    end)
    if not ok or type(result) ~= "table" then
        return
    end
    local remote = type(result.book) == "table" and result.book or result
    book.progress = tonumber(remote.progress) or tonumber(book.progress) or 0
    book.chapter_uid = remote.chapterUid or remote.chapterId or remote.chapter_uid or book.chapter_uid
    book.chapter_idx = tonumber(remote.chapterIdx or remote.chapterIndex or remote.chapter_idx)
        or tonumber(book.chapter_idx)
    book.chapter_offset = tonumber(remote.chapterOffset or remote.chapterPos or remote.offset)
        or tonumber(book.chapter_offset) or 0
    book.summary = remote.summary or book.summary or ""
end

-- Build (and refresh when stale) the reader context on the given book
-- record. Performs network I/O; never persists settings.
function ReadReport:_build_context(book_id, force, book)
    book.book_id = book.book_id or book.bookId or book_id
    book.reader_url = WeRead.reader_url(book_id)

    -- BookStore never persists the chapter list, so a freshly loaded record
    -- has no chapters. Restore them from the on-disk catalog cache first;
    -- otherwise the TTL check below can never pass and every report would
    -- refetch the whole reader page.
    if type(book.chapters) ~= "table" or #book.chapters == 0 then
        Content.load_catalog_cache(self.client, self.settings, book)
    end

    local age = self.now() - (tonumber(book.read_context_updated_at) or 0)
    local ready = tostring(book.psvts or "") ~= ""
        and book.chapter_uid ~= nil
        and type(book.chapters) == "table" and #book.chapters > 0
    if not force and ready and age < CONTEXT_TTL_SECONDS then
        return book
    end

    Content.ensure_reader_state(self.client, book)
    if force or type(book.chapters) ~= "table" or #book.chapters == 0 then
        local chapters = Content.fetch_catalog(self.client, book)
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters)
        if not cache_ok then
            log("warn", "save chapter catalog cache failed:", tostring(cache_err))
        end
    end
    self:_merge_remote_progress(book_id, book)

    local selected
    for _i, chapter in ipairs(book.chapters or {}) do
        if tostring(chapter.chapterUid or "") == tostring(book.chapter_uid or "") then
            selected = chapter
            break
        end
    end
    selected = selected or Content.first_readable_chapter(book.chapters)
    if not selected then
        error("no readable chapter found for report context")
    end
    book.chapter_uid = selected.chapterUid or book.chapter_uid
    book.chapter_idx = tonumber(selected.chapterIdx) or tonumber(book.chapter_idx) or 0
    book.app_id = book.app_id or WeRead.web_app_id()
    book.read_context_updated_at = self.now()
    if tostring(book.psvts or "") == "" or book.chapter_uid == nil then
        error("reader context is incomplete")
    end
    return book
end

function ReadReport:ensure_context(book_id, force)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("missing book id")
    end
    if not self.settings:is_cookie_configured() then
        error("cookie not configured")
    end

    local books = self.settings:get("books", {})
    local book = book_record(books, book_id) or {
        book_id = book_id,
        title = self.current_book_title or book_id,
    }
    self:_build_context(book_id, force, book)
    if self._no_persist then
        -- Forked child: the parent persists the context from the outcome.
        return book
    end
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return book
end

function ReadReport:build_payload(book_id, elapsed_seconds, book)
    book = book or self:ensure_context(book_id, false)
    return WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid,
        chapter_idx = tonumber(book.chapter_idx) or 0,
        chapter_offset = tonumber(book.chapter_offset) or 0,
        progress = tonumber(book.progress) or 0,
        summary = book.summary or "",
        elapsed_seconds = elapsed_seconds,
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
    }
end

function ReadReport:_send(book_id, book)
    local payload = self:build_payload(book_id, self:_interval(), book)
    return self.client:report_read(payload, book.reader_url or WeRead.reader_url(book_id))
end

return ReadReport
