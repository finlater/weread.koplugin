-- One-at-a-time subprocess runner for silent prefetch work.
--
-- The child communicates through atomic progress/result files. This avoids a
-- pipe filling while KOReader is suspended and lets the parent remain the only
-- process that mutates UI state and persistent LuaSettings.
local FFIUtil = require("ffi/util")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local ok_json, Json = pcall(require, "json")
if not ok_json then Json = require("rapidjson") end

local Worker = {}
Worker.__index = Worker

local DEFAULT_MIN_AVAILABLE_KB = 128 * 1024
local DEFAULT_TIMEOUT_SECONDS = 180
local DEFAULT_CANCEL_GRACE_SECONDS = 5
local DEFAULT_POLL_INTERVAL = 0.25
local MEMORY_COOLDOWN_SECONDS = 30

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function atomic_write(path, data)
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    file:close()
    if not ok then
        os.remove(temporary)
        return nil, write_err
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then os.remove(temporary) end
    return renamed, rename_err
end

local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path)
end

local function available_memory_kb(raw)
    local values = {}
    for key, value in tostring(raw or ""):gmatch("([%a_]+):%s*(%d+)%s*kB") do
        values[key] = tonumber(value)
    end
    if values.MemAvailable then return values.MemAvailable end
    if values.MemFree then
        return values.MemFree + (values.Buffers or 0) + (values.Cached or 0)
    end
end

local function memory_error(value)
    local text = tostring(value or ""):lower()
    return text:find("cannot allocate memory", 1, true)
        or text:find("not enough memory", 1, true)
        or text:find("out of memory", 1, true)
        or text:find("enomem", 1, true)
end

local function default_runner()
    if type(FFIUtil.runInSubProcess) ~= "function"
        or type(FFIUtil.isSubProcessDone) ~= "function" then return nil end
    if type(FFIUtil.isAndroid) == "function" and FFIUtil.isAndroid() then return nil end
    return {
        run = function(callback)
            return FFIUtil.runInSubProcess(callback, false, false)
        end,
        is_done = function(pid)
            return FFIUtil.isSubProcessDone(pid, false)
        end,
        terminate = function(pid)
            return FFIUtil.terminateSubProcess(pid)
        end,
    }
end

function Worker:new(options)
    options = options or {}
    local obj = setmetatable({
        scheduler = options.scheduler or UIManager,
        runner = options.runner or default_runner(),
        temp_dir = assert(options.temp_dir, "worker temp_dir required"),
        min_available_kb = tonumber(options.min_available_kb)
            or DEFAULT_MIN_AVAILABLE_KB,
        timeout = tonumber(options.timeout) or DEFAULT_TIMEOUT_SECONDS,
        cancel_grace = tonumber(options.cancel_grace)
            or DEFAULT_CANCEL_GRACE_SECONDS,
        poll_interval = tonumber(options.poll_interval)
            or DEFAULT_POLL_INTERVAL,
        now = options.now or os.time,
        read_memory = options.read_memory or function()
            return read_file("/proc/meminfo")
        end,
        sequence = 0,
    }, self)
    if not ensure_dir(obj.temp_dir) then obj.runner = nil end
    return obj
end

function Worker:availableMemoryKB()
    return available_memory_kb(self.read_memory())
end

function Worker:available()
    return self.runner ~= nil
end

function Worker:busy()
    return self.job ~= nil
end

function Worker:_token()
    self.sequence = self.sequence + 1
    return table.concat({ tostring(self.now()), tostring(self.sequence),
        tostring(math.random(100000, 999999)) }, "-")
end

function Worker:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    self.scheduler:scheduleIn(self.poll_interval, task)
end

function Worker:_decode(path)
    local raw = read_file(path)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value, raw end
end

function Worker:_cleanup(job)
    for _, path in ipairs({ job.progress_path, job.result_path,
        job.cancel_path }) do
        os.remove(path)
        os.remove(path .. ".tmp")
    end
end

function Worker:_complete(request, result)
    if request and request.options and type(request.options.on_done) == "function" then
        local ok, err = pcall(request.options.on_done, result)
        if not ok then
            require("weread.lib.logger").warn("background worker callback:", tostring(err))
        end
    end
end

