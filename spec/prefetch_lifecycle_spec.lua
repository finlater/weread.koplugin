-- Focused tests for next-chapter selection and one-second prefetch notices.

package.path = "./?.lua;" .. package.path

local existing = {}
local logs = {}
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return {
                info = function(...) logs[#logs + 1] = { "info", ... } end,
                warn = function(...) logs[#logs + 1] = { "warn", ... } end,
            }
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(book_id) return book_id == "mp-book" end }
end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        display_error = function(value) return tostring(value) end,
        log_error = function(value) return tostring(value) end,
        file_exists = function(path) return existing[path] == true end,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local chapters = {
    { chapterUid = 1, title = "One" },
    { chapterUid = 2, title = "Two" },
    { chapterUid = 3, title = "Three" },
}
local book = {
    book_id = "book",
    chapters = chapters,
    cached_chapters = { ["1"] = "/cache/one.epub" },
}
existing["/cache/one.epub"] = true

local cache = {
    auto_prefetch_next_chapter = true,
    show_prefetch_notifications = true,
    download_underlines_and_thoughts = true,
}
local starts = {}
local notices = {}
local downloader = {
    cancelPrefetch = function() end,
    isPrefetching = function() return false end,
    isPromotedPrefetch = function() return false end,
    start = function(_self, target_book, target_chapters, suffix, options)
        starts[#starts + 1] = {
            book = target_book,
            chapters = target_chapters,
            suffix = suffix,
            options = options,
        }
        return true
    end,
}
local host = {
    settings = {
        get = function(_self, key)
            if key == "cache" then return cache end
            if key == "books" then return { book = book } end
        end,
    },
    downloader = downloader,
    ui = { document = { file = "/cache/one.epub" } },
    ensureChaptersLoaded = function() return chapters end,
    showTransientInfo = function(_self, text, timeout)
        notices[#notices + 1] = { text, timeout }
    end,
    detectWeReadBook = function() return nil end,
    requireLogin = function() return true end,
    progress_sync = { sync_now = function() end },
}
for key, value in pairs(Lifecycle) do host[key] = value end
host.detectWeReadBook = function() return nil end

expect(host:maybePrefetchNextChapter("book"), "prefetch request accepted")
expect(#starts == 1 and starts[1].chapters[1] == chapters[2],
    "only the immediate next chapter is selected")
expect(starts[1].options.include_annotations == true,
    "background annotation preference is forwarded")
expect(starts[1].options.start_delay == 0.7,
    "visible start notice gets time to close before network work")

starts[1].options.on_start()
starts[1].options.on_complete(true, "/cache/two.epub")
expect(#notices == 2 and notices[1][2] == 0.5 and notices[2][2] == 1,
    "start notice lasts half a second and completion lasts one second")
expect(#logs == 2 and logs[1][1] == "info" and logs[2][1] == "info",
    "prefetch start and success are logged")

starts = {}
notices = {}
book.cached_chapters["2"] = "/cache/two.epub"
existing["/cache/two.epub"] = true
expect(host:maybePrefetchNextChapter("book"), "cached next chapter is satisfied")
expect(#starts == 0, "cached next chapter does not scan forward to chapter three")

book.cached_chapters["2"] = nil
existing["/cache/two.epub"] = nil
host:maybePrefetchNextChapter("book")
starts[1].options.on_complete(false, "offline")
expect(#notices == 1
    and notices[1][1]:find("Network is not connected", 1, true) ~= nil,
    "offline prefetch reports a failure")
expect(logs[#logs][1] == "warn", "prefetch failure is logged")

cache.show_prefetch_notifications = false
starts = {}
host:maybePrefetchNextChapter("book")
expect(starts[1].options.start_delay == 0.1,
    "silent prefetch does not pay the notification grace delay")
starts[1].options.on_start()
starts[1].options.on_complete(false, "network error")
expect(#notices == 1, "notification setting silences all prefetch notices")

local legacy_single = {
    cached_file = "/cache/one.epub",
    cached_chapters = { ["1"] = "/cache/one.epub" },
}
expect(host:getFullBookCachePath(legacy_single) == nil,
    "legacy single chapter is not mistaken for a full book")
legacy_single.cached_chapters["2"] = "/cache/one.epub"
expect(host:getFullBookCachePath(legacy_single) == "/cache/one.epub",
    "legacy combined EPUB remains a full-book cache")

notices = {}
expect(not host:onWeReadSyncProgress(),
    "standalone sync gesture rejects a local document")
expect(notices[1] and notices[1][2] == 1,
    "standalone sync gesture explains missing WeRead context")

print(string.format(
    "prefetch_lifecycle_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
