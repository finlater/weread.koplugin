local PositionMapper = require("weread.lib.position_mapper")

local logger = require("weread.lib.logger").scoped("ProgressSync")
local PluginUtil = require("weread.lib.plugin_util")
local ok_time, time = pcall(require, "ui/time")
if not ok_time then
    time = { now = function() return 0 end }
end
local perf = PluginUtil.perf or function() end

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
if not ok_ffiutil then
    ffiutil = nil
end

local ProgressSync = {}
ProgressSync.__index = ProgressSync

local OPEN_DELAY_SECONDS = 0.6
local RESUME_RECHECK_SECONDS = 5 * 60
local PULL_RETRY_DELAY_SECONDS = 15
local PULL_MAX_RETRIES = 3
local BUSY_RETRY_SECONDS = 2
local BUSY_RETRY_LIMIT = 10
local SAME_THRESHOLD_PERCENT = 2
local SOURCE_CONFLICT_THRESHOLD_PERCENT = 2
local JOB_POLL_INITIAL_SECONDS = 0.25
local JOB_POLL_MAX_SECONDS = 2
local JOB_TIMEOUT_SECONDS = 180

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function make_subprocess_runner()
    if not ffiutil or type(ffiutil.runInSubProcess) ~= "function" then
        return nil
    end
    return {
        run = function(child_func)
            return ffiutil.runInSubProcess(child_func, true)
        end,
        write_all = function(fd, data)
            return ffiutil.writeToFD(fd, data, true)
        end,
        is_done = function(pid)
            return ffiutil.isSubProcessDone(pid)
        end,
        terminate = function(pid)
            ffiutil.terminateSubProcess(pid)
        end,
        read_size = function(fd)
            return ffiutil.getNonBlockingReadSize(fd)
        end,
        read_all = function(fd)
            return ffiutil.readAllFromFD(fd)
        end,
    }
end

local function is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

function ProgressSync:new(options)
    options = options or {}
    assert(options.settings, "progress sync settings are required")
    assert(options.client, "progress sync client is required")
    assert(options.scheduler, "progress sync scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")
    assert(type(options.get_book) == "function", "get_book callback is required")
    assert(type(options.get_chapters) == "function", "get_chapters callback is required")
    assert(type(options.get_file_context) == "function", "get_file_context callback is required")
    assert(type(options.run_online) == "function", "run_online callback is required")
    assert(type(options.upload_position) == "function", "upload_position callback is required")
    assert(type(options.goto_fraction) == "function", "goto_fraction callback is required")
    assert(type(options.open_chapter) == "function", "open_chapter callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        get_document = options.get_document,
        get_footer = options.get_footer,
        detect_book = options.detect_book,
        get_book = options.get_book,
        get_chapters = options.get_chapters,
        refresh_catalog = options.refresh_catalog,
        get_file_context = options.get_file_context,
        run_online = options.run_online,
        upload_position = options.upload_position,
        build_upload_outcome = options.build_upload_outcome,
        apply_upload_outcome = options.apply_upload_outcome,
        goto_fraction = options.goto_fraction,
        open_chapter = options.open_chapter,
        is_online = options.is_online or function() return true end,
        on_choice = options.on_choice or function(context)
            context.keep_local()
        end,
        notify = options.notify or function() end,
        now = options.now or os.time,
        subprocess = options.subprocess == nil and make_subprocess_runner()
            or options.subprocess,
        state = "idle",
        generation = 0,
        pull_retry_token = 0,
        dirty = false,
        verified = false,
    }
    return setmetatable(object, self)
end

function ProgressSync:_config()
    return self.settings:get("sync", {})
end

function ProgressSync:_decode_job_payload(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return self.client:json_decode(payload)
    end)
    return ok and type(decoded) == "table" and decoded or nil
end

