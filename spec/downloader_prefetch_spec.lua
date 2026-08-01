-- Focused tests for the downloader's single-prefetch invariant and promotion.

package.path = "./?.lua;" .. package.path

local scheduled = {}
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.content"] = function()
    return { ensure_reader_state = function() end }
end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            options.show = function() end
            options.reportProgress = function() end
            options.close = function() end
            return options
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end

local Downloader = require("weread.lib.downloader")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local background = {}
local completions = {}
local downloader = Downloader:new{
    client = {},
    settings = {
        is_cookie_configured = function() return true end,
    },
    is_connected = function() return true end,
    run_background_task = function(callback)
        background[#background + 1] = callback
        return true
    end,
    show_transient = function() end,
    refresh_ui = function() end,
}

local book_a = { book_id = "a" }
local chapter_2 = { chapterUid = 2 }
local chapter_3 = { chapterUid = 3 }

expect(downloader:start(book_a, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
    on_complete = function(ok, reason)
        completions[#completions + 1] = { ok, reason }
    end,
}), "first prefetch starts")
expect(#background == 1, "first prefetch has one background callback")
expect(downloader:isPrefetching(book_a, chapter_2), "first target is active")
expect(downloader:promotePrefetch(book_a, chapter_2), "matching prefetch promotes")
expect(downloader._active_job.open_on_complete == true,
    "promotion requests automatic open")
expect(downloader._active_job.progress_dialog ~= nil,
    "promotion exposes the background task progress")
expect(downloader:isPromotedPrefetch(book_a, chapter_2),
    "promoted target can be detected by navigation")
expect(not downloader:promotePrefetch(book_a, chapter_3),
    "different chapter cannot promote")

expect(downloader:start(book_a, { chapter_3 }, "chapter", {
    prefetch = true,
    single_chapter = true,
}), "replacement prefetch is queued")
expect(downloader._active_job.cancelled == true,
    "old prefetch is cancelled before replacement")
expect(downloader._pending_start.chapters[1] == chapter_3,
    "only replacement target is pending")

downloader:_step(downloader._active_job)
expect(#scheduled == 1, "replacement schedules exactly one start")
scheduled[1]()
expect(#background == 2, "replacement creates one background callback")
expect(downloader:isPrefetching(book_a, chapter_3),
    "replacement becomes the sole active prefetch")
expect(#completions == 1 and completions[1][2] == "replaced",
    "cancelled prefetch reports replacement reason once")

downloader:cancelPrefetch("document_closed")
expect(downloader._active_job.cancelled == true,
    "document close cancels active prefetch")

scheduled = {}
local race_background = {}
local race = Downloader:new{
    client = {},
    settings = { is_cookie_configured = function() return true end },
    is_connected = function() return true end,
    run_background_task = function(callback)
        race_background[#race_background + 1] = callback
        return true
    end,
    show_transient = function() end,
    refresh_ui = function() end,
}
race:start(book_a, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
})
race:start(book_a, { chapter_3 }, "chapter", {
    prefetch = true,
    single_chapter = true,
})
race:_step(race._active_job)
expect(#scheduled == 1 and race._scheduled_start ~= nil,
    "replacement waits in a cancellable scheduled slot")
race:cancelPrefetch("document_closed")
scheduled[1]()
expect(#race_background == 1 and race._active_job == nil,
    "document close prevents the scheduled replacement from starting")

scheduled = {}
local starts_notified = 0
local deferred = Downloader:new{
    client = {},
    settings = { is_cookie_configured = function() return true end },
    is_connected = function() return true end,
    run_background_task = function(callback)
        callback()
        return true
    end,
    show_transient = function() end,
    refresh_ui = function() end,
}
expect(deferred:start({ book_id = "b" }, { chapter_2 }, "chapter", {
    prefetch = true,
    single_chapter = true,
    start_delay = 0.7,
    on_start = function() starts_notified = starts_notified + 1 end,
}), "deferred prefetch starts")
expect(starts_notified == 1 and #scheduled == 1,
    "start notice runs before initialization is scheduled")
expect(deferred._active_job.standby_guard == nil,
    "network initialization has not begun while notice is visible")
scheduled[1]()
expect(deferred._active_job.standby_guard == true,
    "network initialization begins after the notice grace period")

print(string.format(
    "downloader_prefetch_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
