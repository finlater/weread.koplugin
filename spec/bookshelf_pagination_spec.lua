package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["ui/uimanager"] = function()
    return { close = function() end }
end
for _, name in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/inputdialog",
    "ui/widget/progressbardialog", "ui/widget/textviewer",
}) do
    package.preload[name] = function() return {} end
end
package.preload["weread.lib.book_reviews"] = function() return {} end
package.preload["weread.ui.book_reviews_view"] = function() return {} end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    }
end

local shown = {}
package.preload["weread.ui.library_view"] = function()
    return {
        show = function(data, callbacks)
            shown[#shown + 1] = { data = data, callbacks = callbacks }
            return { page = data.page }
        end,
    }
end

G_reader_settings = {
    readSetting = function(_self, key)
        return key == "items_per_page" and 14 or nil
    end,
}

local Library = require("weread.ui.library")
local shelf = {}
for index = 1, 1000 do
    shelf[index] = { bookId = tostring(index), title = "Book " .. tostring(index) }
end
local shelf_settings = { sort_order = "time_desc", paginated = true }
local host = {
    shelf_regular = shelf,
    shelf_mp = {},
    settings = {
        get = function(_self, key, default)
            if key == "books" then return {} end
            if key == "shelf" then return shelf_settings end
            return default
        end,
    },
    bookMatchesFilters = function() return true end,
    isBookDownloaded = function() return false end,
    shelfSortSummary = function() return "Recent" end,
    shelfFilterSummary = function() return "All" end,
    showShelfSortOptions = function() end,
    showShelfFilterOptions = function() end,
    safeCallback = function(_self, _label, callback) return callback end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

host:showShelfView("books", nil, nil, {})
expect(shown[1].data.paged == true, "bookshelf did not enable pagination by default")
expect(shown[1].data.page_size == 10, "bookshelf used the wrong page size")
expect(#shown[1].data.books == 1000, "pagination discarded full shelf search data")

local prepared_books = shown[1].data.books
shown[1].callbacks.on_page_changed(7)
expect(shown[2].data.page == 7, "bookshelf page change was not retained")
expect(shown[2].data.books == prepared_books,
    "page change recomputed the prepared bookshelf")

shelf_settings.paginated = false
host:showShelfView("books", nil, shown[2], {})
expect(shown[3].data.paged == false,
    "bookshelf ignored the continuous-scroll preference")

shelf_settings.paginated = true
shelf_settings.sort_order = "name_asc"
host.shelf_regular = {
    { bookId = "z", title = "Zulu", visible = true },
    { bookId = "b", title = "Beta", visible = false },
    { bookId = "a", title = "Alpha", visible = true },
}
host.bookMatchesFilters = function(_self, book) return book.visible end
host:showShelfView("books", nil, shown[3], {})
expect(#shown[4].data.books == 2
        and shown[4].data.books[1].title == "Alpha"
        and shown[4].data.books[2].title == "Zulu",
    "bookshelf did not filter and sort the full result before pagination")
host:showShelfView("books", "zul", shown[4], {})
expect(#shown[5].data.books == 1 and shown[5].data.books[1].title == "Zulu",
    "bookshelf search did not run over the full filtered shelf")

print(("bookshelf_pagination_spec: %d checks"):format(checks))
