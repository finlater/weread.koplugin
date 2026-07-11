-- Local-cache scanner: registers manually copied book/article directories under
-- a download root into the books table. Only directories whose name matches an
-- entry in `allowed` (built from the user's WeRead shelf) are imported, so when
-- the download dir points at a user-selected library, unrelated folders can
-- never be registered and later deleted by cache cleanup.
--
-- Kept free of KOReader dependencies (filesystem access and the MP check are
-- injected) so it can be unit-tested with a plain Lua interpreter.

local Scan = {}

local function dirname(path)
    if type(path) ~= "string" then
        return nil
    end
    return path:match("^(.*)/[^/]+$")
end

local function file_exists(fs, path)
    if type(path) ~= "string" then
        return false
    end
    local attr = fs.attributes(path)
    return attr ~= nil and attr.mode == "file"
end

-- opts:
--   root     download root directory to scan
--   fs       lfs-like interface: fs.dir(path) iterator, fs.attributes(path)
--   books    books table, mutated in place unless dry_run
--   allowed  map of directory name -> { book_id, title, author } from the shelf
--   is_mp    function(book_id) -> true for MP (public account) ids
--   dry_run  when true, only count what would change
--   now      timestamp used for updated_at on new records
-- Returns added, updated.
function Scan.scan_root(opts)
    local fs, books, allowed = opts.fs, opts.books, opts.allowed
    local added, updated = 0, 0
    local ok, iter, dir_obj = pcall(fs.dir, opts.root)
    if not ok then
        return 0, 0
    end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local dir = opts.root .. "/" .. entry
            local attr = fs.attributes(dir)
            if attr and attr.mode == "directory" then
                -- MP dirs hold .html articles; regular books hold .epub, and we
                -- track the largest one as the book file to open.
                local main_epub, main_size = nil, -1
                local has_epub, has_html = false, false
                local ok2, fiter, fobj = pcall(fs.dir, dir)
                if ok2 then
                    for f in fiter, fobj do
                        if f ~= "." and f ~= ".." then
                            local fattr = fs.attributes(dir .. "/" .. f)
                            if fattr and fattr.mode == "file" then
                                local ext = f:match("%.([^.]+)$")
                                ext = ext and ext:lower()
                                if ext == "html" then
                                    has_html = true
                                elseif ext == "epub" then
                                    has_epub = true
                                    if (fattr.size or 0) > main_size then
                                        main_size = fattr.size or 0
                                        main_epub = dir .. "/" .. f
                                    end
                                end
                            end
                        end
                    end
                end
                -- Only directories whose name matches a shelf book id are
                -- imported; unrelated folders under a user-selected download
                -- dir are left untouched.
                local shelf_book = allowed[entry]
                if shelf_book then
                    local book_id = shelf_book.book_id
                    local is_mp = opts.is_mp(book_id)
                    local has_content = is_mp and has_html or (not is_mp and has_epub)
                    if has_content then
                        local record = books[book_id] or { book_id = book_id }
                        local had_cache = (type(record.cache_dir) == "string" and record.cache_dir ~= "")
                            or record.cached_file ~= nil
                        local is_new = not had_cache
                        -- The same change detection drives both the dry-run
                        -- counters and the actual import so they always agree.
                        local dir_changed = record.cache_dir ~= dir
                        -- Rebind the book file whenever the stored path is
                        -- missing, points outside this directory (stale after a
                        -- download-dir change), or no longer exists on disk. A
                        -- valid file inside this directory is kept even when
                        -- another epub here is larger. MP articles are opened
                        -- per-article, not via a single file.
                        local cf = record.cached_file
                        local cf_valid = dirname(cf) == dir and file_exists(fs, cf)
                        local needs_file = not is_mp and main_epub ~= nil and not cf_valid
                        local needs_title = not record.title or record.title == ""
                        local changed = is_new or dir_changed or needs_file or needs_title
                        if opts.dry_run then
                            if changed then
                                if is_new then
                                    added = added + 1
                                else
                                    updated = updated + 1
                                end
                            end
                        elseif changed then
                            record.cache_dir = dir
                            if needs_file then
                                record.cached_file = main_epub
                            end
                            if needs_title then
                                record.title = shelf_book.title
                                    or (main_epub and main_epub:match("([^/]+)%.epub$"))
                                    or book_id
                            end
                            if shelf_book.author and not record.author then
                                record.author = shelf_book.author
                            end
                            -- Chapter paths may still point at an old download
                            -- dir: follow files that also exist here by name,
                            -- and drop entries that exist nowhere so they don't
                            -- read as cached.
                            if type(record.cached_chapters) == "table" then
                                for uid, path in pairs(record.cached_chapters) do
                                    if not file_exists(fs, path) then
                                        local name = type(path) == "string" and path:match("[^/]+$")
                                        local candidate = name and (dir .. "/" .. name)
                                        if candidate and file_exists(fs, candidate) then
                                            record.cached_chapters[uid] = candidate
                                        else
                                            record.cached_chapters[uid] = nil
                                        end
                                    end
                                end
                            end
                            if is_new then
                                record.updated_at = opts.now
                                added = added + 1
                            else
                                updated = updated + 1
                            end
                            books[book_id] = record
                        end
                    end
                end
            end
        end
    end
    return added, updated
end

return Scan