function ProgressSync:_start_job(kind, worker, complete)
    local runner = self.subprocess
    if not runner then return false, "subprocess_unavailable" end
    if self.job then return false, "progress_job_busy" end

    local pid, read_fd = runner.run(function(_pid, child_write_fd)
        local ok, outcome = pcall(worker)
        if not ok then
            outcome = { ok = false, error = tostring(outcome) }
        elseif type(outcome) ~= "table" then
            outcome = { ok = false, error = "invalid progress job outcome" }
        else
            outcome.ok = outcome.ok ~= false
        end
        local encoded_ok, encoded = pcall(function()
            return self.client:json_encode(outcome)
        end)
        if not encoded_ok or type(encoded) ~= "string" then
            encoded = '{"ok":false,"error":"failed to serialize progress job"}'
        end
        runner.write_all(child_write_fd, encoded)
    end)
    if not pid then return false, tostring(read_fd) end

    local job = {
        kind = kind,
        pid = pid,
        read_fd = read_fd,
        started_at = self.now(),
        poll_interval = JOB_POLL_INITIAL_SECONDS,
        complete = complete,
    }
    job.poll = function()
        self:_poll_job(job)
    end
    self.job = job
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
    return true
end

function ProgressSync:_finish_job(job, outcome)
    if self.job ~= job then return end
    self.job = nil
    local ok, err = pcall(job.complete, outcome)
    if not ok then
        log("warn", "progress job completion failed:",
            "kind=", tostring(job.kind), "error=", tostring(err))
    end
end

function ProgressSync:_collect_pid(pid)
    local runner = self.subprocess
    local collect
    collect = function()
        if not runner.is_done(pid) then
            self.scheduler:scheduleIn(1, collect)
        end
    end
    self.scheduler:scheduleIn(1, collect)
end

function ProgressSync:_poll_job(job)
    if self.job ~= job then return end
    local runner = self.subprocess
    local done = runner.is_done(job.pid)
    local readable = job.read_fd and runner.read_size(job.read_fd)
    if done or (readable and readable > 0) then
        local payload
        if job.read_fd then
            payload = runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        if not done then
            self:_collect_pid(job.pid)
        end
        self:_finish_job(job, self:_decode_job_payload(payload))
        return
    end
    if self.now() - job.started_at > JOB_TIMEOUT_SECONDS then
        runner.terminate(job.pid)
        self:_finish_job(job, {
            ok = false,
            error = tostring(job.kind) .. " timed out",
        })
        return
    end
    job.poll_interval = math.min(job.poll_interval * 2, JOB_POLL_MAX_SECONDS)
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
end

function ProgressSync:_child_fetch_remote(book_id, chapters)
    local auth_changed = false
    local original_flush = self.settings.flush
    local original_update_auth = self.settings.update_auth
    self.settings.flush = function() end
    if type(original_update_auth) == "function" then
        self.settings.update_auth = function(settings_obj, credentials, options)
            auth_changed = true
            options = options or {}
            options.flush = false
            return original_update_auth(settings_obj, credentials, options)
        end
    end

    local remote, pull_error = self:_fetch_remote(book_id, chapters)
    local outcome = {
        remote = remote,
        pull_error = pull_error and tostring(pull_error) or nil,
    }
    if auth_changed then
        outcome.auth = {
            cookies = self.settings:get("cookies", {}),
            wr_ticket = self.settings:get("wr_ticket", ""),
            wr_wrpa = self.settings:get("wr_wrpa", ""),
        }
    end
    self.settings.flush = original_flush
    self.settings.update_auth = original_update_auth
    return outcome
end

function ProgressSync:_apply_job_auth(outcome)
    if type(outcome) ~= "table" or type(outcome.auth) ~= "table" then
        return
    end
    local ok, err = pcall(function()
        self.settings:update_auth({
            cookies = outcome.auth.cookies,
            wr_ticket = outcome.auth.wr_ticket,
            wr_wrpa = outcome.auth.wr_wrpa,
        }, { replace_cookies = true })
    end)
    if not ok then
        log("warn", "persist progress job auth failed:", tostring(err))
    end
