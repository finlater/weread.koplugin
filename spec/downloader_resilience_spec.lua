package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

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
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
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

local serial_behavior
local serial_calls = 0
local save_calls = 0
package.preload["weread.lib.content"] = function()
    return {
        fetch_single_chapter_source = function()
            serial_calls = serial_calls + 1
            if serial_behavior == "fail"
                or (type(serial_behavior) == "number"
                    and serial_calls < serial_behavior) then
                error("injected source failure")
            end
            if serial_behavior == "invalid" then return "invalid" end
            return "valid"
        end,
        validate_chapter_source = function(_chapter, xhtml)
            return xhtml == "valid", 100, 100
        end,
        save_book_epub = function()
            save_calls = save_calls + 1
            return "/cache/book.epub"
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.footnotes"] = function()
    return { scan_chapter = function() return {} end }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.parallel"] = function() return {} end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end,
    }
end

local Downloader = require("weread.lib.downloader")

local messages = {}
local completions = {}
local finished = 0
local downloader = Downloader:new{
    client = {},
    settings = { get = function(_self, _key, default) return default end },
    show_info = function(text) messages[#messages + 1] = text end,
    show_transient = function() end,
    refresh_shelf = function() end,
}
downloader._finishChapter = function(_self, _dl) finished = finished + 1 end

local function make_download(source)
    local chapter = { chapterUid = 7, title = "Chapter", wordCount = 100 }
    return {
        book = { book_id = "book", title = "Book" },
        chapters = { chapter },
        chapter_sources = source and { source } or nil,
        selected = {},
        bodies = {},
        assets = {},
        state = {},
        index = 1,
        total = 1,
        failed = {},
        annotation_failed_batches = 0,
        footnote_scans = {},
        parallel = { chapters = 1, comments = 1, images = 1 },
        cancelled = false,
        started_at = 999,
        on_complete = function(ok, value)
            completions[#completions + 1] = { ok = ok, value = value }
        end,
    }
end

serial_calls = 0
serial_behavior = 1
local recovered = make_download({ error = "parallel worker failed" })
downloader:_step(recovered)
expect(serial_calls == 1 and finished == 1,
    "parallel worker failure did not fall back to one serial fetch")

serial_calls = 0
serial_behavior = 3
finished = 0
local retried = make_download()
downloader:_step(retried)
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end
expect(serial_calls == 3 and finished == 1 and not retried.aborted,
    "serial chapter source did not recover on the third attempt")

serial_calls = 0
serial_behavior = "invalid"
finished = 0
local invalid = make_download()
downloader:_step(invalid)
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end
expect(serial_calls == 3 and invalid.aborted and finished == 0,
    "structurally incomplete serial content bypassed retry exhaustion")

serial_calls = 0
serial_behavior = "fail"
finished = 0
local exhausted = make_download()
downloader:_step(exhausted)
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end
expect(serial_calls == 3 and exhausted.aborted and finished == 0,
    "exhausted chapter retries did not abort the combined book")
expect(#completions == 2 and completions[2].ok == false,
    "aborted book did not report a failed completion")
expect(#messages == 2,
    "aborted books did not surface exactly one failure message each")

local incomplete = make_download()
incomplete.chapters = {
    { chapterUid = 7, title = "First" },
    { chapterUid = 8, title = "Second" },
}
incomplete.total = 2
incomplete.index = 3
incomplete.selected = { incomplete.chapters[1] }
incomplete.footnotes_done = true
downloader:_step(incomplete)
expect(incomplete.aborted,
    "combined-book completeness guard accepted a missing chapter")
expect(#completions == 3 and completions[3].ok == false,
    "completeness guard did not report failed completion")
expect(save_calls == 0,
    "completeness failure reached the EPUB writer")

print(("downloader_resilience_spec: %d checks"):format(checks))
