package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local kindle = true
package.preload["device"] = function()
    return { isKindle = function() return kindle end }
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
local host = {
    shelf_regular = shelf,
    shelf_mp = {},
    settings = {
        get = function(_self, key, default)
            if key == "books" then return {} end
            if key == "shelf" then return { sort_order = "time_desc" } end
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
expect(shown[1].data.paged == true, "Kindle bookshelf did not enable pagination")
expect(shown[1].data.page_size == 10, "Kindle bookshelf used the wrong page size")
expect(#shown[1].data.books == 1000, "pagination discarded full shelf search data")

local prepared_books = shown[1].data.books
shown[1].callbacks.on_page_changed(7)
expect(shown[2].data.page == 7, "Kindle page change was not retained")
expect(shown[2].data.books == prepared_books,
    "Kindle page change recomputed the prepared bookshelf")

kindle = false
host:showShelfView("books", nil, shown[2], {})
expect(shown[3].data.paged == false,
    "non-Kindle bookshelf unexpectedly enabled pagination")

print(("kindle_bookshelf_pagination_spec: %d checks"):format(checks))