end

function ProgressSync:_persist(book_id, patch)
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then return false end

    if type(self.settings.update_book) == "function" then
        local started = time.now()
        local ok = self.settings:update_book(book_id, patch)
        perf("progress.update_book", started, "book=", book_id)
        return ok
    end

    -- Compatibility fallback for older host/test settings objects.
    local books = self.settings:get("books", {})
    local book = books[book_id] or { book_id = book_id }
    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = copy(value)
        end
    end
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return true
end

function ProgressSync:_local_fraction()
    local document = self.get_document()
    if not document then return nil end

    local footer = self.get_footer and self.get_footer()
    local footer_value = footer and tonumber(footer.percent_finished)
    if footer_value then
        if footer_value > 1 then footer_value = footer_value / 100 end
        return math.max(0, math.min(1, footer_value))
    end

    local page
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if not page and type(document.getPageNumber) == "function" then
        local ok, value = pcall(document.getPageNumber, document)
        if ok then page = tonumber(value) end
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = tonumber(value) end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    local current_pos = tonumber(document.current_pos)
    local doc_height = tonumber(document.info and document.info.doc_height)
        or tonumber(document.doc_height)
    if current_pos and doc_height and doc_height > 0 then
        return math.max(0, math.min(1, current_pos / doc_height))
    end
    return nil
end

function ProgressSync:capture_local()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then
        return nil, "document_not_weread"
    end
    book_id = tostring(book_id)
    local document = self.get_document()
    local path = document_path(document)
    if not document or not path then return nil, "document_unavailable" end
    local cached = self.document_context
    local book
    local chapters
    local current_chapter
    local is_full_book
    if cached and cached.book_id == book_id and cached.path == path then
        book = cached.book
        chapters = cached.chapters
        current_chapter = cached.current_chapter
        is_full_book = cached.is_full_book
    else
        book = self.get_book(book_id)
        if type(book) ~= "table" then return nil, "book_not_found" end
        chapters = self.get_chapters(book)
        if type(chapters) ~= "table" or #chapters == 0 then
            return nil, "catalog_unavailable"
        end
        local _index
        _index, current_chapter, is_full_book =
            self.get_file_context(book, path)
        self.document_context = {
            book_id = book_id,
            book = book,
            chapters = chapters,
            current_chapter = current_chapter,
            is_full_book = is_full_book == true,
            path = path,
        }
    end
    local fraction = self:_local_fraction()
    if fraction == nil then return nil, "position_unavailable" end
    local position, reason = PositionMapper.local_to_remote(
        chapters,
        fraction,
        {
            is_full_book = is_full_book == true,
            current_chapter_uid = current_chapter
                and (current_chapter.chapterUid or current_chapter.chapterId),
            summary = book.summary or book.title or "",
        }
    )
    if not position then return nil, reason end
    position.book_id = book_id
    position.captured_at = self.now()
    position.current_chapter_uid = current_chapter
        and (current_chapter.chapterUid or current_chapter.chapterId)
    position.is_full_book = is_full_book == true
    return position, nil, {
        book_id = book_id,
        book = book,
        chapters = chapters,
        current_chapter = current_chapter,
        is_full_book = is_full_book == true,
        path = path,
    }
end

function ProgressSync:_mark_verified(book_id, reason, local_position, remote)
    self.current_book_id = tostring(book_id)
    self.verified = true
    self.verified_at = self.now()
    self.verified_reason = reason
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.state = "verified"
    self:_persist(book_id, {
        verified_at = self.verified_at,
        verified_source = reason,
        last_local_position = local_position,
        last_remote_position = remote,
        last_sync_error = false,
    })
    log("info", "verified:",
        "book=", tostring(book_id),
        "reason=", tostring(reason),
        "local=", tostring(local_position and local_position.percent or "-"),
        "remote=", tostring(remote and remote.percent or "-"))
