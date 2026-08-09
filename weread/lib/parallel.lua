-- Bounded subprocess pool for network-heavy work.
--
-- KOReader's Lua runtime has no native thread pool and LuaSocket requests are
-- blocking. ffi/util.runInSubProcess gives us isolated POSIX workers without
-- sharing mutable Lua/SQLite state. Results are exchanged through per-task
-- files so large chapter/image payloads cannot deadlock a pipe.
local ok_ui, UIManager = pcall(require, "ui/uimanager")
if not ok_ui then
    UIManager = { scheduleIn = function(_self, _delay, callback) callback() end }
end
local ok_ffi, ffiUtil = pcall(require, "ffi/util")
if not ok_ffi then ffiUtil = {} end
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = {} end

local Parallel = {}
Parallel.MAX_CONCURRENCY = 8

local job_sequence = 0

local function clamp(value, minimum, maximum)
    value = math.floor(tonumber(value) or minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function ensure_dir(path)
    if type(lfs.attributes) ~= "function" or type(lfs.mkdir) ~= "function" then
        return false, "filesystem support is unavailable"
    end
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path)
end

local function write_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then error(err or ("cannot write " .. tostring(path))) end
    local ok, write_err = file:write(data or "")
    file:close()
    if not ok then error(write_err or ("cannot write " .. tostring(path))) end
    return true
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function remove_dir(path)
    if type(lfs.attributes) ~= "function" or type(lfs.dir) ~= "function" then return end
    if lfs.attributes(path, "mode") ~= "directory" then return end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            if lfs.attributes(child, "mode") == "directory" then
                remove_dir(child)
            else
                pcall(os.remove, child)
            end
        end
    end
    pcall(lfs.rmdir, path)
end

local function make_job_dir(base_dir, prefix)
    ensure_dir(base_dir)
    job_sequence = job_sequence + 1
    local path = string.format("%s/%s-%d-%d-%d", base_dir,
        tostring(prefix or "job"), os.time(), job_sequence, math.random(1000, 9999))
    local ok, err = ensure_dir(path)
    if not ok then error(err or "cannot create parallel job directory") end
    return path
end

local function task_dir(job_dir, index)
    local path = string.format("%s/task-%04d", job_dir, index)
    local ok, err = ensure_dir(path)
    if not ok then error(err or "cannot create parallel task directory") end
    return path
end

local function spawn_subprocess(callback)
    local ok, pid, err = pcall(ffiUtil.runInSubProcess, callback)
    if not ok then return false, pid end
    return pid, err
end

function Parallel.write_file(path, data)
    return write_file(path, data)
end

function Parallel.read_file(path)
    return read_file(path)
end

function Parallel.detect_memory_mb()
    local file = io.open("/proc/meminfo", "r")
    if file then
        for line in file:lines() do
            local kb = line:match("^MemTotal:%s+(%d+)%s+kB")
            if kb then
                file:close()
                return math.max(1, math.floor(tonumber(kb) / 1024 + 0.5))
            end
        end
        file:close()
    end
    return nil
end

function Parallel.recommended(memory_mb)
    memory_mb = tonumber(memory_mb) or 512
    if memory_mb <= 256 then
        return { chapters = 1, comments = 1, images = 1 }
    elseif memory_mb <= 512 then
        return { chapters = 1, comments = 2, images = 2 }
    elseif memory_mb <= 1024 then
        return { chapters = 1, comments = 3, images = 3 }
    elseif memory_mb <= 2048 then
        return { chapters = 1, comments = 4, images = 4 }
    end
    return { chapters = 1, comments = 6, images = 6 }
end

