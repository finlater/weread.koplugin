-- Cache settings, directory selection, scanning, and cleanup UI.
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Content = require("weread.lib.content")
local logger = require("weread.lib.logger")
local PathChooser = require("ui/widget/pathchooser")
local Scan = require("weread.lib.scan")
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")

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
            self:offerMoveContentToNewDir(old_dir, path)
        end,
    }
    UIManager:show(path_chooser)
end

function M:showMetaDirPicker(touchmenu_instance)
    local current = self.settings:get_meta_dir()
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
            local old_dir = self.settings:get_meta_dir()
            self.settings:set_meta_dir(path)
            logger.info("metadata directory changed:", path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            self:offerMoveMetaToNewDir(old_dir, path)
        end,
    }
    UIManager:show(path_chooser)
end

local function normalize_root(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:gsub("/+$", "")
end

local function path_under_root(path, root)
    root = normalize_root(root)
    path = type(path) == "string" and path or nil
    if not root or not path then
        return false
    end
    if path == root then
        return true
    end
    return path:sub(1, #root + 1) == root .. "/"
end

-- After the book directory changes, offer to move flat EPUB/chapter files.
-- Sidecar metadata stays in meta_dir and is not moved here.
function M:offerMoveContentToNewDir(old_dir, new_dir)
    old_dir = normalize_root(old_dir)
    new_dir = normalize_root(new_dir)
    if old_dir == new_dir then
        self:offerScanNewDir(new_dir, T(_("Book directory set to:\n%1"), new_dir))
        return
    end
    local books = self.settings:get("books", {})
    local movable = {}
    local function maybe_add(book_id, src)
        if type(src) ~= "string" or src == "" then
            return
        end
        if not path_under_root(src, old_dir) then
            return
        end
        local name = src:match("[^/]+$")
        if not name then
            return
        end
        local dst = new_dir .. "/" .. name
        if src ~= dst then
            table.insert(movable, { book_id = book_id, src = src, dst = dst, kind = "file" })
        end
    end
    for book_id, book in pairs(books) do
        if type(book) == "table" then
            maybe_add(book_id, book.cached_file)
            if type(book.cached_chapters) == "table" then
                for _uid, chapter_path in pairs(book.cached_chapters) do
                    maybe_add(book_id, chapter_path)
                end
            end
        end
    end
    if #movable == 0 then
        self:offerScanNewDir(new_dir, T(_("Book directory set to:\n%1"), new_dir))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Book directory changed. Move %1 downloaded file(s) to the new location?"), tostring(#movable)),
        ok_text = _("Move"),
        ok_callback = function()
            self:moveContentFilesToNewDir(movable, new_dir)
        end,
        cancel_text = _("Keep"),
        cancel_callback = function()
            self:offerScanNewDir(new_dir, T(_("Book directory set to:\n%1\nExisting downloads stay in the old location."), new_dir))
        end,
    })
end

function M:moveContentFilesToNewDir(movable, new_dir)
    self:showBusy(_("Moving downloaded books..."))
    UIManager:scheduleIn(0.1, function()
        local books = self.settings:get("books", {})
        local moved, skipped, failed = 0, 0, 0
        local remap = {}
        for _i, m in ipairs(movable) do
            local ok, reason = self:moveContentFile(m.src, m.dst)
            if ok then
                remap[m.src] = m.dst
                moved = moved + 1
            elseif reason == "target_exists" then
                skipped = skipped + 1
                logger.warn("skip move, target exists:", m.dst)
            else
                failed = failed + 1
                logger.err("move book file failed:", m.src, "->", m.dst)
            end
        end
        for _book_id, book in pairs(books) do
            if type(book) == "table" then
                if type(book.cached_file) == "string" and remap[book.cached_file] then
                    book.cached_file = remap[book.cached_file]
                end
                if type(book.cached_chapters) == "table" then
                    for uid, path in pairs(book.cached_chapters) do
                        if remap[path] then
                            book.cached_chapters[uid] = remap[path]
                        end
                    end
                end
            end
        end
        self.settings:set("books", books)
        self.settings:flush()
        self:closeBusy()
        local message
        if skipped == 0 and failed == 0 then
            message = T(_("Moved %1 file(s) to:\n%2"), tostring(moved), new_dir)
        else
            message = T(_("Moved %1 file(s). %2 skipped (target already exists), %3 failed. These stay in the old location."), tostring(moved), tostring(skipped), tostring(failed))
        end
        self:offerScanNewDir(new_dir, message)
    end)
end

function M:moveContentFile(src, dst)
    if src == dst then
        return true
    end
    local lfs = require("libs/libkoreader-lfs")
    local src_attr = lfs.attributes(src)
    if not src_attr or src_attr.mode ~= "file" then
        return false, "missing"
    end
    if lfs.attributes(dst) then
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