end

function ProgressSync:_clear_verified(reason)
    self.verified = false
    self.verified_at = nil
    self.verified_reason = reason
    if self.current_book_id then
        self:_persist(self.current_book_id, {
            verified_at = false,
            verified_source = reason or "cleared",
        })
    end
end

function ProgressSync:_fetch_remote(book_id, chapters)
    local gateway
    local web
    local gateway_error
    local web_error
    if self.settings:is_api_configured() then
        local ok, result = pcall(self.client.get_progress, self.client, book_id)
        if ok then
            gateway, gateway_error = PositionMapper.normalize_remote(
                result, book_id, "gateway", chapters)
        else
            gateway_error = tostring(result)
        end
    end
    if self.settings:is_cookie_configured() then
        local ok, result = pcall(
            self.client.get_web_progress, self.client, book_id)
        if ok then
            web, web_error = PositionMapper.normalize_remote(
                result, book_id, "web", chapters)
        else
            web_error = tostring(result)
        end
    end
    local selected = PositionMapper.choose_remote(
        web,
        gateway,
        SOURCE_CONFLICT_THRESHOLD_PERCENT
    )
    if not selected then
        return nil, gateway_error or web_error or "remote_unavailable"
    end
    return selected
end

function ProgressSync:_apply_remote(remote, context, options)
    options = options or {}
    local target, reason = PositionMapper.remote_to_local(
        context.chapters,
        remote,
        {
            is_full_book = context.is_full_book,
            current_chapter_uid = context.current_chapter
                and (context.current_chapter.chapterUid
                    or context.current_chapter.chapterId),
        }
    )
    if not target then return false, reason end

    if target.requires_chapter_open then
        self:_clear_verified("switching_chapter")
        self.dirty = false
        self.pending_jump = {
            book_id = context.book_id,
            chapter_uid = target.chapter
                and (target.chapter.chapterUid or target.chapter.chapterId),
            fraction = target.fraction,
            remote = copy(remote),
            notify = options.manual == true,
        }
        self.state = "switching_chapter"
        local open_ok, opened, open_error = pcall(
            self.open_chapter, context.book, target.chapter)
        if not open_ok or opened == false then
            self.pending_jump = nil
            self.state = "error"
            return false, (open_ok and open_error or opened)
                or "target_chapter_unavailable"
        end
        return true
    end
    local ok, err = self.goto_fraction(target.fraction)
    if not ok then return false, err or "jump_failed" end
    self.dirty = false
    self:_mark_verified(
        context.book_id,
        "remote_selected",
        self.local_position,
        remote
    )
    if options.manual then
        self.notify("remote_applied", { position = remote })
    end
    self.scheduler:scheduleIn(0.15, function()
        local position = self:capture_local()
        if position then
            self.local_position = position
            self.dirty = false
            self:_persist(context.book_id, {
                last_local_position = position,
            })
        end
    end)
    return true
end

function ProgressSync:_queue_snapshot(position, reason)
    if type(position) ~= "table" then return false end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    if book_id == "" then return false end
    self:_persist(book_id, {
        pending_upload_position = position,
        pending_upload_reason = reason or "unspecified",
    })
    self.state = "queued"
    return true
end

