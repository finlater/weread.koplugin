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
        min_available_kb = 64 * 1024,
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
    "64 MB gate still attempted to fork")
expect(low_result and low_result.available_kb == 32 * 1024,
    "low-memory result omitted available memory")

local annotation_result, chapter_result
local annotation_ok = worker:start {
    kind = "annotation",
    task = function() return "annotation" end,
    on_done = function(value) annotation_result = value end,
}
local annotation_pid = next_pid
local chapter_ok = worker:start {
    kind = "chapter",
    queue = true,
    replace_active = true,
    task = function() return "chapter" end,
    on_done = function(value) chapter_result = value end,
}
expect(annotation_ok and chapter_ok,
    "different worker kinds were not accepted")
callbacks[annotation_pid](); done[annotation_pid] = true; poll()
expect(annotation_result and annotation_result.ok
        and annotation_result.value == "annotation",
    "chapter replacement cancelled an active annotation task")
local chapter_pid = next_pid
callbacks[chapter_pid](); done[chapter_pid] = true; poll()
expect(chapter_result and chapter_result.ok
        and chapter_result.value == "chapter" and not worker:busy(),
    "queued chapter task did not run after the annotation task")

local superseded_result, replacement_result
local old_chapter_ok = worker:start {
    kind = "chapter",
    task = function() return "old chapter" end,
    on_done = function(value) superseded_result = value end,
}
local old_chapter_pid = next_pid
local replacement_ok = worker:start {
    kind = "chapter",
    queue = true,
    replace_active = true,
    task = function() return "new chapter" end,
    on_done = function(value) replacement_result = value end,
}
clock = clock + 6
poll()
expect(old_chapter_ok and replacement_ok and terminated[old_chapter_pid]
        and superseded_result and superseded_result.cancelled
        and superseded_result.error == "superseded",
    "same-kind replacement did not supersede the active chapter task")
local replacement_pid = next_pid
callbacks[replacement_pid](); done[replacement_pid] = true; poll()
expect(replacement_result and replacement_result.ok
        and replacement_result.value == "new chapter" and not worker:busy(),
    "same-kind replacement did not run")

local legacy_result, legacy_replacement_result
worker:start {
    task = function() return "legacy" end,
    on_done = function(value) legacy_result = value end,
}
local legacy_pid = next_pid
worker:start {
    queue = true,
    replace_active = true,
    task = function() return "legacy replacement" end,
    on_done = function(value) legacy_replacement_result = value end,
}
clock = clock + 6
poll()
expect(terminated[legacy_pid] and legacy_result and legacy_result.cancelled
        and legacy_result.error == "superseded",
    "kind-less callers no longer retain the legacy replacement behavior")
local legacy_replacement_pid = next_pid
callbacks[legacy_replacement_pid](); done[legacy_replacement_pid] = true; poll()
expect(legacy_replacement_result and legacy_replacement_result.ok
        and legacy_replacement_result.value == "legacy replacement"
        and not worker:busy(),
    "kind-less replacement did not run")

print(("background_worker_spec: %d checks"):format(checks))
