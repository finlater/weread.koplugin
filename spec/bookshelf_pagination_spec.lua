package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["ui/uimanager"] = function()
    return {
        close = function() end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_self, value) return value end,
        },
    }
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
local cached_covers = {}
local cover_path_lookups = 0
local fake_cover_cache = {
    pathFor = function(_self, book)
        cover_path_lookups = cover_path_lookups + 1
        return cached_covers[book]
    end,
    store = function(_self, book)
        cached_covers[book] = "/covers/" .. tostring(book.bookId) .. ".jpg"
        return cached_covers[book]
    end,
    prune = function() return 0 end,
}
package.preload["weread.lib.cover_cache"] = function()
    return {
        new = function() return fake_cover_cache end,
    }
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
            local source = data.mode == "public_account" and data.accounts or data.books
            local page_count = math.max(1, math.ceil(#source / data.page_size))
            local page = math.max(1, math.min(data.page or 1, page_count))
            return { page = page, page_count = page_count }
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
local shelf_settings = { sort_order = "time_desc", paginated = true, view_mode = "list" }
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
    isNetworkOnline = function() return false end,
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

host.shelf_view_pages.books = 7
host.bookMatchesFilters = function() return false end
host.showShelfFilterOptions = function(_self, callback) callback() end
shown[5].callbacks.on_filter()
expect(#shown[6].data.books == 0 and shown[6].data.paged == true,
    "bookshelf filter did not preserve an empty paged result")
expect(shown[6].data.page == 1 and host.shelf_view_pages.books == 1,
    "empty filtered bookshelf did not reset and clamp to page one")

shelf_settings.view_mode = "cover"
shelf_settings.paginated = false
shelf_settings.sort_order = "default"
host.bookMatchesFilters = function() return true end
host.shelf_regular = shelf
host:showShelfView("books", nil, shown[6], {})
expect(shown[7].data.cover_mode == true and shown[7].data.paged == true,
    "cover view did not enforce lightweight page rendering")
expect(shown[7].data.page_size == 6,
    "cover view did not limit the current page to six books")
host:showShelfView("public_account", nil, shown[7], {})
expect(shown[8].data.cover_mode == false and shown[8].data.paged == false,
    "cover preference changed the public-account list")

local cover_requests = {}
for index = 1, 8 do shelf[index].cover = "https://cdn.example/" .. tostring(index) end
host.isNetworkOnline = function() return true end
host.client = {
    get_binary = function(_self, url, options)
        cover_requests[#cover_requests + 1] = { url = url, options = options }
        return "\255\216\255cover"
    end,
}
cover_path_lookups = 0
host:showShelfView("books", nil, shown[8], {})
expect(#cover_requests == 6,
    "cover view fetched books outside the current six-item page: "
        .. tostring(#cover_requests) .. " lookups=" .. tostring(cover_path_lookups)
        .. " page=" .. tostring(shown[9] and shown[9].data.page))
expect(cover_requests[1].options.skip_cookie == true
        and cover_requests[1].options.persist_response_cookies == false,
    "public cover request did not suppress account credentials")
expect(#shown == 10 and shown[10].data.cover_paths[shelf[1]] ~= nil,
    "cover batch did not refresh the page once with cached paths")

local requests_before_unsafe_url = #cover_requests
local unsafe_view = { page = 1 }
host.shelf_view = unsafe_view
host.shelf_cover_generation = host.shelf_cover_generation + 1
host:fetchVisibleShelfCovers(unsafe_view, {
    { bookId = "unsafe", cover = "file:///private/cover.jpg" },
}, {})
expect(#cover_requests == requests_before_unsafe_url,
    "cover loader accepted a non-HTTPS cover source")

print(("bookshelf_pagination_spec: %d checks"):format(checks))
