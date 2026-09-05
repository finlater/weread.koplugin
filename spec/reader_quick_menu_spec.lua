-- Focused tests for opening the WeRead quick menu through a reader action.

package.path = "./?.lua;" .. package.path

local dialog_options, dialog_callbacks
package.preload["weread.ui.end_of_book_dialog"] = function()
    return { show = function(options, callbacks)
        dialog_options = options
        dialog_callbacks = callbacks
    end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(book_id) return book_id == "mp-book" end }
end

local Navigation = require("weread.ui.reader_navigation")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local shown_book_id
local notice
local host = {
    detectWeReadBook = function() return "book-1" end,
    showEndOfBookDialog = function(_self, book_id)
        shown_book_id = book_id
        return true
    end,
    showTransientInfo = function(_self, text, timeout)
        notice = { text = text, timeout = timeout }
    end,
}
for key, value in pairs(Navigation) do
    if host[key] == nil then host[key] = value end
end

expect(host:onShowWeReadQuickMenu(), "quick menu opens for a WeRead document")
expect(shown_book_id == "book-1", "quick menu uses the detected WeRead book")

host.detectWeReadBook = function() return nil end
expect(host:onShowWeReadQuickMenu(),
    "quick menu opens for an unrelated local document")
expect(shown_book_id == nil,
    "quick menu keeps an empty WeRead context for a local document")

local bookshelf_opened = false
host.showBookshelf = function() bookshelf_opened = true end
expect(host:onShowWeReadBookshelf() and bookshelf_opened,
    "bookshelf gesture opens the WeRead bookshelf")

local local_bookshelf_opened, search_opened, action_stats_opened = false, false, false
host.showWereadCollection = function() local_bookshelf_opened = true end
host.showSearch = function() search_opened = true end
host.showReadStats = function() action_stats_opened = true end
expect(host:onShowWeReadLocalBookshelf() and local_bookshelf_opened,
    "local-bookshelf action opens the WeRead collection")
expect(host:onShowWeReadSearch() and search_opened,
    "search action opens WeRead search")
expect(host:onShowWeReadReadingStatistics() and action_stats_opened,
    "reading-statistics action opens WeRead statistics")

local stats_opened = false
local context_books = {}
local annotations_toggled = false
local annotation_cache = { show_annotations = true }
local context_host = {
    ui = { document = { file = "/books/local.epub" } },
    settings = {
        get = function(_self, key, default)
            if key == "books" then return context_books end
            if key == "cache" then return annotation_cache end
            return default
        end,
    },
    showTransientInfo = function(_self, text, timeout)
        notice = { text = text, timeout = timeout }
    end,
    showBookshelf = function() end,
    showSearch = function() end,
    showReadStats = function() stats_opened = true end,
    toggleAnnotationVisibility = function() annotations_toggled = true end,
    _annotationsVisibleForCurrentDocument = function() return false end,
}
for key, value in pairs(Navigation) do
    if context_host[key] == nil then context_host[key] = value end
end

expect(context_host:showEndOfBookDialog(nil),
    "global quick menu builds without a WeRead book")
expect(dialog_options.show_chapter_nav and dialog_options.show_next_chapter
        and dialog_options.enable_chapter_list == false
        and dialog_options.enable_next_chapter == false
        and dialog_options.enable_book_details == false
        and dialog_options.enable_sync_progress == false
        and dialog_options.annotations_visible == true,
    "quick menu reflects the global annotation visibility preference")
annotation_cache.show_annotations = false
expect(context_host:showEndOfBookDialog(nil)
        and dialog_options.annotations_visible == false,
    "quick menu hides annotations when the global preference is disabled")
annotation_cache.show_annotations = true
dialog_callbacks.on_chapter_list()
expect(notice and notice.timeout == 1,
    "context-dependent action explains why it is unavailable")
dialog_callbacks.on_read_stats()
expect(stats_opened,
    "reading statistics remains available for local documents")
dialog_callbacks.on_toggle_annotations()
expect(annotations_toggled,
    "quick menu annotation button delegates to the shared visibility toggle")

context_books["mp-book"] = { book_id = "mp-book", title = "Article" }
context_host.ensureChaptersLoaded = function()
    error("public account quick menu must not load regular book chapters")
end
expect(context_host:showEndOfBookDialog("mp-book"),
    "quick menu opens for a public account article")
expect(dialog_options.enable_book_details == true
        and dialog_options.enable_chapter_list == false
        and dialog_options.enable_next_chapter == false
        and dialog_options.enable_sync_progress == false,
    "public account articles only enable supported contextual actions")
notice = nil
dialog_callbacks.on_sync_progress()
expect(notice and notice.timeout == 1,
    "public account article explains that progress sync needs a regular book")

print(string.format(
    "reader_quick_menu_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
