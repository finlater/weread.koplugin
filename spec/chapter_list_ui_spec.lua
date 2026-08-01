-- Focused tests for paginated chapter actions and visible multi-selection state.

package.path = "./?.lua;" .. package.path

local function empty_module() return {} end
local catalog_view_data
local catalog_view_callbacks
package.preload["weread.ui.chapter_list_view"] = function()
    return {
        show = function(data, callbacks)
            catalog_view_data = data
            catalog_view_callbacks = callbacks
            return {}
        end,
    }
end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = empty_module
package.preload["ui/widget/confirmbox"] = empty_module
package.preload["weread.lib.content"] = empty_module
package.preload["ui/widget/infomessage"] = empty_module
package.preload["ui/widget/inputdialog"] = empty_module
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["ui/widget/progressbardialog"] = empty_module
package.preload["ui/widget/textviewer"] = empty_module
package.preload["weread.lib.protocol"] = empty_module

local closed = 0
local existing_files = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
        close = function() closed = closed + 1 end,
    }
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
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path) return existing_files[path] == true end,
    }
end

G_reader_settings = {
    readSetting = function(_self, key)
        return key == "items_per_page" and 5 or nil
    end,
}

local Library = require("weread.ui.library")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local chapters = {}
for index = 1, 7 do
    chapters[index] = {
        chapterUid = index,
        title = "Chapter " .. tostring(index),
        wordCount = index * 100,
    }
end

local shown = {}
local fake_menu = {
    updateItems = function() end,
    switchItemTable = function() end,
}
local downloaded_options
local returned_to_parent = false
local opened_chapter
local single_chapter_refresh
local host = {
    safeCallback = function(_self, _label, callback) return callback end,
    loadChapters = function(_self, _book, callback) callback(chapters) end,
    showList = function(_self, title, items, _empty, options)
        shown[#shown + 1] = { title = title, items = items, options = options }
        return fake_menu
    end,
    confirmAndDownloadChapters = function(_self, _book, _targets, _suffix, options)
        downloaded_options = options
    end,
    showTransientInfo = function() end,
    openChapter = function(_self, _book, chapter, on_downloaded)
        opened_chapter = chapter
        single_chapter_refresh = on_downloaded
    end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

local persisted_books = {}
host.settings = {
    get = function(_self, key, default)
        if key == "books" then return persisted_books end
        return default
    end,
}
local book = { bookId = "book-1", title = "Book", cached_chapters = {} }
host:showChapterList(book)
expect(catalog_view_data.title == "Book" and #catalog_view_data.chapters == 7,
    "chapter catalog view receives the title and all chapters")
expect(catalog_view_data.chapters[1].status == "100 words",
    "chapter catalog preserves the right-side word-count status")
expect(type(catalog_view_callbacks.on_refresh) == "function"
    and type(catalog_view_callbacks.on_select_download) == "function",
    "chapter catalog keeps refresh and multi-download actions")
catalog_view_callbacks.on_select(chapters[1])
expect(opened_chapter == chapters[1], "chapter row opens the selected chapter")
expect(type(single_chapter_refresh) == "function",
    "chapter row passes a post-download refresh callback")

host:showChapterDownloadSelection(book, chapters, function()
    returned_to_parent = true
    host:showChapterList(book)
end)
local selection_menu = shown[1]
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (0)",
    "selection page starts with a distinct download action")
expect(selection_menu.items[6].text_func() == "[Download] Selected chapters (0)",
    "download action repeats at the top of the second page")

selection_menu.items[2].callback()
expect(selection_menu.items[2].text_func():find("[✓]", 1, true) == 1,
    "selected chapter gets an explicit visible marker")
expect(selection_menu.items[2].mandatory_func() == "Selected",
    "selected chapter gets a visible right-side status")
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (1)",
    "download action count updates after selection")

selection_menu.items[2].callback()
expect(selection_menu.items[2].text_func():find("[  ]", 1, true) == 1,
    "tapping a selected chapter removes its marker")
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (0)",
    "download action count decreases after deselection")
selection_menu.items[2].callback()

selection_menu.items[1].callback()
expect(downloaded_options and downloaded_options.separate_chapters == true,
    "multi-selection starts a separate-chapter download")
expect(downloaded_options.offer_read == nil,
    "multi-selection preserves the read-after-download prompt")
existing_files["/cache/chapter-1.epub"] = true
persisted_books["book-1"] = {
    cached_chapters = { ["1"] = "/cache/chapter-1.epub" },
}
downloaded_options.on_complete(true)
expect(closed == 1 and returned_to_parent,
    "successful multi-download closes selection and returns to parent list")
expect(catalog_view_data.chapters[1].status == "Cached",
    "successful multi-download refreshes cached chapter status")

print(string.format(
    "chapter_list_ui_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
