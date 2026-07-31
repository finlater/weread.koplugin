package.path = "./?.lua;" .. package.path

local existing_paths = {}
local function empty_module() return {} end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = empty_module
package.preload["ui/widget/confirmbox"] = empty_module
package.preload["ui/widget/infomessage"] = empty_module
package.preload["ui/widget/inputdialog"] = empty_module
package.preload["ui/widget/progressbardialog"] = empty_module
package.preload["ui/widget/textviewer"] = empty_module
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_self, _delay, callback) callback() end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path) return existing_paths[path] == true end,
    }
end

local fetched_chapters = { { chapterUid = 7, title = "Cached chapter" } }
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        fetch_catalog = function() return fetched_chapters end,
        save_catalog_cache = function() return true end,
        load_catalog_cache = function() return nil end,
    }
end

local Library = require("weread.ui.library")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local books = {}
local db_detail
local written_book
local written_chapters
local auto_refresh
local shown_book
local opened_path
local single_download_options
local single_download_refreshed = false
local host = {
    settings = {
        get = function(_self, key, default)
            if key == "books" then return books end
            return default
        end,
        set = function(_self, key, value)
            if key == "books" then books = value end
        end,
        flush = function() end,
    },
    library_db = {
        accountKey = function() return "account-a" end,
        getBook = function() return db_detail end,
        putBook = function(_self, book) written_book = book return true end,
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_chapters = chapters
            return true
        end,
    },
    refreshBookRecord = function(_self, book, _old, options)
        auto_refresh = options and options.automatic and book
    end,
    showBookMenu = function(_self, book) shown_book = book end,
    getFullBookCachePath = function(_self, book) return book.full_path end,
    openFile = function(_self, path) opened_path = path end,
    confirmAndDownloadChapters = function(_self, _book, _chapters, _suffix, options)
        single_download_options = options
    end,
    showInfo = function() end,
    requireLogin = function() return true end,
    runOnlineTask = function(_self, _label, callback) callback() return true end,
    showBusy = function() end,
    closeBusy = function() end,
    client = {},
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

host:showBookRecord({ bookId = "42", title = "First open" })
expect(auto_refresh and auto_refresh.book_id == "42",
    "first open without a detail snapshot did not auto-refresh")
expect(written_book and written_book.title == "First open",
    "first-open basic metadata was not written to SQLite")

auto_refresh, shown_book = nil, nil
db_detail = { book_id = "42", title = "Cached", detail_updated_at = 123 }
host:showBookRecord({ bookId = "42", title = "Shelf title" })
expect(shown_book and not auto_refresh,
    "cached detail unexpectedly triggered an automatic refresh")

local callback_chapters
host:loadChapters({ book_id = "42", title = "Catalog" }, function(chapters)
    callback_chapters = chapters
end, true)
expect(written_chapters == fetched_chapters,
    "fetched chapter catalog was not written to SQLite")
expect(callback_chapters == fetched_chapters,
    "chapter callback did not receive the fetched catalog")

local partial = {
    book_id = "42",
    chapter_uid = 3,
    chapters = {
        { chapterUid = 1 }, { chapterUid = 2 }, { chapterUid = 3 },
        { chapterUid = 4 }, { chapterUid = 5 },
    },
    cached_chapters = { ["2"] = "/cache/2.epub", ["4"] = "/cache/4.epub" },
}
existing_paths["/cache/2.epub"] = true
existing_paths["/cache/4.epub"] = true
host:openBookForReading(partial)
expect(opened_path == "/cache/2.epub",
    "equal-distance cached chapter did not prefer the preceding chapter")

partial.chapter_uid = 4
host:openBookForReading(partial)
expect(opened_path == "/cache/4.epub",
    "exact cached progress chapter was not selected")

partial.full_path = "/cache/full.epub"
existing_paths[partial.full_path] = true
host:openBookForReading(partial)
expect(opened_path == partial.full_path,
    "complete cached book did not take priority over chapter caches")

host:downloadChapterAndRead(partial, partial.chapters[3], function()
    single_download_refreshed = true
end)
expect(single_download_options and single_download_options.single_chapter == true,
    "single chapter download keeps single-chapter mode")
single_download_options.on_complete(true, "/cache/3.epub")
expect(single_download_refreshed,
    "single chapter completion did not notify the chapter list")

print(("library_cache_flow_spec: %d checks"):format(checks))