function Parallel.config(settings)
    local cache = {}
    if settings and type(settings.get) == "function" then
        cache = settings:get("cache", {}) or {}
    end
    local memory_mb = Parallel.detect_memory_mb()
    local preset = memory_mb and Parallel.recommended(memory_mb)
        or { chapters = 1, comments = 1, images = 1 }
    local automatic = cache.concurrency_auto ~= false
    local config = {
        automatic = automatic,
        memory_mb = memory_mb,
        chapters = automatic and preset.chapters
            or clamp(cache.chapter_concurrency, 1, Parallel.MAX_CONCURRENCY),
        comments = automatic and preset.comments
            or clamp(cache.comment_concurrency, 1, Parallel.MAX_CONCURRENCY),
        images = automatic and preset.images
            or clamp(cache.image_concurrency, 1, Parallel.MAX_CONCURRENCY),
    }
    if not Parallel.available() then
        config.chapters, config.comments, config.images = 1, 1, 1
        config.supported = false
    else
        config.supported = true
    end
    return config
end

function Parallel.available()
    return type(ffiUtil.runInSubProcess) == "function"
        and type(ffiUtil.isSubProcessDone) == "function"
        and type(ffiUtil.terminateSubProcess) == "function"
end

local Pool = {}
Pool.__index = Pool

function Pool:_spawn(index)
    local task = self.tasks[index]
    local dir = task_dir(self.job_dir, index)
    local worker = self.worker
    local pid, err = spawn_subprocess(function()
        local ok, worker_err = xpcall(function()
            worker(task, dir)
        end, debug.traceback)
        if ok then
            write_file(dir .. "/_status", "ok")
        else
            write_file(dir .. "/_error", tostring(worker_err):sub(1, 8192))
            write_file(dir .. "/_status", "error")
        end
    end)
    if not pid then
        local ok, worker_err = xpcall(function()
            worker(task, dir)
        end, debug.traceback)
        if ok then
            write_file(dir .. "/_status", "ok")
        else
            write_file(dir .. "/_error", tostring(worker_err or err):sub(1, 8192))
            write_file(dir .. "/_status", "error")
        end
        self:_collect(index, task, dir)
        return
    end
    self.active[index] = { pid = pid, task = task, dir = dir }
end

