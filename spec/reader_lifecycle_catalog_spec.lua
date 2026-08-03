-- Focused tests for offline chapter catalog self-healing.

package.path = "./?.lua;" .. package.path

local loaded_chapters
local saved_chapters
local save_ok, save_err = true, nil
local warnings = {}

package.preload["weread.lib.content"] = function()
    return {
        catalog_cache_path = function() return "/cache/book/catalog.json" end,
        load_catalog_cache = function(_client, _settings, book)
            if loaded_chapters then book.chapters = loaded_chapters end
            return loaded_chapters
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_chapters = chapters
            return save_ok, save_err
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return {
                warn = function(...) warnings[#warnings + 1] = { ... } end,
            }
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        display_error = tostring,
        file_exists = function() return false end,
        log_error = tostring,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local function reset()
    loaded_chapters = nil
    saved_chapters = nil
    save_ok, save_err = true, nil
    warnings = {}
end

local disk = { { chapterUid = 1 } }
local database = { { chapterUid = 2 } }

reset()
local put_chapters
local host = {
    client = {},
    settings = {},
    library_db = {
        getChapters = function() return database end,
        putChapters = function(_self, _book_id, chapters)
            put_chapters = chapters
        end,
    },
}
for key, value in pairs(Lifecycle) do host[key] = value end

local memory = { { chapterUid = 3 } }
local memory_book = { book_id = "book", chapters = memory }
expect(host:ensureChaptersLoaded(memory_book) == memory,
    "memory catalog has first priority")
expect(saved_chapters == memory and put_chapters == memory,
    "memory catalog heals both persistent stores")

reset()
loaded_chapters = disk
local disk_book = { book_id = "book" }
expect(host:ensureChaptersLoaded(disk_book) == disk,
    "disk catalog has second priority")
expect(put_chapters == disk, "disk catalog backfills SQLite")

reset()
local db_book = { book_id = "book" }
expect(host:ensureChaptersLoaded(db_book) == database,
    "SQLite catalog is the final fallback")
expect(db_book.chapters == database and saved_chapters == database,
    "SQLite catalog backfills memory and catalog.json")

reset()
host.library_db = nil
local no_db_book = { book_id = "book" }
expect(host:ensureChaptersLoaded(no_db_book) == nil,
    "missing SQLite dependency degrades safely")

reset()
host.library_db = {
    getChapters = function() return {} end,
    putChapters = function() end,
}
local empty_book = { book_id = "book" }
expect(host:ensureChaptersLoaded(empty_book) == nil,
    "empty SQLite catalog is treated as a miss")
expect(saved_chapters == nil, "empty catalog is not persisted")

reset()
save_ok, save_err = false, "disk full"
host.library_db.getChapters = function() return database end
local failed_save_book = { book_id = "book" }
expect(host:ensureChaptersLoaded(failed_save_book) == database,
    "catalog remains usable when disk backfill fails")
expect(#warnings == 1, "disk backfill failure is logged")

print(string.format(
    "reader_lifecycle_catalog_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