function Worker:_launch(request)
    if not self.runner then
        self:_complete(request, { ok = false, error = "worker_unavailable" })
        return false, "worker_unavailable"
    end
    local now = self.now()
    if self.memory_cooldown_until and now < self.memory_cooldown_until then
        self:_complete(request, { ok = false, error = "low_memory" })
        return false, "low_memory"
    end
    collectgarbage("collect")
    local free_kb = self:availableMemoryKB()
    if free_kb and free_kb < self.min_available_kb then
        self:_complete(request, {
            ok = false, error = "low_memory", available_kb = free_kb,
        })
        return false, "low_memory"
    end

    local prefix = self.temp_dir .. "/prefetch-" .. request.token
    local progress_path = prefix .. ".progress.json"
    local result_path = prefix .. ".result.json"
    local cancel_path = prefix .. ".cancel"
    local child = function()
        local function cancelled()
            return lfs.attributes(cancel_path) ~= nil
        end
        local context = {
            token = request.token,
            cancelled = cancelled,
            checkCancelled = function()
                if cancelled() then error("__weread_worker_cancelled__", 0) end
            end,
            emit = function(state)
                state = type(state) == "table" and state or {}
                state.task_token = request.token
                state.updated_at = os.time()
                local encoded_ok, encoded = pcall(Json.encode, state)
                if encoded_ok then atomic_write(progress_path, encoded) end
            end,
            sleep = function(seconds)
                local remaining = math.max(0, tonumber(seconds) or 0)
                while remaining > 0 do
                    if cancelled() then error("__weread_worker_cancelled__", 0) end
                    local slice = math.min(remaining, 0.1)
                    if type(FFIUtil.usleep) == "function" then
                        FFIUtil.usleep(math.floor(slice * 1000000))
                    end
                    remaining = remaining - slice
                end
            end,
        }
        local ok, value = xpcall(function()
            context.checkCancelled()
            return request.options.task(context)
        end, debug.traceback)
        local cancelled_error = not ok
            and tostring(value):find("__weread_worker_cancelled__", 1, true) ~= nil
        local payload = ok and { ok = true, value = value,
            task_token = request.token }
            or { ok = false, cancelled = cancelled_error or nil,
                error = cancelled_error and "cancelled" or tostring(value),
                task_token = request.token }
        local encoded_ok, encoded = pcall(Json.encode, payload)
        if encoded_ok then atomic_write(result_path, encoded) end
    end
    local ok, pid, err = pcall(self.runner.run, child)
    if not ok or not pid then
        local detail = tostring(err or pid or "worker launch failed")
        if memory_error(detail) then
            self.memory_cooldown_until = now + MEMORY_COOLDOWN_SECONDS
            detail = "low_memory"
        end
        self:_complete(request, { ok = false, error = detail,
            available_kb = free_kb })
        return false, detail
    end
    self.job = {
        request = request, pid = pid, started_at = now,
        last_progress_at = now, progress_path = progress_path,
        result_path = result_path, cancel_path = cancel_path,
    }
    if type(request.options.on_launch) == "function" then
        pcall(request.options.on_launch, pid, free_kb)
    end
    self:_schedule()
    return true
end

function Worker:_startPending()
    if self.job or not self.pending then return end
    local pending = self.pending
    self.pending = nil
    self:_launch(pending)
end

function Worker:start(options)
    options = options or {}
    assert(type(options.task) == "function", "worker task required")
    local request = { token = self:_token(), options = options }
    if self.job then
        if not options.queue then return false, "worker_busy" end
        if self.pending then
            local previous = self.pending
            self.pending = nil
            self:_complete(previous, { ok = false, cancelled = true,
                error = "replaced" })
        end
        self.pending = request
        if options.replace_active then
            self:cancel(self.job.request, "superseded")
        end
        return true, request
    end
    local ok, err = self:_launch(request)
    if not ok then return false, err end
    return true, request
end

function Worker:cancel(request, reason)
    if request and self.pending == request then
        self.pending = nil
        self:_complete(request, { ok = false, cancelled = true,
            error = reason or "cancelled" })
        return true
    end
    local job = self.job
    if not job or (request and job.request ~= request) then return false end
    if not job.cancel_requested_at then
        job.request.cancel_reason = reason or "cancelled"
        local ok = atomic_write(job.cancel_path, "1")
        job.cancel_requested_at = self.now()
        if not ok then
            pcall(self.runner.terminate, job.pid)
            job.terminated = true
        end
    end
    self:_schedule()
    return true
end

function Worker:_poll()
    local job = self.job
    if not job then self:_startPending(); return end
    local progress, raw = self:_decode(job.progress_path)
    if progress and raw ~= job.last_progress_raw
        and tostring(progress.task_token or "") == job.request.token then
        job.last_progress_raw = raw
        job.last_progress_at = tonumber(progress.updated_at) or self.now()
        if type(job.request.options.on_progress) == "function" then
            pcall(job.request.options.on_progress, progress)
        end
    end

    local now = self.now()
    if job.cancel_requested_at and not job.terminated
        and now - job.cancel_requested_at >= self.cancel_grace then
        pcall(self.runner.terminate, job.pid)
        job.terminated = true
    elseif not job.cancel_requested_at and not job.terminated
        and now - job.last_progress_at >= (tonumber(job.request.options.timeout)
            or self.timeout) then
        job.request.cancel_reason = "worker_timeout"
        pcall(self.runner.terminate, job.pid)
        job.terminated = true
    end

    local done_ok, done = pcall(self.runner.is_done, job.pid)
    if not done_ok or not done then
        self:_schedule()
        return
    end
    local result = self:_decode(job.result_path)
    if not result or tostring(result.task_token or "") ~= job.request.token then
        result = { ok = false,
            cancelled = job.cancel_requested_at ~= nil,
            error = job.request.cancel_reason or "worker_no_result" }
    end
    self.job = nil
    self:_cleanup(job)
    self:_complete(job.request, result)
    self:_startPending()
end

Worker.available_memory_kb = available_memory_kb

return Worker
