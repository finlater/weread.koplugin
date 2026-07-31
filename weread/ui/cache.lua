-- Cache settings, directory selection, scanning, and cleanup UI.
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Content = require("weread.lib.content")
local logger = require("weread.lib.logger")
local PathChooser = require("ui/widget/pathchooser")
local Scan = require("weread.lib.scan")
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")
local ReadCollection = require("readcollection")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists

local M = {}

function M:setMPImageDownload(enabled)
    local cache = self.settings:get("cache")
    cache.download_mp_images = enabled == true
    self.settings:set("cache", cache)
    self.settings:flush()
    logger.info(
        "image download setting changed:",
        "target=mp",
        "enabled=", tostring(cache.download_mp_images)
    )
end

-- Returns true if the directory is usable (creatable and writable), else false + message.
function M:validateDownloadDir(path)
    local lfs = require("libs/libkoreader-lfs")
    if type(path) ~= "string" or path == "" then
        return false, _("Invalid path.")
    end
    if not lfs.attributes(path, "mode") then
        os.execute("mkdir -p " .. string.format("%q", path))
        if not lfs.attributes(path, "mode") then
            return false, _("Directory does not exist and could not be created.")
        end
    end
    local test_file = path .. "/.weread_write_test"
    local f = io.open(test_file, "w")
    if not f then
        return false, _("Directory is not writable.")
    end
    f:close()
    os.remove(test_file)
    return true
end

function M:showDownloadDirPicker(touchmenu_instance)
    local current = self.settings:get_download_dir()
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = current,
        onConfirm = function(path)
            local ok, err = self:validateDownloadDir(path)
            if not ok then
                self:showInfo(T(_("Cannot use this directory: %1"), err))
                return
            end
            local old_dir = self.settings:get_download_dir()
            self.settings:set_download_dir(path)
            logger.info("download directory changed:", path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            self:offerMoveBooksToNewDir(old_dir, path)
        end,
    }
    UIManager:show(path_chooser)
end

-- After the download directory changes, offer to move already-cached books from
-- their old locations into the new directory. Without this, old files stay behind
-- as orphans (still reachable via the stored paths, but not under the new root).
function M:offerMoveBooksToNewDir(old_dir, new_dir)
    if old_dir == new_dir then
        self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1"), new_dir))
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local movable = {}
    for book_id, book in pairs(books) do
        local src = Content.book_resolved_dir(self.settings, book_id, book)
        local dst = Content.book_cache_dir(self.settings, book_id)
        if src ~= dst then
            local attr = lfs.attributes(src)
            if attr and attr.mode == "directory" then
                table.insert(movable, { book_id = book_id, src = src, dst = dst })
            end
        end
    end
    if #movable == 0 then
        self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1"), new_dir))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Download directory changed. Move %1 cached book(s) to the new location?"), tostring(#movable)),
        ok_text = _("Move"),
        ok_callback = function()
            self:moveBooksToNewDir(movable, new_dir)
        end,
        cancel_text = _("Keep"),
        cancel_callback = function()
            self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1\nExisting downloads stay in the old location."), new_dir))
        end,
    })
end

function M:moveBooksToNewDir(movable, new_dir)
    self:showBusy(_("Moving cached books..."))
    UIManager:scheduleIn(0.1, function()
        local books = self.settings:get("books", {})
        local moved, skipped, failed = 0, 0, 0
        for _i, m in ipairs(movable) do
            local ok, reason = self:moveBookDir(m.src, m.dst)
            if ok then
                local book = books[m.book_id]
                if book then
                    book.cache_dir = m.dst
                    book.cached_file = self:remapCachedPath(book.cached_file, m.dst)
                    book.cached_full_book = self:remapCachedPath(
                        book.cached_full_book, m.dst)
                    if type(book.cached_chapters) == "table" then
                        for uid, path in pairs(book.cached_chapters) do
                            book.cached_chapters[uid] = self:remapCachedPath(path, m.dst)
                        end
                    end
                end
                moved = moved + 1
            elseif reason == "target_exists" then
                skipped = skipped + 1
                logger.warn("skip move, target exists:", m.dst)
            else
                failed = failed + 1
                logger.err("move book cache failed:", m.src, "->", m.dst)
            end
        end
        self.settings:set("books", books)
        self.settings:flush()
        self:closeBusy()
        local message
        if skipped == 0 and failed == 0 then
            message = T(_("Moved %1 book(s) to:\n%2"), tostring(moved), new_dir)
        else
            message = T(_("Moved %1 book(s). %2 skipped (target already exists), %3 failed. These stay in the old location."), tostring(moved), tostring(skipped), tostring(failed))
        end
        self:offerScanNewDir(new_dir, message)
    end)
