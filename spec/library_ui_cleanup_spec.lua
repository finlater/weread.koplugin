-- Opening a document from the bookshelf must dismiss every full-screen
-- WeRead UI (bookshelf, book details, chapter list). KOReader only tears
-- down once its window stack is empty, so a leftover shelf view would block
-- quitting until the user manually closes it (reported on Kindle).

package.path = "./?.lua;" .. package.path

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
package.preload["weread.lib.content"] = empty_module
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
        file_exists = function() return false end,
    }
end

local closed_widgets = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
        close = function(_self, widget)
            closed_widgets[#closed_widgets + 1] = widget
        end,
    }
end

local Library = require("weread.ui.library")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local opened_path
local switched_path
local host = {
    settings = {
        get = function() return {} end,
        set = function() end,
        flush = function() end,
    },
    library_db = {},
    client = {},
    showInfo = function() end,
    requireLogin = function() return true end,
    showBusy = function() end,
    closeBusy = function() end,
    refreshUI = function() end,
    ui = {
        document = nil,
        openFile = function(_self, path) opened_path = path end,
        switchDocument = function(_self, path) switched_path = path end,
    },
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

-- Case 1: a fresh file-manager open has no WeRead UI to dismiss.
closed_widgets = {}
host.shelf_view = nil
host._book_detail_view = nil
host._chapter_list_view = nil
host:openFile("/mnt/base-us/koreader/weread/books/42.epub")
expect(#closed_widgets == 0, "openFile closed widgets when no WeRead UI was open")
expect(opened_path == "/mnt/base-us/koreader/weread/books/42.epub",
    "openFile did not delegate to ui:openFile")
expect(switched_path == nil, "openFile wrongly used switchDocument without a document")

-- Case 2: bookshelf + book details + chapter list are all dismissed.
closed_widgets = {}
local shelf_view = { name = "shelf" }
local detail_view = { name = "detail" }
local chapter_view = { name = "chapters" }
host.shelf_view = shelf_view
host._book_detail_view = detail_view
host._chapter_list_view = chapter_view
opened_path = nil
host:openFile("/mnt/base-us/koreader/weread/books/42.epub")
expect(#closed_widgets == 3,
    "openFile did not close all three WeRead UIs (closed " .. #closed_widgets .. ")")
expect(closed_widgets[1] == shelf_view, "bookshelf view was not closed first")
expect(closed_widgets[2] == detail_view, "book detail view was not closed")
expect(closed_widgets[3] == chapter_view, "chapter list view was not closed")
expect(host.shelf_view == nil, "shelf_view reference was not cleared")
expect(host._book_detail_view == nil, "_book_detail_view reference was not cleared")
expect(host._chapter_list_view == nil, "_chapter_list_view reference was not cleared")
expect(opened_path == "/mnt/base-us/koreader/weread/books/42.epub",
    "openFile did not open the document after dismissing WeRead UI")

-- Case 3: with an existing reader document, switchDocument is used and the
-- (already dismissed) WeRead fields stay nil.
closed_widgets = {}
host.ui.document = { file = "/mnt/base-us/koreader/weread/books/42.epub" }
host.shelf_view = nil
host._book_detail_view = nil
host._chapter_list_view = nil
opened_path = nil
host:openFile("/mnt/base-us/koreader/weread/books/43.epub")
expect(switched_path == "/mnt/base-us/koreader/weread/books/43.epub",
    "openFile did not switch the document in reader context")
expect(opened_path == nil, "openFile wrongly delegated to ui:openFile in reader context")
expect(#closed_widgets == 0, "openFile closed widgets in reader context with none open")

print("library_ui_cleanup_spec: " .. checks .. " checks, 0 failure(s)")
