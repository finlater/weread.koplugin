local Content = require("weread.lib.content")
local logger = require("weread.lib.logger")
local lfs = require("libs/libkoreader-lfs")

local PluginUtil = require("weread.lib.plugin_util")
local log_error = PluginUtil.log_error

local Migrations = {}

local function is_dir(path)
    return type(path) == "string" and path ~= "" and lfs.attributes(path, "mode") == "directory"
end

local function is_file(path)
    return type(path) == "string" and path ~= "" and lfs.attributes(path, "mode") == "file"
end

local function dirname(path)
    if type(path) ~= "string" then
        return nil
    end
    return path:match("^(.*)/[^/]+$")
end

local function join(a, b)
    return tostring(a):gsub("/+$", "") .. "/" .. tostring(b):gsub("^/+", "")
end

local function has_sidecar_markers(dir)
    if not is_dir(dir) then
        return false
    end
    return is_file(join(dir, "catalog.json"))
        or is_file(join(dir, "thoughts.db"))
        or is_file(join(dir, "metadata.json"))
        or is_file(join(dir, "reading_state.json"))
end

local function has_epub(dir)
    if not is_dir(dir) then
        return false
    end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then
        return false
    end
    for name in iter, dir_obj do
        if type(name) == "string" and name:lower():match("%.epub$") then
            return true
        end
    end
    return false
end

-- Repair book.cache_dir values left behind by the short-lived flat-layout fork:
-- they often point at <library>/metadata/<bookId> which only has metadata.json,
-- while catalog/thoughts/EPUB still live under the legacy download folder.
local function repair_flat_layout_cache_dirs(settings, books)
    local repaired = 0
    local download_root = settings.cache_dir
    local candidates_root = {
        download_root,
        settings.meta_dir,
        settings.default_meta_dir,
        settings.default_cache_dir,
        settings.data_dir and (settings.data_dir .. "/meta") or nil,
        settings.data_dir and (settings.data_dir .. "/cache") or nil,
    }

    for book_id, book in pairs(books) do
        if type(book) == "table" then
            local current = book.cache_dir
            local current_ok = has_sidecar_markers(current) or has_epub(current)
            if not current_ok then
                local picks = {}
                local function consider(dir)
                    if type(dir) ~= "string" or dir == "" then
                        return
                    end
                    dir = dir:gsub("/+$", "")
                    if picks[dir] then
                        return
                    end
                    picks[dir] = true
                end

                consider(dirname(book.cached_file))
                if type(book.cached_chapters) == "table" then
                    for _uid, path in pairs(book.cached_chapters) do
                        consider(dirname(path))
                    end
                end
                for _i, root in ipairs(candidates_root) do
                    if type(root) == "string" and root ~= "" then
                        consider(join(root, Content.book_dir_name(book_id)))
                    end
                end

                local best
                for dir, _ in pairs(picks) do
                    local score = 0
                    if has_epub(dir) then score = score + 4 end
                    if is_file(join(dir, "catalog.json")) then score = score + 3 end
                    if is_file(join(dir, "thoughts.db")) then score = score + 2 end
                    if is_file(join(dir, "metadata.json")) then score = score + 1 end
                    if score > 0 and (not best or score > best.score) then
                        best = { dir = dir, score = score }
                    end
                end

                if best and best.dir ~= current then
                    book.cache_dir = best.dir
                    -- If cached_file is missing/broken but an EPUB remains in the
                    -- recovered directory, rebind to the largest EPUB there.
                    if not is_file(book.cached_file) then
                        local ok, iter, dir_obj = pcall(lfs.dir, best.dir)
                        if ok then
                            local main_epub, main_size = nil, -1
                            for name in iter, dir_obj do
                                if type(name) == "string" and name:lower():match("%.epub$") then
                                    local path = join(best.dir, name)
                                    local size = lfs.attributes(path, "size") or 0
                                    if size > main_size then
                                        main_size = size
                                        main_epub = path
                                    end
                                end
                            end
                            if main_epub then
                                book.cached_file = main_epub
                            end
                        end
                    end
                    repaired = repaired + 1
                    logger.info("repaired book cache_dir:",
                        "book_id=", tostring(book_id),
                        "from=", tostring(current),
                        "to=", best.dir)
                end
            end
        end
    end
    return repaired
end

function Migrations.run(settings, client)
    local books = settings:get("books", {})
    local found, migrated, failed = false, 0, 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and book.chapters ~= nil then
            found = true
            if type(book.chapters) == "table" then
                local ok, saved = pcall(Content.save_catalog_cache,
                    client, settings, book, book.chapters)
                if ok and saved then
                    migrated = migrated + 1
                else
                    failed = failed + 1
                end
            end
            book.chapters = nil
        end
    end

    local repaired = 0
    local ok_repair, repair_or_err = pcall(repair_flat_layout_cache_dirs, settings, books)
    if ok_repair then
        repaired = tonumber(repair_or_err) or 0
    else
        logger.warn("flat-layout cache_dir repair failed:",
            log_error(repair_or_err))
    end

    if not found and repaired == 0 and not settings:has_legacy_book_records() then
        return
    end

    local ok, err = pcall(function()
        settings:set("books", books)
        settings:flush()
    end)
    if ok then
        logger.info("legacy per-book data migrated:",
            "catalogs=", tostring(migrated),
            "catalog_failures=", tostring(failed),
            "cache_dir_repaired=", tostring(repaired))
    else
        logger.err("legacy per-book data migration failed:",
            log_error(err))
    end
end

return Migrations
