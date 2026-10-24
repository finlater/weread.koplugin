package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local dialogs = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, dialog) dialogs[#dialogs + 1] = dialog end,
        close = function() end,
        nextTick = function(_self, callback) callback() end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
local subprocess_runs, subprocess_payload = 0, nil
package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function(callback)
            subprocess_runs = subprocess_runs + 1
            callback(100 + subprocess_runs, 200 + subprocess_runs)
            return 100 + subprocess_runs, 200 + subprocess_runs
        end,
        writeToFD = function(_fd, data) subprocess_payload = data return true end,
        isSubProcessDone = function() return true end,
        terminateSubProcess = function() end,
        readAllFromFD = function() local data = subprocess_payload subprocess_payload = nil return data end,
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
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, data)
        data.movable = { {} }
        return data
    end }
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
    sourcePathFor = function() return nil end,
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
    return { is_mp_book = function(id) return tostring(id):match("^MP_WXS_") ~= nil end }
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
        getLayout = function(cover)
            if cover then
                return require("weread.lib.cover_layout").calculate{ width = 600, height = 800, reserved_height = 127 }
            end
            return { page_size = 10 }
        end,
        show = function(data, callbacks)
            shown[#shown + 1] = { data = data, callbacks = callbacks }
            local source = data.mode == "public_account" and data.accounts or data.books
            local page_count = math.max(1, math.ceil(#source / data.page_size))
            local page = math.max(1, math.min(data.page or 1, page_count))
            return { page = page, page_count = page_count, page_size = data.page_size,
                on_refresh = callbacks.on_refresh,
                setRefreshing = function(self, busy) self.refreshing = busy end,
                getScrollOffset = function() return { x = 0, y = 125 } end,
            }
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
    settings = require("spec.helpers.book_settings").install({
        set = function() end, flush = function() end,
        get = function(_self, key, default)
            if key == "shelf" then return shelf_settings end
            return default
        end,
    }, {}),
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
host.shelf_mp = {
    { bookId = "MP_WXS_1", title = "Account 1", cover = "http://wx.qlogo.cn/avatar-1" },
    { bookId = "MP_WXS_2", title = "Account 2", cover = "http://wx.qlogo.cn/avatar-2" },
}
host:showShelfView("books", nil, shown[6], {})
expect(shown[7].data.cover_mode == true and shown[7].data.paged == true,
    "cover view did not enforce lightweight page rendering")
expect(shown[7].data.page_size == 9,
    "cover view did not limit the current page to nine books")
host:showShelfView("public_account", nil, shown[7], {})
expect(shown[8].data.cover_mode == true and shown[8].data.paged == true
        and shown[8].data.page_size == 9,
    "public-account shelf did not adopt the shared cover preference")

local cover_requests = {}
for index = 1, 12 do shelf[index].cover = "https://cdn.example/" .. tostring(index) end
host.isNetworkOnline = function() return true end
host.client = {
    get_binary = function(_self, url, options)
        cover_requests[#cover_requests + 1] = { url = url, options = options }
        return "\255\216\255cover"
    end,
}
cover_path_lookups = 0
host:showShelfView("books", nil, shown[8], {})
expect(shown[9].data.cover_loading[shelf[1]] == true,
    "uncached online cover did not show its loading state")
expect(#cover_requests == 9,
    "cover view fetched books outside the current nine-item page: "
        .. tostring(#cover_requests) .. " lookups=" .. tostring(cover_path_lookups)
        .. " page=" .. tostring(shown[9] and shown[9].data.page))
expect(subprocess_runs == 9,
    "cover network and thumbnail work did not run in background subprocesses")
expect(cover_requests[1].options.skip_cookie == true
        and cover_requests[1].options.persist_response_cookies == false,
    "public cover request did not suppress account credentials")
expect(#shown == 10 and shown[10].data.cover_paths[shelf[1]] ~= nil,
    "cover batch did not refresh the page once with cached paths")
expect(shown[10].data.cover_loading[shelf[1]] ~= true,
    "cached cover incorrectly remained in its loading state")

local requests_before_unsafe_url = #cover_requests
local unsafe_view = { page = 1 }
host.shelf_view = unsafe_view
host.shelf_cover_generation = host.shelf_cover_generation + 1
host:fetchVisibleShelfCovers(unsafe_view, {
    { bookId = "unsafe", cover = "file:///private/cover.jpg" },
}, {})
expect(#cover_requests == requests_before_unsafe_url,
    "cover loader accepted a non-HTTPS cover source")

local requests_before_qlogo = #cover_requests
local qlogo_view = { page = 1, page_size = 1 }
host.shelf_view = qlogo_view
host.shelf_cover_generation = host.shelf_cover_generation + 1
host:fetchVisibleShelfCovers(qlogo_view, {
    { bookId = "MP_WXS_avatar", cover = "http://wx.qlogo.cn/avatar" },
}, {})
expect(#cover_requests == requests_before_qlogo + 1
        and cover_requests[#cover_requests].url == "https://wx.qlogo.cn/avatar",
    "public-account avatar cover was not upgraded to HTTPS and fetched")

-- Groups are projected once per snapshot and share the existing shelf records.
local grouped_books = {}
for index = 1, 30 do grouped_books[index] = { bookId = tostring(index), title = "Group book " .. index } end
local membership = {}
for index = 1, 20 do membership[index] = tostring(index) end
local archives = {
    { archiveId = 7, name = "History", bookIds = membership },
    { archiveId = 8, name = "Empty", bookIds = {} },
    { archiveId = 9, name = "Accounts", bookIds = { "MP_WXS_1" } },
}
shelf_settings.view_mode = "list"
shelf_settings.paginated = true
host.isNetworkOnline = function() return false end
host:applyShelfSnapshot(grouped_books, archives)
host:showShelfView("books")
local groups = host.shelf_groups
expect(#groups == 3 and groups[1].books[1] == grouped_books[1],
    "snapshot groups were not projected onto the shared book records")
shown[#shown].callbacks.on_select_group("archive:7")
expect(shown[#shown].data.mode == "books" and #shown[#shown].data.books == 20
        and shown[#shown].data.group_label == "History", "group created a separate content mode")
shown[#shown].callbacks.on_page_changed(2)
expect(host.shelf_groups == groups and shown[#shown].data.page == 2,
    "paging rebuilt groups or lost the selected page")
shown[#shown].callbacks.on_switch("public_account")
shown[#shown].callbacks.on_switch("books")
expect(shown[#shown].data.group_key == "archive:7" and shown[#shown].data.page == 2,
    "switching content type discarded the book group or page")
shown[#shown].callbacks.on_select_group("archive:8")
expect(#shown[#shown].data.books == 0, "empty group fell back to the entire shelf")
shown[#shown].callbacks.on_select_group("__ungrouped__")
expect(#shown[#shown].data.books == 10, "uncategorized group has wrong membership")
shown[#shown].callbacks.on_select_group("archive:7")
for index = 1, 12 do grouped_books[index].cover = "https://cdn.example/group-" .. index end
host.isNetworkOnline = function() return true end
shown[#shown].callbacks.on_display_change("view_mode", "cover")
expect(shown[#shown].data.cover_mode and shown[#shown].data.group_key == "archive:7",
    "display mode change discarded the group")
host.isNetworkOnline = function() return false end
shown[#shown].callbacks.on_display_change("view_mode", "list")
shown[#shown].callbacks.on_page_changed(2)

local pending, fetches, written_archives
host.requireLogin = function() return true end
host.showBusy = function() end
host.closeBusy = function() end
host.showInfo = function() end
host.runOnlineTask = function(_self, _label, callback) pending = callback return true end
host.client.get_shelf = function()
    fetches = (fetches or 0) + 1
    return { books = grouped_books, archive = { archives[2], archives[1] } }
end
host.library_db = { cacheShelf = function(_self, _books, value) written_archives = value end }
local before_refresh = shown[#shown]
local cover_generation = host.shelf_cover_generation
host.shelf_cover_pending = { view = host.shelf_view }
before_refresh.callbacks.on_refresh()
before_refresh.callbacks.on_refresh()
expect(host.shelf_refreshing and fetches == nil, "refresh was not scheduled or guarded")
expect(host.shelf_cover_generation > cover_generation and host.shelf_cover_pending == nil,
    "refresh left a thumbnail batch able to replace the view")
pending()
expect(fetches == 1 and written_archives[2].archiveId == 7 and not host.shelf_refreshing,
    "refresh duplicated requests or omitted archive caching")
expect(shown[#shown].data.page == 2 and shown[#shown].data.group_key == "archive:7"
        and shown[#shown].data.scroll_offset.y == 125,
    "refresh lost group, page or scroll position after archive reorder")

host.client.get_shelf = function() return { books = grouped_books, archive = {} } end
shown[#shown].callbacks.on_refresh()
pending()
expect(shown[#shown].data.group_key == nil and shown[#shown].data.page == 1
        and #shown[#shown].data.books == 30, "deleted group did not fall back to all books")
host.runOnlineTask = function() return false end
shown[#shown].callbacks.on_refresh()
expect(not host.shelf_refreshing, "offline refresh stayed locked")
host.runOnlineTask = function(_self, _label, callback) callback() return true end
host.client.get_shelf = function() error("fixture") end
local before_failure = #shown
shown[#shown].callbacks.on_refresh()
expect(#shown == before_failure and not host.shelf_refreshing, "failed refresh replaced the shelf or stayed locked")
host.library_db.getShelf = function() return grouped_books end
host.library_db.getShelfArchives = function() return archives end
host:showBookshelf()
expect(#host.shelf_groups == 3, "cached opening lost archive data")
expect(#dialogs == 0, "current group cache triggered the upgrade hint")
host.library_db.getShelfArchives = function() return {} end
host:showBookshelf()
expect(#dialogs == 0, "synced shelf without groups triggered the upgrade hint")
host.library_db.getShelfArchives = function() return nil end
host:showBookshelf()
expect(#dialogs == 1 and shelf_settings.groups_refresh_hint_shown,
    "old shelf cache did not show and remember the one-time upgrade hint")
local hinted_view = host.shelf_view
local saved_refresh = host.refreshBookshelf
local refreshed_view
host.refreshBookshelf = function(_self, view) refreshed_view = view end
dialogs[1].ok_callback()
expect(refreshed_view == hinted_view, "upgrade hint did not refresh the visible shelf")
host.refreshBookshelf = saved_refresh
host:showBookshelf()
expect(#dialogs == 1, "old shelf cache repeated the upgrade hint before a refresh")
host.shelf_group_key = "archive:7"
host:onWeReadAccountChanged()
expect(host.shelf_groups == nil and host.shelf_group_key == nil, "account switch retained old groups")

print(("bookshelf_pagination_spec: %d checks"):format(checks))