function Pool:_collect(index, task, dir)
    local status = read_file(dir .. "/_status")
    local worker_err = read_file(dir .. "/_error")
    local ok, value, load_err = pcall(self.load_result, task, dir,
        status == "ok", worker_err)
    if not ok then
        value, load_err = nil, value
    end
    self.completed = self.completed + 1
    if self.on_result then
        local callback_ok, callback_err = pcall(self.on_result,
            task, value, load_err, self.completed, #self.tasks)
        if not callback_ok and not self.first_error then
            self.first_error = callback_err
        end
    end
    remove_dir(dir)
end

function Pool:_finish(ok, err)
    if self.finished then return end
    self.finished = true
    remove_dir(self.job_dir)
    if self.on_complete then
        self.on_complete(ok == true, err or self.first_error)
    end
end

function Pool:cancel(reason)
    if self.finished or self.cancelled then return end
    self.cancelled = true
    self.cancel_reason = reason or "cancelled"
    self.next_index = #self.tasks + 1
    for _, slot in pairs(self.active) do
        ffiUtil.terminateSubProcess(slot.pid)
    end
end

function Pool:_poll()
    if self.finished then return end
    if self.is_cancelled and self.is_cancelled() then
        self:cancel("cancelled")
    end

    for index, slot in pairs(self.active) do
        if ffiUtil.isSubProcessDone(slot.pid) then
            self.active[index] = nil
            self:_collect(index, slot.task, slot.dir)
        end
    end

    if self.cancelled then
        if next(self.active) == nil then
            self:_finish(false, self.cancel_reason)
            return
        end
        UIManager:scheduleIn(0.05, function() self:_poll() end)
        return
    end

    while self.next_index <= #self.tasks do
        local active_count = 0
        for _index in pairs(self.active) do active_count = active_count + 1 end
        if active_count >= self.concurrency then break end
        local index = self.next_index
        self.next_index = index + 1
        self:_spawn(index)
    end

    if self.completed >= #self.tasks and next(self.active) == nil then
        self:_finish(self.first_error == nil, self.first_error)
        return
    end
    UIManager:scheduleIn(0.05, function() self:_poll() end)
end

function Parallel.start(options)
    assert(Parallel.available(), "parallel subprocesses are unavailable")
    assert(type(options) == "table" and type(options.tasks) == "table")
    local base_dir = assert(options.base_dir, "parallel base_dir is required")
    local pool = setmetatable({
        tasks = options.tasks,
        worker = assert(options.worker, "parallel worker is required"),
        load_result = assert(options.load_result, "parallel loader is required"),
        on_result = options.on_result,
        on_complete = options.on_complete,
        is_cancelled = options.is_cancelled,
        concurrency = clamp(options.concurrency, 1, Parallel.MAX_CONCURRENCY),
        active = {},
        next_index = 1,
        completed = 0,
        job_dir = make_job_dir(base_dir, options.prefix),
    }, Pool)
    UIManager:scheduleIn(0.01, function() pool:_poll() end)
    return pool
end

-- Used by the synchronous public-account article path. Network work still runs
-- concurrently; only the caller waits for all workers, matching the old API.
function Parallel.map_blocking(options)
    local tasks = options.tasks or {}
    if #tasks == 0 then return {} end
    local concurrency = clamp(options.concurrency, 1, Parallel.MAX_CONCURRENCY)
    local results = {}
    if concurrency <= 1 or not Parallel.available() then
        local job_dir = make_job_dir(options.base_dir, options.prefix)
        for index, task in ipairs(tasks) do
            local dir = task_dir(job_dir, index)
            local ok, worker_err = xpcall(function()
                options.worker(task, dir)
            end, debug.traceback)
            local value, load_err = options.load_result(task, dir, ok,
                ok and nil or worker_err)
            results[index] = { value = value, error = load_err }
            if options.on_result then
                options.on_result(task, value, load_err, index, #tasks)
            end
            remove_dir(dir)
        end
        remove_dir(job_dir)
        return results
    end

    local job_dir = make_job_dir(options.base_dir, options.prefix)
    local active, next_index, completed = {}, 1, 0
    while completed < #tasks do
        while next_index <= #tasks do
            local active_count = 0
            for _index in pairs(active) do active_count = active_count + 1 end
            if active_count >= concurrency then break end
            local index, task = next_index, tasks[next_index]
            next_index = next_index + 1
            local dir = task_dir(job_dir, index)
            local pid, spawn_err = spawn_subprocess(function()
                local ok, worker_err = xpcall(function()
                    options.worker(task, dir)
                end, debug.traceback)
                if ok then
                    write_file(dir .. "/_status", "ok")
                else
                    write_file(dir .. "/_error", tostring(worker_err):sub(1, 8192))
                    write_file(dir .. "/_status", "error")
                end
            end)
            if pid then
                active[index] = { pid = pid, task = task, dir = dir }
            else
                local ok, worker_err = xpcall(function()
                    options.worker(task, dir)
                end, debug.traceback)
                if ok then
                    write_file(dir .. "/_status", "ok")
                else
                    write_file(dir .. "/_error",
                        tostring(worker_err or spawn_err):sub(1, 8192))
                    write_file(dir .. "/_status", "error")
                end
                active[index] = { pid = false, task = task, dir = dir }
            end
        end
        for index, slot in pairs(active) do
            if slot.pid == false or ffiUtil.isSubProcessDone(slot.pid) then
                active[index] = nil
                local status = read_file(slot.dir .. "/_status")
                local worker_err = read_file(slot.dir .. "/_error")
                local value, load_err = options.load_result(slot.task, slot.dir,
                    status == "ok", worker_err)
                results[index] = { value = value, error = load_err }
                completed = completed + 1
                if options.on_result then
                    options.on_result(slot.task, value, load_err, completed, #tasks)
                end
                remove_dir(slot.dir)
            end
        end
        if completed < #tasks then ffiUtil.usleep(50000) end
    end
    remove_dir(job_dir)
    return results
end

return Parallel