end

-- Move one book directory to dst. Uses `mv`, which (unlike os.rename) handles
-- moves across filesystems, e.g. internal storage to an SD card. Returns
-- true on success, or false plus a reason ("target_exists" / "move_failed").
function M:moveBookDir(src, dst)
    if src == dst then
        return true
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dst) then
        -- The target already exists. Since the new directory is user-selected, it
        -- may be unrelated user data that only happens to share the sanitized name.
        -- Never delete it; leave the book in its old location instead.
        return false, "target_exists"
    end
    local parent = dst:match("^(.*)/[^/]+$")
    if parent then
        os.execute("mkdir -p " .. string.format("%q", parent))
    end
    local status = os.execute("mv -f " .. string.format("%q", src) .. " " .. string.format("%q", dst))
    if status == true or status == 0 then
        return true
    end
    return false, "move_failed"
end

-- Rewrite a stored absolute file path to sit under the new book directory,
-- keeping the original filename.
function M:remapCachedPath(path, dst)
    if type(path) ~= "string" then
        return path
    end
    local name = path:match("[^/]+$")
    if not name then
        return path
    end
    return dst .. "/" .. name
end

local SHELF_SORT_OPTIONS = {
    { key = "time_desc", label = _("Last read time (newest first)") },
    { key = "time_asc",  label = _("Last read time (oldest first)") },
    { key = "default",   label = _("Default order") },
    { key = "name_asc",  label = _("Title A-Z") },
    { key = "name_desc", label = _("Title Z-A") },
}

local function shelfSortLabel(sort_key)
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        if opt.key == sort_key then
            return opt.label
        end
    end
    return SHELF_SORT_OPTIONS[1].label
end

local SHELF_FILTER_OPTIONS = {
    { dim = "reading",  value = "finished",       label = _("Only show finished books"),       short = _("Finished") },
    { dim = "reading",  value = "unfinished",     label = _("Only show unfinished books"),     short = _("Unfinished") },
    { dim = "download", value = "downloaded",     label = _("Only show downloaded books"),     short = _("Downloaded") },
    { dim = "download", value = "not_downloaded", label = _("Only show not-downloaded books"), short = _("Not downloaded") },
}

function M:shelfFilterSummary()
    local filters = self.shelf_filters
    local parts = {}
    for _i, opt in ipairs(SHELF_FILTER_OPTIONS) do
        if filters[opt.dim] == opt.value then
            table.insert(parts, opt.short)
        end
    end
    if #parts == 0 then
        return _("All")
    end
    return table.concat(parts, " / ")
end

function M:saveShelfFilters()
    local shelf = self.settings:get("shelf")
    shelf.filter_reading = self.shelf_filters.reading
    shelf.filter_download = self.shelf_filters.download
    self.settings:set("shelf", shelf)
    self.settings:flush()
end

function M:bookMatchesFilters(book, saved_books, downloaded_cache)
    local filters = self.shelf_filters or {}
    if filters.reading == "finished" and book.finishReading ~= 1 then return false end
    if filters.reading == "unfinished" and book.finishReading == 1 then return false end
    if filters.download then
        local is_downloaded = self:isBookDownloaded(book, saved_books, downloaded_cache)
        if filters.download == "downloaded" and not is_downloaded then return false end
        if filters.download == "not_downloaded" and is_downloaded then return false end
    end
    return true
end