function ProgressSync:_upload_snapshot(position, reason, show_result, on_complete)
    if type(position) ~= "table" then return false end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    if book_id == "" or self.uploading then return false end
    self:_queue_snapshot(position, reason)
    if not self.is_online() then
        self.state = "offline"
        if show_result then self.notify("offline", {}) end
        return false
    end
    self.uploading = true
    self.state = "uploading"
    local upload_generation = self.generation
    local attempts = 0
    local attempt
    attempt = function()
        attempts = attempts + 1
        local function finish(ok, accepted, outcome)
            if ok and not accepted and type(outcome) == "table"
                and outcome.error_kind == "busy"
                and attempts < BUSY_RETRY_LIMIT then
                self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, attempt)
                return
            end
            self.uploading = false
            local applies_to_current = upload_generation == self.generation
                and tostring(self.current_book_id or "") == book_id
            if ok and accepted then
                if applies_to_current then
                    self.state = "verified"
                    self.dirty = false
                    self.last_uploaded_position = copy(position)
                end
                self:_persist(book_id, {
                    last_local_position = position,
                    last_uploaded_position = position,
                    last_upload_at = self.now(),
                    pending_upload_position = false,
                    pending_upload_reason = false,
                    last_sync_error = false,
                })
                log("info", "upload accepted:",
                    "book=", book_id,
                    "percent=", tostring(position.percent),
                    "reason=", tostring(reason))
                if show_result then
                    self.notify("upload_success", { position = position })
                end
                if applies_to_current and on_complete then
                    on_complete(true, outcome)
                end
                if applies_to_current and self.resume_recheck_pending then
                    self:_run_resume_recheck()
                end
                return
            end
            local error_message = ok and type(outcome) == "table"
                and outcome.error or outcome
            if applies_to_current then
                self.state = "error"
            end
            self:_persist(book_id, {
                last_sync_error = tostring(error_message or "upload_failed"),
            })
            log("warn", "upload failed:", tostring(error_message))
            if show_result then
                self.notify("upload_failed", {
                    error = tostring(error_message or "upload_failed"),
                })
            end
            if applies_to_current and on_complete then
                on_complete(false, outcome)
            end
        end

        if self.subprocess and type(self.build_upload_outcome) == "function" then
            local started, start_error = self:_start_job("progress_upload", function()
                return {
                    upload = self.build_upload_outcome(
                        book_id, copy(position), 0),
                }
            end, function(job_outcome)
                if type(job_outcome) ~= "table" or job_outcome.ok == false then
                    finish(false, nil, job_outcome and job_outcome.error)
                    return
                end
                local upload_outcome = job_outcome.upload
                if type(self.apply_upload_outcome) == "function" then
                    local apply_started = time.now()
                    self.apply_upload_outcome(book_id, upload_outcome)
                    perf("upload.parent_apply", apply_started, "book=", book_id)
                end
                finish(true,
                    type(upload_outcome) == "table"
                        and upload_outcome.accepted == true,
                    upload_outcome)
            end)
            if not started then
                if start_error == "progress_job_busy"
                    and attempts < BUSY_RETRY_LIMIT then
                    self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, attempt)
                    return
                end
                finish(false, nil, start_error)
            end
            return
        end

        local ok, accepted, outcome = pcall(
            self.upload_position,
            book_id,
            copy(position),
            0
        )
        finish(ok, accepted, outcome)
    end
    local started
    if self.subprocess and type(self.build_upload_outcome) == "function" then
        self.scheduler:scheduleIn(0.1, attempt)
        started = true
    else
        started = self.run_online("progress_upload", attempt)
    end
    if not started then
        self.uploading = false
        self.state = "offline"
    end
    return started == true
end

function ProgressSync:_keep_local(local_position, remote, options)
    options = options or {}
    self.dirty = not PositionMapper.same_position(local_position, remote)
    self:_mark_verified(
        local_position.book_id,
        "local_selected",
        local_position,
        remote
    )
    if options.upload_now then
        self:_upload_snapshot(local_position, options.reason, true)
    elseif options.manual then
        self.notify("local_kept", { position = local_position })
    end
end

