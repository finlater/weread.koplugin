package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local prevented = 0
local allowed = 0
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
        preventStandby = function() prevented = prevented + 1 end,
        allowStandby = function() allowed = allowed + 1 end,
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        show = function() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
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
    return {
        ensure_reader_state = function() end,
        fetch_single_chapter_source = function()
            error("injected transient timeout")
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            return {
                options = options,
                show = function() end,
                close = function() end,
                setTitle = function() end,
                reportProgress = function() end,
            }
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end,
    }
end

local Downloader = require("weread.lib.downloader")

local completions = {}
local messages = {}
local downloader = Downloader:new{
    client = {},
    settings = {},
    require_login = function() return false end,
    run_online_task = function() error("must not run while logged out") end,
    show_info = function(text) messages[#messages + 1] = text end,
    show_transient = function(text) messages[#messages + 1] = text end,
    refresh_ui = function() end,
}
local started = downloader:start({}, {}, "book", {
    on_complete = function(ok, value)
        completions[#completions + 1] = { ok, value }
    end,
})
expect(started == false, "logged-out download should not start")
expect(#completions == 1 and completions[1][1] == false
    and completions[1][2] == "authentication_required",
    "logged-out completion result was wrong")

downloader.require_login = function() return true end
downloader.run_online_task = function() return false end
started = downloader:start({}, {}, "book", {
    on_complete = function(ok, value)
        completions[#completions + 1] = { ok, value }
    end,
})
expect(started == false, "offline download should not start")
expect(#completions == 2 and completions[2][2] == "offline",
    "offline completion result was wrong")

local cancellation_count = 0
local cancelled = {
    cancelled = true,
    standby_guard = true,
    on_complete = function(ok, value)
        cancellation_count = cancellation_count + 1
        expect(ok == false and value == "cancelled",
            "cancel completion result was wrong")
    end,
}
downloader:_beginStandby()
downloader:_step(cancelled)
downloader:_step(cancelled)
expect(cancellation_count == 1, "cancel completion callback was not idempotent")
expect(downloader._standby_ref == 0 and allowed == 1,
    "cancel did not release standby exactly once")

local guarded_completion_count = 0
local closed = 0
local guarded = {
    standby_guard = true,
    progress_dialog = { close = function() closed = closed + 1 end },
    on_complete = function(ok, value)
        guarded_completion_count = guarded_completion_count + 1
        expect(ok == false and tostring(value):find("guarded boom", 1, true),
            "guarded error completion result was wrong")
    end,
}
downloader:_beginStandby()
downloader:_scheduleGuarded(guarded, function()
    error("guarded boom")
end, 0)
expect(#scheduled == 1, "guarded step was not scheduled")
scheduled[1]()
expect(guarded_completion_count == 1 and closed == 1,
    "guarded failure did not close and notify exactly once")
expect(downloader._standby_ref == 0 and allowed == 2,
    "guarded failure leaked the standby guard")
expect(#messages >= 2, "lifecycle failures were not surfaced to the user")
expect(prevented == 2, "standby guard was not acquired exactly once per job")

local retry_download = {
    book = { book_id = "book" },
    chapters = { { chapterUid = 30, title = "Chapter 30" } },
    index = 1,
    total = 1,
    failed = {},
}
local scheduled_before_retry = #scheduled
downloader:_step(retry_download)
expect(retry_download.index == 1 and #retry_download.failed == 0,
    "first transient chapter failure was not retained for retry")
expect(#scheduled == scheduled_before_retry + 1,
    "first chapter retry was not scheduled")
scheduled[#scheduled]()
expect(retry_download.index == 1 and #retry_download.failed == 0,
    "second transient chapter failure was not retained for retry")
scheduled[#scheduled]()
expect(retry_download.index == 2 and retry_download.failed[1] == "30",
    "chapter was not skipped after exhausting two retries")

print(("downloader_lifecycle_spec: %d checks"):format(checks))