function M:showShelfSortOptions(on_sorted)
    local dialog
    local current_sort = self.settings:get("shelf").sort_order or "default"
    local buttons = {}
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        table.insert(buttons, {
            {
                text = opt.label,
                checked_func = function()
                    return opt.key == current_sort
                end,
                -- Defer close+refresh so Button's post-tap checkmark repaint runs
                -- against the still-shown dialog (avoids a ghost label on close).
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        local shelf = self.settings:get("shelf")
                        shelf.sort_order = opt.key
                        self.settings:set("shelf", shelf)
                        self.settings:flush()
                        on_sorted()
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Sort by"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M:showShelfFilterOptions(on_changed)
    local dialog
    local filters = self.shelf_filters
    local buttons = {
        {
            {
                text = _("All"),
                checked_func = function()
                    return filters.reading == nil and filters.download == nil
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        filters.reading = nil
                        filters.download = nil
                        self:saveShelfFilters()
                        on_changed()
                    end)
                end,
            },
        },
    }
    for _i, opt in ipairs(SHELF_FILTER_OPTIONS) do
        table.insert(buttons, {
            {
                text = opt.label,
                checked_func = function()
                    return filters[opt.dim] == opt.value
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        -- Toggle within the dimension: re-tapping clears it, else select.
                        filters[opt.dim] = (filters[opt.dim] == opt.value) and nil or opt.value
                        self:saveShelfFilters()
                        on_changed()
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Filter by"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M:bookRecordHasDownload(record)
    if type(record) ~= "table" then return false end
    if file_exists(record.cached_full_book) or file_exists(record.cached_file) then
        return true
    end
    for _uid, path in pairs(record.cached_chapters or {}) do
        if file_exists(path) then return true end
    end
    return false
end

function M:isBookDownloaded(book, saved_books, downloaded_cache)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return false
    end
    if downloaded_cache and downloaded_cache[book_id] ~= nil then
        return downloaded_cache[book_id]
    end
    local record = (saved_books or self.settings:get("books", {}))[book_id]
    local is_downloaded = self:bookRecordHasDownload(record)
    if downloaded_cache then
        downloaded_cache[book_id] = is_downloaded
    end
    return is_downloaded
end

function M:shelfToolbarItems(with_filters, refresh)
    local sort_order = self.settings:get("shelf").sort_order
    local items = {
        {
            text = _("Sort"),
            mandatory = T(_("%1 \u{25BE}"), shelfSortLabel(sort_order)),
            callback = self:safeCallback(_("Sort"), function()
                self:showShelfSortOptions(refresh)
            end),
        },
    }
    if with_filters then
        table.insert(items, {
            text = _("Filter"),
            mandatory = T(_("%1 \u{25BE}"), self:shelfFilterSummary()),
            callback = self:safeCallback(_("Filter"), function()
                self:showShelfFilterOptions(refresh)
            end),
        })
    end
    items[#items].separator = true -- divide the toolbar rows from the book list
    return items
end

function M:showCacheManagement()
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local items = {}
    local entries = {}
    local seen_dirs = {}
    local total_size = 0
    local mp_total_size = 0

    local function directory_stats(path)
        local size = 0
        local file_count = 0
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok then
            return size, file_count
        end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local child = path .. "/" .. entry
                local attr = lfs.attributes(child)
                if attr and attr.mode == "file" then
                    size = size + (attr.size or 0)
                    file_count = file_count + 1
                elseif attr and attr.mode == "directory" then
                    local child_size, child_count = directory_stats(child)
                    size = size + child_size
                    file_count = file_count + child_count
                end
            end
        end
        return size, file_count
    end

    local function add_cache_entry(book_id, title, book_dir)
        if seen_dirs[book_dir] then
            return
        end
        seen_dirs[book_dir] = true
        local size, file_count = directory_stats(book_dir)
        if file_count == 0 then
            return
        end
        local is_mp = WeRead.is_mp_book(book_id)
        total_size = total_size + size
        if is_mp then
            mp_total_size = mp_total_size + size
        end
        table.insert(entries, {
            book_id = book_id,
            title = title or book_id,
            size = size,
            file_count = file_count,
            is_mp = is_mp,
        })
    end

    -- Only list plugin-owned entries tracked in the books table. Scanning the
    -- filesystem would list unrelated subfolders when cache_dir is a user-selected
    -- library directory, and deleting one would rm -rf a non-WeRead folder.
    for book_id, book in pairs(books) do
        add_cache_entry(book_id, book.title, Content.book_resolved_dir(self.settings, book_id, book))
    end

    table.sort(entries, function(a, b)
        if a.is_mp ~= b.is_mp then
            return a.is_mp
        end
        return tostring(a.title):lower() < tostring(b.title):lower()
    end)

    local total_str = total_size < 1024 * 1024
        and string.format("%.0f KB", total_size / 1024)
        or string.format("%.1f MB", total_size / 1024 / 1024)
    local mp_total_str = mp_total_size < 1024 * 1024
        and string.format("%.0f KB", mp_total_size / 1024)
        or string.format("%.1f MB", mp_total_size / 1024 / 1024)
    table.insert(items, {
        text = T(_("[Cleanup] Clear all public account cache (%1)"), mp_total_str),
        callback = self:safeCallback(_("Clear all public account cache"), function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all public account cache? Downloaded articles and cached article lists will be deleted."),
                ok_text = _("Clear"),
                ok_callback = function()
                    self:clearAllMPCache()
                    self:refreshCacheManagement(_("Public account cache cleared"))
                end,
            })
        end),
    })
    table.insert(items, {
        text = T(_("[Cleanup] Clear all cache (%1)"), total_str),
        separator = true,
        callback = self:safeCallback(_("Clear all cache"), function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all cache? Downloaded books and articles will be deleted."),
                ok_text = _("Clear"),
                ok_callback = function()
                    self:clearAllCache()
                    self:refreshCacheManagement(_("Cache cleared"))
                end,
            })
        end),
    })

    for entry_index, entry in ipairs(entries) do
        local size_str = entry.size < 1024 * 1024
            and string.format("%.0f KB", entry.size / 1024)
            or string.format("%.1f MB", entry.size / 1024 / 1024)
        table.insert(items, {
            text = entry.title,
            post_text = T(_("%1 files, %2"), tostring(entry.file_count), size_str),
            mandatory = entry.is_mp and _("Public Account") or "",
            callback = self:safeCallback(entry.title, function()
                self:confirmClearBookCache(entry.book_id, entry.title)
            end),
        })
    end

    self.cache_menu = self:showList(_("Cache management"), items, _("No cached items"))
end

function M:refreshCacheManagement(message)
    if self.cache_menu then
        UIManager:close(self.cache_menu)
        self.cache_menu = nil
    end
    self:showCacheManagement()
    if message then
        self:showTransientInfo(message)
    end
end

-- Register manually copied content under a download root into the books table.
-- Only directories whose name matches a shelf book id in `allowed` are imported
-- (see weread/lib/scan.lua), so unrelated folders in a user-selected download dir can
-- never be registered and later removed by cache cleanup.
function M:scanLocalCache(root, allowed, dry_run)
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local added, updated = Scan.scan_root({
        root = root,
        fs = lfs,
        books = books,
        allowed = allowed,
        is_mp = WeRead.is_mp_book,
        dry_run = dry_run,
        now = os.time(),
    })
    if not dry_run then
        self.settings:set("books", books)
        self.settings:flush()
    end
    return added, updated
end

-- Build the set of importable directory names from the user's WeRead shelf.
-- Must be called from an online context; raises on API failure.
function M:fetchShelfAllowedMap()
    local result = self.client:get_shelf()
    local allowed = {}
    local books = type(result) == "table"
        and type(result.books) == "table"
        and result.books
        or {}
    for _i, book in ipairs(books) do
        if book.bookId then
            allowed[Content.book_dir_name(book.bookId)] = {
                book_id = book.bookId,
                title = book.title,
                author = book.author,
            }
        end
    end
    return allowed
end

function M:confirmScanLocalCache()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Scanning requires the official API key to match folders against your WeRead shelf."))
        return
    end
    self:runOnlineTask(_("Scan and match local books"), function()
        self:showBusy(_("Scanning local cache..."))
        local ok, allowed = pcall(function()
            return self:fetchShelfAllowedMap()
        end)
        if not ok then
            self:closeBusy()
            logger.err("scan shelf fetch failed:", log_error(allowed))
            self:showInfo(T(_("%1 failed:\n%2"), _("Scan and match local books"), display_error(allowed)))
            return
        end
        local added, updated = self:scanLocalCache(self.settings.cache_dir, allowed)
        self:closeBusy()
        self:refreshCacheManagement(T(_("Scan complete. %1 added, %2 updated."),
            tostring(added), tostring(updated)))
    end)
end

-- After the download directory changes, offer to register untracked items
-- already sitting in the new directory (e.g. manually copied in), as well as
-- known books whose stored paths became stale and need rebinding to the files
-- found here. base_message is shown when there is nothing to import or the user
-- skips. Importing requires matching against the shelf, so without an API key
-- or network the scan is silently skipped; it can be run later from Cache
-- management.
function M:offerScanNewDir(new_dir, base_message)
    if not self.settings:is_api_configured() or not self:isNetworkOnline() then
        self:showInfo(base_message)
        return
    end
    self:runOnlineTask(_("Scan and match local books"), function()
        local ok, allowed = pcall(function()
            return self:fetchShelfAllowedMap()
        end)
        if not ok then
            logger.warn("skip scan, shelf fetch failed:", log_error(allowed))
            self:showInfo(base_message)
            return
        end
        local pending_added, pending_updated = self:scanLocalCache(new_dir, allowed, true)
        if pending_added + pending_updated == 0 then
            self:showInfo(base_message)
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Found %1 new and %2 outdated item(s) in the new directory. Import them?"),
                tostring(pending_added), tostring(pending_updated)),
            ok_text = _("Import"),
            ok_callback = function()
                local added, updated = self:scanLocalCache(new_dir, allowed)
                self:showInfo(T(_("Imported %1 new and %2 updated item(s)."), tostring(added), tostring(updated)))
            end,
            cancel_text = _("Skip"),
            cancel_callback = function()
                self:showInfo(base_message)
            end,
        })
    end)
