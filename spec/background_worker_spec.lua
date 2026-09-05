package.path = "./?.lua;" .. package.path

local temp_dir = "/tmp/weread-background-worker-spec"
os.execute("mkdir -p " .. temp_dir)

local encoded, sequence = {}, 0
package.preload["json"] = function()
    return {
        encode = function(value)
            sequence = sequence + 1
            local key = "encoded-" .. tostring(sequence)
            encoded[key] = value
            return key
        end,
        decode = function(key) return encoded[key] end,
    }
end
package.preload["ffi/util"] = function()
    return { isAndroid = function() return false end }
end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function() end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            if path == temp_dir then return field and "directory" or { mode = "directory" } end
            local file = io.open(path, "rb")
            if not file then return nil end
            file:close()
            return field and "file" or { mode = "file" }
        end,
        mkdir = function(path)
            os.execute("mkdir -p " .. path)
            return true
        end,
    }
end

local BackgroundWorker = require("weread.lib.background_worker")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local scheduled, callbacks, done, terminated = {}, {}, {}, {}
local next_pid, clock = 200, 1000
local runner = {
    run = function(callback)
        next_pid = next_pid + 1
        callbacks[next_pid] = callback
        done[next_pid] = false
        return next_pid
    end,
    is_done = function(pid) return done[pid] == true end,
    terminate = function(pid)
        terminated[pid] = true
        done[pid] = true
    end,
}
local scheduler = {
    scheduleIn = function(_self, _delay, callback)
        scheduled[#scheduled + 1] = callback
    end,
}
local function new_worker(memory_kb)
    return BackgroundWorker:new {
        temp_dir = temp_dir,
        runner = runner,
        scheduler = scheduler,
        now = function() return clock end,
        read_memory = function()
            return "MemAvailable: " .. tostring(memory_kb) .. " kB\n"
        end,
        min_available_kb = 128 * 1024,
    }
end
local function poll()
    local callback = table.remove(scheduled, 1)
    expect(callback ~= nil, "worker did not schedule a poll")
    callback()
end

expect(BackgroundWorker.available_memory_kb(
    "MemFree: 10 kB\nBuffers: 20 kB\nCached: 30 kB\n") == 60,
    "legacy kernels must derive available memory")

local worker = new_worker(256 * 1024)
local progress, result
local started, handle = worker:start {
    task = function(context)
        context.emit { stage = "source", current = 2, count = 5 }
        return { path = "/tmp/book.epub" }
    end,
    on_progress = function(value) progress = value end,
    on_done = function(value) result = value end,
}
expect(started and handle and worker:busy(), "worker did not start")
callbacks[201]()
done[201] = true
poll()
expect(progress and progress.current == 2 and progress.count == 5,
    "progress file was not delivered")
expect(result and result.ok and result.value.path == "/tmp/book.epub",
    "result file was not delivered")
expect(not worker:busy(), "completed child was not cleared")

local first_done, second_done = false, false
local first_ok, first = worker:start {
    task = function() return "first" end,
    on_done = function(value) first_done = value.ok end,
}
local second_ok, second = worker:start {
    queue = true,
    task = function() return "second" end,
    on_done = function(value) second_done = value.ok end,
}
expect(first_ok and second_ok and first ~= second,
    "one pending task was not accepted")
callbacks[202](); done[202] = true; poll()
expect(first_done and worker:busy(), "pending task did not start after reaping")
callbacks[203](); done[203] = true; poll()
expect(second_done and not worker:busy(), "pending task did not finish")

local cancel_result
local cancel_ok, cancel_handle = worker:start {
    task = function() return "never run" end,
    on_done = function(value) cancel_result = value end,
}
expect(cancel_ok and worker:cancel(cancel_handle, "document_closed"),
    "active task did not accept cancellation")
clock = clock + 6
poll()
expect(terminated[204] and cancel_result and cancel_result.cancelled
    and cancel_result.error == "document_closed",
    "cancel grace did not terminate and report the task")

local launches_before = next_pid
local low_result
local low = new_worker(32 * 1024)
local low_ok, low_err = low:start {
    task = function() return true end,
    on_done = function(value) low_result = value end,
}
expect(not low_ok and low_err == "low_memory" and next_pid == launches_before,
    "128 MB gate still attempted to fork")
expect(low_result and low_result.available_kb == 32 * 1024,
    "low-memory result omitted available memory")

print(("background_worker_spec: %d checks"):format(checks))
