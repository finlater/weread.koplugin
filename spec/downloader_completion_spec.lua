-- Focused tests for automatic opening after a progress-target chapter download.
-- Run from the repo root with:
--   lua spec/downloader_completion_spec.lua

package.path = "./?.lua;" .. package.path

local shown = {}
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
        show = function(_self, widget) shown[#shown + 1] = widget end,
        preventStandby = function() end,
        allowStandby = function() end,
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
local full_book_save_count = 0
package.preload["weread.lib.content"] = function()
    return {
        save_chapter_epub = function(_settings, _book, chapter)
            return "/cache/book/chapter-" .. tostring(chapter.chapterUid) .. ".epub"
        end,
        save_book_epub = function()
            full_book_save_count = full_book_save_count + 1
            return "/cache/book/replacement-full.epub"
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
    }
end

local Downloader = require("weread.lib.downloader")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local stored_books
local live_books = {
    book = {
        book_id = "book",
        progress = 88,
        cached_chapters = { existing = "/cache/book/existing.epub" },
    },
}
local opened
local info_messages = {}
local completion_count = 0
local completion_ok
local completion_path
local settings = {
    get = function(_self, key)
        return key == "books" and live_books or nil
    end,
    set = function(_self, key, value)
        if key == "books" then
            stored_books = value
            live_books = value
        end
    end,
    flush = function() end,
}
local downloader = Downloader:new{
    settings = settings,
    client = {},
    refresh_shelf = function() end,
    open_file = function(path) opened = path end,
    show_info = function(text) info_messages[#info_messages + 1] = text end,
    show_transient = function() end,
}
local chapter = { chapterUid = 22, title = "Target" }
local download = {
    book = { book_id = "book", title = "Book" },
    chapters = { chapter },
    selected = { chapter },
    bodies = { ["22"] = "<p>body</p>" },
    assets = {},
    state = { css = "" },
    suffix = "chapter",
    index = 2,
    total = 1,
    failed = {},
    annotation_failed_batches = 0,
    single_chapter = true,
    open_on_complete = true,
    started_at = 999,
    on_complete = function(ok, path)
        completion_count = completion_count + 1
        completion_ok = ok
        completion_path = path
    end,
}

downloader:_step(download)

eq(completion_count, 1, "completion callback count")
eq(completion_ok, true, "completion success")
eq(completion_path, "/cache/book/chapter-22.epub", "completion path")
eq(opened, "/cache/book/chapter-22.epub", "automatically opened path")
eq(#shown, 0, "no redundant read-now dialog")
eq(stored_books.book.cached_chapters["22"],
    "/cache/book/chapter-22.epub", "target chapter persisted")
eq(stored_books.book.progress, 88,
    "download cache merge preserved newer reading progress")
eq(stored_books.book.cached_chapters.existing, "/cache/book/existing.epub",
    "download cache merge preserved unrelated chapter mappings")

local chapter_33 = { chapterUid = 33, title = "Other" }
live_books.book.cached_file = "/cache/book/full.epub"
live_books.book.cached_full_book = "/cache/book/full.epub"
local separate = {
    book = {
        book_id = "book",
        title = "Book",
        cached_file = "/cache/book/full.epub",
        cached_full_book = "/cache/book/full.epub",
    },
    chapters = { chapter, chapter_33 },
    selected = { chapter, chapter_33 },
    bodies = { ["22"] = "<p>22</p>", ["33"] = "<p>33</p>" },
    assets = {},
    assets_by_uid = { ["22"] = {}, ["33"] = {} },
    state = { css = "" },
    suffix = "chapters",
    index = 3,
    total = 2,
    failed = {},
    annotation_failed_batches = 0,
    separate_chapters = true,
    silent_completion = true,
    started_at = 999,
}
downloader:_step(separate)
eq(stored_books.book.cached_chapters["22"],
    "/cache/book/chapter-22.epub", "first selected chapter persisted separately")
eq(stored_books.book.cached_chapters["33"],
    "/cache/book/chapter-33.epub", "second selected chapter persisted separately")
eq(stored_books.book.cached_full_book, "/cache/book/full.epub",
    "partial download preserved the full-book cache")

local incomplete_full_completion_count = 0
local incomplete_full_completion_ok
local incomplete_full_completion_value
local incomplete_full = {
    book = {
        book_id = "book",
        title = "Book",
        cached_file = "/cache/book/full.epub",
        cached_full_book = "/cache/book/full.epub",
    },
    chapters = { chapter, chapter_33 },
    selected = { chapter },
    bodies = { ["22"] = "<p>22</p>" },
    assets = {},
    state = { css = "" },
    suffix = "full",
    index = 3,
    total = 2,
    failed = { "33" },
    annotation_failed_batches = 0,
    started_at = 999,
    on_complete = function(ok, value)
        incomplete_full_completion_count = incomplete_full_completion_count + 1
        incomplete_full_completion_ok = ok
        incomplete_full_completion_value = value
    end,
}
downloader:_step(incomplete_full)
eq(full_book_save_count, 0,
    "incomplete full-book download did not build a partial EPUB")
eq(stored_books.book.cached_full_book, "/cache/book/full.epub",
    "incomplete full-book download preserved the existing full cache")
eq(stored_books.book.cached_file, "/cache/book/full.epub",
    "incomplete full-book download preserved the compatibility cache alias")
eq(incomplete_full_completion_count, 1,
    "incomplete full-book completion callback count")
eq(incomplete_full_completion_ok, false,
    "incomplete full-book completion reported failure")
eq(incomplete_full_completion_value, "incomplete_full_book",
    "incomplete full-book completion reason")
eq(#info_messages, 1,
    "incomplete full-book failure was shown to the user")

print(string.format(
    "downloader_completion_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