end

function M:confirmClearBookCache(book_id, title, on_cleared)
    UIManager:show(ConfirmBox:new{
        text = T(_("Clear cache for \"%1\"?"), title),
        ok_text = _("Clear"),
        ok_callback = function()
            self:clearBookCache(book_id)
            if on_cleared then
                on_cleared()
                self:showTransientInfo(_("Cache cleared"))
            else
                self:refreshCacheManagement(_("Cache cleared"))
            end
        end,
    })
end

function M:clearBookCache(book_id)
    local books = self.settings:get("books", {})
    local cached_file = books[book_id] and books[book_id].cached_file
    local cache_dir = Content.book_resolved_dir(self.settings, book_id, books[book_id])
    os.execute("rm -rf " .. string.format("%q", cache_dir))
    if books[book_id] then
        books[book_id] = nil
        self.settings:set("books", books)
        self.settings:flush()
    end
    -- Drop the full-book EPUB from the local "weread" collection when its cache is cleared.
    if cached_file then
        pcall(function()
            if not ReadCollection.coll then
                ReadCollection:_read()
            end
            ReadCollection:removeItem(cached_file, "weread")
            ReadCollection:write({ weread = true })
        end)
    end
    self:refreshShelfCacheIndicators()
end

function M:clearAllMPCache()
    -- Delete each MP book's real directory (which may sit under an old download
    -- root) rather than scanning only the current cache_dir, and only touch
    -- plugin-owned entries tracked in the books table.
    -- Also drop matching entries from the local "weread" collection.
    local books = self.settings:get("books", {})
    pcall(function()
        if not ReadCollection.coll then
            ReadCollection:_read()
        end
    end)
    for book_id, book in pairs(books) do
        if WeRead.is_mp_book(book_id) then
            if book and book.cached_file then
                pcall(function()
                    ReadCollection:removeItem(book.cached_file, "weread")
                end)
            end
            os.execute("rm -rf " .. string.format("%q", Content.book_resolved_dir(self.settings, book_id, book)))
            books[book_id] = nil
        end
    end
    pcall(function()
        ReadCollection:write({ weread = true })
    end)
    self.settings:set("books", books)
    self.settings:flush()
    self:refreshShelfCacheIndicators()
end

-- Also drop each book's cached EPUB from the local "weread" collection so the
-- shelf stays in sync with on-disk cache. removeItem is cheap and idempotent.
function M:clearAllCache()
    local books = self.settings:get("books", {})
    pcall(function()
        if not ReadCollection.coll then
            ReadCollection:_read()
        end
    end)
    for book_id, book in pairs(books) do
        if book and book.cached_file then
            pcall(function()
                ReadCollection:removeItem(book.cached_file, "weread")
            end)
        end
        os.execute("rm -rf " .. string.format("%q", Content.book_resolved_dir(self.settings, book_id, book)))
    end
    pcall(function()
        ReadCollection:write({ weread = true })
    end)
    self.settings:set("books", {})
    self.settings:flush()
    self:refreshShelfCacheIndicators()
end

return M
