-- Local-cache scanner: registers manually copied book/article directories under
-- a download root into the books table. Only directories whose name matches an
-- entry in `allowed` (built from the user's WeRead shelf) are imported, so when
-- the download dir points at a user-selected library, unrelated folders can
-- never be registered and later deleted by cache cleanup.
--
-- Kept free of KOReader dependencies (filesystem access and the MP check are
-- injected) so it can be unit-tested with a plain Lua interpreter.

local Scan = {}

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
                        local record = books[book_id]
                        local is_new = record == nil
                        if opts.dry_run then
                            if is_new then
                                added = added + 1
                            end
                        else
                            record = record or { book_id = book_id }
                            local changed = is_new
                            if record.cache_dir ~= dir then
                                record.cache_dir = dir
                                changed = true
                            end
                            -- MP articles are opened per-article, not via a single file.
                            if not is_mp and not record.cached_file and main_epub then
                                record.cached_file = main_epub
                                changed = true
                            end
                            if not record.title or record.title == "" then
                                record.title = shelf_book.title
                                    or (main_epub and main_epub:match("([^/]+)%.epub$"))
                                    or book_id
                                changed = true
                            end
                            if shelf_book.author and not record.author then
                                record.author = shelf_book.author
                            end
                            if is_new then
                                record.updated_at = opts.now
                            end
                            if changed then
                                books[book_id] = record
                                if is_new then
                                    added = added + 1
                                else
                                    updated = updated + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return added, updated
end

return Scan