-- After the metadata directory changes, offer to move per-book sidecar folders.
function M:offerMoveMetaToNewDir(old_dir, new_dir)
    old_dir = normalize_root(old_dir)
    new_dir = normalize_root(new_dir)
    if old_dir == new_dir then
        self:showInfo(T(_("Metadata directory set to:\n%1"), new_dir))
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local movable = {}
    for book_id, book in pairs(books) do
        local src = Content.book_resolved_dir(self.settings, book_id, book)
        local dst = Content.book_meta_dir(self.settings, book_id)
        if src ~= dst and path_under_root(src, old_dir) then
            local attr = lfs.attributes(src)
            if attr and attr.mode == "directory" then
                table.insert(movable, { book_id = book_id, src = src, dst = dst })
            end
        end
    end
    if #movable == 0 then
        self:showInfo(T(_("Metadata directory set to:\n%1"), new_dir))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Metadata directory changed. Move %1 book metadata folder(s) to the new location?"), tostring(#movable)),
        ok_text = _("Move"),
        ok_callback = function()
            self:moveMetaDirsToNewDir(movable, new_dir)
        end,
        cancel_text = _("Keep"),
        cancel_callback = function()
            self:showInfo(T(_("Metadata directory set to:\n%1\nExisting metadata stays in the old location."), new_dir))
        end,
    })
end

function M:moveMetaDirsToNewDir(movable, new_dir)
    self:showBusy(_("Moving book metadata..."))
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
                logger.warn("skip meta move, target exists:", m.dst)
            else
                failed = failed + 1
                logger.err("move book meta failed:", m.src, "->", m.dst)
            end
        end
        self.settings:set("books", books)
        self.settings:flush()
        self:closeBusy()
        if skipped == 0 and failed == 0 then
            self:showInfo(T(_("Moved %1 metadata folder(s) to:\n%2"), tostring(moved), new_dir))
        else
            self:showInfo(T(_("Moved %1 metadata folder(s). %2 skipped (target already exists), %3 failed. These stay in the old location."), tostring(moved), tostring(skipped), tostring(failed)))
        end
    end)
end

-- Move one sidecar directory to dst. Uses `mv`, which (unlike os.rename) handles
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

local SHELF_SORT_OPTIONS = {
    { key = "time_desc", label = _("Last read time (newest first)"), short = _("Newest") },
    { key = "time_asc",  label = _("Last read time (oldest first)"), short = _("Oldest") },
    { key = "default",   label = _("Default order"), short = _("Default") },
    { key = "name_asc",  label = _("Title A-Z"), short = "A–Z" },
    { key = "name_desc", label = _("Title Z-A"), short = "Z–A" },
}

local function shelfSortLabel(sort_key)
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        if opt.key == sort_key then
            return opt.label
        end
    end
    return SHELF_SORT_OPTIONS[1].label
end

function M:shelfSortSummary()
    local sort_key = self.settings:get("shelf").sort_order
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        if opt.key == sort_key then return opt.short end
    end
    return SHELF_SORT_OPTIONS[1].short
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

    local function file_size(path)
        if type(path) ~= "string" or path == "" then
            return 0
        end
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            return attr.size or 0
        end
        return 0
    end

    local function add_cache_entry(book_id, book)
        local book_dir = Content.book_resolved_dir(self.settings, book_id, book)
        local key = book_dir or book_id
        if seen_dirs[key] then
            return
        end
        seen_dirs[key] = true
        local size, file_count = directory_stats(book_dir)
        -- Flat EPUB/chapter files live outside the sidecar directory.
        local content_paths = {}
        if type(book) == "table" then
            if type(book.cached_file) == "string" then
                content_paths[book.cached_file] = true
            end
            if type(book.cached_chapters) == "table" then
                for _uid, chapter_path in pairs(book.cached_chapters) do
                    if type(chapter_path) == "string" then
                        content_paths[chapter_path] = true
                    end
                end
            end
        end
        local meta_norm = type(book_dir) == "string" and book_dir:gsub("/+$", "") or nil
        for path in pairs(content_paths) do
            if not (meta_norm and (path == meta_norm or path:sub(1, #meta_norm + 1) == meta_norm .. "/")) then
                local sz = file_size(path)
                if sz > 0 or file_exists(path) then
                    size = size + sz
                    file_count = file_count + 1
                end
            end
        end
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
            title = (book and book.title) or book_id,
            size = size,
            file_count = file_count,
            is_mp = is_mp,
        })
    end

    -- Only list plugin-owned entries tracked in the books table. Scanning the
    -- filesystem would list unrelated files when the book directory is a user
    -- library, and deleting one would remove non-WeRead content.
    for book_id, book in pairs(books) do
        add_cache_entry(book_id, book)
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
        local added_meta, updated_meta = self:scanLocalCache(self.settings.meta_dir, allowed)
        added = added + added_meta
        updated = updated + updated_meta
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
    Content.remove_book_files(self.settings, book_id, books[book_id])
    if books[book_id] then
        books[book_id] = nil
        self.settings:set("books", books)
        self.settings:flush()
    end
    self:refreshShelfCacheIndicators()
end

function M:clearAllMPCache()
    -- Delete each MP book's sidecar/content files rather than scanning only the
    -- current roots, and only touch plugin-owned entries tracked in books.
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        if WeRead.is_mp_book(book_id) then
            Content.remove_book_files(self.settings, book_id, book)
            books[book_id] = nil
        end
    end
    self.settings:set("books", books)
    self.settings:flush()
    self:refreshShelfCacheIndicators()
end

function M:clearAllCache()
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        Content.remove_book_files(self.settings, book_id, book)
    end
    self.settings:set("books", {})
    self.settings:flush()
    self:refreshShelfCacheIndicators()
end

return M