function ProgressSync:_resolve(local_position, remote, context, options)
    options = options or {}
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    local comparison = PositionMapper.compare(
        local_position,
        remote,
        SAME_THRESHOLD_PERCENT
    )

    if comparison == "same" and not remote.conflict then
        self.dirty = false
        self:_mark_verified(
            context.book_id,
            "positions_match",
            local_position,
            remote
        )
        if options.manual then
            self.notify("already_synced", { position = local_position })
        end
        return
    end

    local ask = self:_config().ask_on_conflict ~= false
    if remote.conflict or ask then
        self.state = "awaiting_choice"
        local choice_generation = self.generation
        local function choice_is_current()
            return choice_generation == self.generation
                and tostring(self.detect_book() or "") == context.book_id
        end
        self.on_choice({
            book_title = context.book.title or context.book_id,
            local_position = copy(local_position),
            remote_position = copy(remote),
            source_conflict = remote.conflict == true,
            use_remote = function()
                if not choice_is_current() then return end
                local ok, reason = self:_apply_remote(
                    remote, context, { manual = options.manual })
                if not ok then
                    self.state = "error"
                    self.notify("jump_failed", { error = reason })
                end
            end,
            keep_local = function()
                if not choice_is_current() then return end
                self:_keep_local(local_position, remote, {
                    manual = options.manual,
                    upload_now = true,
                    reason = "explicit_local_choice",
                })
            end,
        })
        return
    end

    if comparison == "remote_ahead" then
        local ok, reason = self:_apply_remote(
            remote, context, { manual = options.manual })
        if not ok then
            self.state = "error"
            self.notify("jump_failed", { error = reason })
        end
    else
        self:_keep_local(local_position, remote, {
            manual = options.manual,
            upload_now = options.manual == true,
            reason = "manual_sync",
        })
    end
end

function ProgressSync:_complete_pull(generation, local_position, context,
        options, remote, pull_error)
    if generation == self.generation then
        self.pulling = false
    end
    if generation ~= self.generation
        or tostring(self.detect_book() or "") ~= context.book_id then
        return
    end
    if not remote then
        if options.resume_recheck then
            self.resume_recheck_pending = true
            self.state = "waiting_for_network"
        else
            self.state = "error"
        end
        self:_persist(context.book_id, {
            last_pull_at = self.now(),
            last_sync_error = tostring(pull_error),
        })
        if options.manual then
            self.notify("pull_failed", { error = tostring(pull_error) })
        elseif not options.resume_recheck then
            self:_schedule_pull_retry(options, options.retry_token or self.pull_retry_token)
        end
        return
    end
    self:_persist(context.book_id, {
        last_remote_position = remote,
        last_local_position = local_position,
        last_pull_at = self.now(),
        last_sync_error = false,
    })
    self:_resolve(local_position, remote, context, options)
end

function ProgressSync:_schedule_pull_retry(options, retry_token)
    local attempt = (options.retry or 0) + 1
    if attempt > PULL_MAX_RETRIES then
        log("warn", "automatic pull retries exhausted:",
            "book=", tostring(self.current_book_id))
        return false
    end
    local generation = self.generation
    self.scheduler:scheduleIn(PULL_RETRY_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        if retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling then return end
        if self.state == "awaiting_choice" then return end
        self:_pull{
            manual = false,
            retry = attempt,
            retry_token = retry_token,
        }
    end)
    log("info", "automatic pull retry scheduled:",
        "book=", tostring(self.current_book_id),
        "attempt=", tostring(attempt),
        "delay=", tostring(PULL_RETRY_DELAY_SECONDS))
    return true
end

function ProgressSync:_pull(options)
    options = options or {}
    if self.pulling then return false end
    local retry_token = options.retry_token
    if retry_token == nil then
        self.pull_retry_token = self.pull_retry_token + 1
        retry_token = self.pull_retry_token
    elseif retry_token ~= self.pull_retry_token then
        return false
    end
    local local_position, reason, context = self:capture_local()
    if not local_position then
        if not (options.manual == true
            and reason == "catalog_unavailable"
            and type(self.refresh_catalog) == "function") then
            if options.manual then
                self.notify("local_unavailable", { error = reason })
            end
            return false
        end
    end
    if not self.settings:is_api_configured()
        and not self.settings:is_cookie_configured() then
        if options.manual then self.notify("authentication_required", {}) end
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
        return false
    end

    local generation = self.generation
    self.pulling = true
    self.state = "pulling"

    local fetch_attempts = 0
    local start_fetch
    start_fetch = function()
        fetch_attempts = fetch_attempts + 1
        if self.subprocess then
            local started, start_error = self:_start_job("progress_pull", function()
                return self:_child_fetch_remote(
                    context.book_id, context.chapters)
            end, function(outcome)
                if type(outcome) ~= "table" or outcome.ok == false then
                    self:_complete_pull(generation, local_position, context,
                        options, nil, outcome and outcome.error
                            or "progress pull job failed")
                    return
                end
                self:_apply_job_auth(outcome)
                self:_complete_pull(generation, local_position, context,
                    options, outcome.remote, outcome.pull_error)
            end)
            if not started then
                if start_error == "progress_job_busy"
                    and fetch_attempts < BUSY_RETRY_LIMIT then
                    self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, start_fetch)
                    return true
                end
                self:_complete_pull(generation, local_position, context,
                    options, nil, start_error)
            end
            return started
        end

        local remote, pull_error = self:_fetch_remote(
            context.book_id, context.chapters)
        self:_complete_pull(generation, local_position, context,
            options, remote, pull_error)
        return true
    end

    local function prepare()
        if not local_position then
            local book_id = tostring(self.detect_book() or "")
            local refresh_ok, refreshed, refresh_error = pcall(
                self.refresh_catalog, book_id)
            if not refresh_ok then
                refresh_error = refreshed
                refreshed = nil
            end
            self.document_context = nil
            local_position, reason, context = self:capture_local()
            if not local_position then
                self.pulling = false
                self.state = "error"
                self.notify("local_unavailable", {
                    error = refresh_error or reason,
                })
                return false
            end
            if type(refreshed) ~= "table" or #refreshed == 0 then
                log("warn", "catalog refresh returned no chapters for:", book_id)
            end
        end
        return start_fetch()
    end

    local started
    if self.subprocess and local_position then
        started = start_fetch()
    else
        started = self.run_online("progress_pull", prepare, {
            silent_offline = options.manual ~= true,
        })
    end
    if not started then
        self.pulling = false
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
    end
    return started == true
end

function ProgressSync:_apply_pending_jump(book_id)
    local pending = self.pending_jump
    if not pending or tostring(pending.book_id) ~= tostring(book_id) then
        return false
    end
    local local_position, _reason, context = self:capture_local()
    if not context or not context.current_chapter
        or tostring(context.current_chapter.chapterUid or context.current_chapter.chapterId)
            ~= tostring(pending.chapter_uid) then
        return false
    end
    self.pending_jump = nil
    local ok, err = self.goto_fraction(pending.fraction)
    if not ok then
        self.state = "error"
        self.notify("jump_failed", { error = err })
        return true
    end
    self.dirty = false
    self:_mark_verified(
        book_id,
        "remote_chapter_applied",
        local_position,
        pending.remote
    )
    if pending.notify then
        self.notify("remote_applied", { position = pending.remote })
    end
    self.scheduler:scheduleIn(0.15, function()
        local position = self:capture_local()
        if position then
            self.local_position = position
            self:_persist(book_id, { last_local_position = position })
        end
    end)
    return true
end

function ProgressSync:cancel_pending_jump(reason)
    if not self.pending_jump then return false end
    self.pending_jump = nil
    self.dirty = false
    self.state = "unverified"
    self:_clear_verified(tostring(reason or "pending_jump_cancelled"))
    return true
end

function ProgressSync:on_reader_ready()
    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = nil
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.verified = false
    self.dirty = false
    self.pulling = false
    self.resume_recheck_pending = false
    self.state = "waiting"

    self.scheduler:scheduleIn(OPEN_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        local book_id = self.detect_book()
        if not book_id or is_mp_book(book_id) then
            self.state = "unsupported"
            return
        end
        book_id = tostring(book_id)
        self.current_book_id = book_id
        if self:_apply_pending_jump(book_id) then return end

        local local_position, reason = self:capture_local()
        if not local_position then
            self.state = "unsafe"
            log("warn", "local position unavailable:", tostring(reason))
            return
        end
        self.local_position = local_position
        self:_persist(book_id, { last_local_position = local_position })
        if self:_config().pull_on_open ~= true then
            self.state = "unverified"
            return
        end
        self:_pull({ manual = false })
    end)
end

function ProgressSync:on_page_update()
    if not self.current_book_id then return end
    local position = self:capture_local()
    if not position then return end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
end

function ProgressSync:on_close_document()
    local position = self:capture_local() or self.local_position
    if position and self.verified
        and self:_config().upload_on_close == true then
        if not self.local_position
            or not PositionMapper.same_position(position, self.local_position) then
            self.dirty = true
        end
        if self.dirty then
            self:_upload_snapshot(position, "document_close", false)
        end
    end
    self.generation = self.generation + 1
    self.current_book_id = nil
    self.verified = false
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.pulling = false
    self.resume_recheck_pending = false
end

function ProgressSync:on_suspend()
    self.suspended_at = self.now()
    local position = self:capture_local() or self.local_position
    if position and self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    if position and self.verified and self.dirty
        and self:_config().upload_on_close == true then
        -- Suspend handlers must be local-only. The immutable snapshot is
        -- flushed after KOReader broadcasts NetworkConnected.
        self:_queue_snapshot(position, "suspend")
    end
end

function ProgressSync:on_resume()
    local slept = self.suspended_at and self.now() - self.suspended_at or 0
    self.suspended_at = nil
    if slept >= RESUME_RECHECK_SECONDS
        and self:_config().pull_on_open == true then
        self.resume_recheck_pending = true
        self:_clear_verified("resume_recheck")
        self.state = "waiting_for_network"
    end
    if self.is_online() then
        self.scheduler:scheduleIn(0.1, function()
            self:on_network_connected()
        end)
    end
end

function ProgressSync:_pending_upload()
    local book_id = tostring(self.current_book_id or "")
    if book_id == "" then return nil end
    local book = self.settings:get("books", {})[book_id]
    if type(book) ~= "table"
        or type(book.pending_upload_position) ~= "table" then
        return nil
    end
    return copy(book.pending_upload_position),
        book.pending_upload_reason or "queued"
end

function ProgressSync:_run_resume_recheck()
    if not self.resume_recheck_pending then return false end
    self.resume_recheck_pending = false
    local started = self:_pull({ manual = false, resume_recheck = true })
    if not started then
        self.resume_recheck_pending = true
    end
    return started
end

function ProgressSync:on_network_connected()
    if not self.current_book_id or not self.is_online() then
        return false
    end
    local pending, reason = self:_pending_upload()
    if pending and not self.uploading then
        return self:_upload_snapshot(pending, reason, false, function(success)
            if success then
                self:_run_resume_recheck()
            end
        end)
    end
    if not self.uploading then
        return self:_run_resume_recheck()
    end
    return false
end

function ProgressSync:sync_now()
    return self:_pull({ manual = true })
end

function ProgressSync:position_for_report(book_id)
    local current = self.detect_book()
    if not current or tostring(current) ~= tostring(book_id)
        or is_mp_book(book_id) then
        return nil, nil, false
    end
    if not self.verified then
        return nil, "progress_unverified", true
    end
    local position, reason = self:capture_local()
    if not position then
        return nil, reason or "position_unavailable", true
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
    return position, nil, true
end

function ProgressSync:status()
    return {
        state = self.state,
        book_id = self.current_book_id,
        verified = self.verified,
        dirty = self.dirty,
        pulling = self.pulling == true,
        uploading = self.uploading == true,
        local_position = copy(self.local_position),
        remote_position = copy(self.remote_position),
    }
end

return ProgressSync
