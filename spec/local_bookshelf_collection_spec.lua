-- Focused regression tests for local "weread" collection sync.
-- Covers download add rules and cache-clear remove rules.
-- Run from the repo root with:
--   lua spec/local_bookshelf_collection_spec.lua

package.path = "./?.lua;" .. package.path

local coll_adds = {}
local coll_removes = {}
local coll_writes = 0

package.preload["readcollection"] = function()
    return {
        coll = { weread = {} },
        _read = function() end,
        addCollection = function(self, name)
            self.coll[name] = self.coll[name] or {}
        end,
        isFileInCollection = function(_self, _path, _name)
            return false
        end,
        addItem = function(_self, path, name)
            coll_adds[#coll_adds + 1] = { path = path, name = name }
        end,
        removeItem = function(_self, path, name, no_write)
            coll_removes[#coll_removes + 1] = {
                path = path,
                name = name,
                no_write = no_write == true,
            }
            return true
        end,
        write = function()
            coll_writes = coll_writes + 1
        end,
    }
end

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        preventStandby = function() end,
        allowStandby = function() end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        save_chapter_epub = function(_settings, _book, chapter)
            return "/cache/book/chapter-" .. tostring(chapter.chapterUid) .. ".epub"
        end,
        save_book_epub = function()
            return "/cache/book/full.epub"
        end,
        book_resolved_dir = function(_settings, book_id, _book)
            return "/cache/" .. tostring(book_id)
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        is_mp_book = function(book_id)
            return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
        end,
    }
end

local Downloader = require("weread.lib.downloader")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local function make_downloader()
    local live_books = {}
    return Downloader:new{
        settings = {
            get = function(_self, key)
                return key == "books" and live_books or nil
            end,
            set = function(_self, key, value)
                if key == "books" then live_books = value end
            end,
            flush = function() end,
        },
        client = {},
        refresh_shelf = function() end,
        open_file = function() end,
        show_info = function() end,
        show_transient = function() end,
    }
end

local chapter = { chapterUid = 22, title = "Target" }

-- Full-book download must add the EPUB to the weread collection.
coll_adds, coll_removes, coll_writes = {}, {}, 0
do
    local downloader = make_downloader()
    downloader:_step({
        book = { book_id = "book", title = "Book" },
        chapters = { chapter },
        selected = { chapter },
        bodies = { ["22"] = "<p>body</p>" },
        assets = {},
        state = { css = "" },
        suffix = "full",
        index = 2,
        total = 1,
        failed = {},
        annotation_failed_batches = 0,
        silent_completion = true,
        footnotes_done = true,
        started_at = 999,
    })
    eq(#coll_adds, 1, "full book adds once")
    eq(coll_adds[1] and coll_adds[1].path, "/cache/book/full.epub", "full book path")
    eq(coll_adds[1] and coll_adds[1].name, "weread", "full book collection name")
    eq(coll_writes >= 1 and true or false, true, "full book writes collection")
end

-- Single-chapter download must not add to the collection.
coll_adds, coll_removes, coll_writes = {}, {}, 0
do
    local downloader = make_downloader()
    downloader:_step({
        book = { book_id = "book", title = "Book" },
        chapters = { chapter },
        selected = { chapter },
        bodies = { ["22"] = "<p>body</p>" },
        assets = {},
        state = { css = "" },
        suffix = "chapter",
        index = 2,
        total = 1,
        failed = {},
        annotation_failed_batches = 0,
        single_chapter = true,
        silent_completion = true,
        started_at = 999,
    })
    eq(#coll_adds, 0, "single chapter does not add")
end

-- Separate-chapters download must not add to the collection.
coll_adds, coll_removes, coll_writes = {}, {}, 0
do
    local chapter_33 = { chapterUid = 33, title = "Other" }
    local downloader = make_downloader()
    downloader:_step({
        book = {
            book_id = "book",
            title = "Book",
            cached_file = "/cache/book/full.epub",
            cached_full_book = "/cache/book/full.epub",
        },
        chapters = { chapter, chapter_33 },
        selected = { chapter, chapter_33 },
        bodies = { ["22"] = "<p>22</p>", ["33"] = "<p>33</p>" },
        assets = {},
        assets_by_uid = { ["22"] = {}, ["33"] = {} },
        state = { css = "" },
        suffix = "chapters",
        index = 3,
        total = 2,
        failed = {},
        annotation_failed_batches = 0,
        separate_chapters = true,
        silent_completion = true,
        started_at = 999,
    })
    eq(#coll_adds, 0, "separate chapters does not add")
end

-- Cache clear helpers: preload remaining UI deps used by weread.ui.cache.
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/widget/pathchooser"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["weread.lib.scan"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        log_error = function(err) return tostring(err) end,
        display_error = function(err) return tostring(err) end,
        file_exists = function() return true end,
    }
end

local real_os_execute = os.execute
rawset(os, "execute", function() return 0 end)

package.loaded["weread.ui.cache"] = nil
package.loaded["weread.lib.content"] = nil
package.loaded["weread.lib.protocol"] = nil
local Cache = require("weread.ui.cache")

local function make_cache_host(books)
    local stored = books
    local host = {
        settings = {
            get = function(_self, key, default)
                if key == "books" then return stored end
                return default
            end,
            set = function(_self, key, value)
                if key == "books" then stored = value end
            end,
            flush = function() end,
        },
        refreshShelfCacheIndicators = function() end,
    }
    for key, value in pairs(Cache) do
        host[key] = value
    end
    return host
end

-- clearBookCache removes the full-book path from the collection.
coll_adds, coll_removes, coll_writes = {}, {}, 0
do
    local host = make_cache_host({
        book = {
            cached_file = "/cache/book/full.epub",
            cached_full_book = "/cache/book/full.epub",
        },
    })
    host:clearBookCache("book")
    eq(#coll_removes, 1, "clearBookCache removes once")
    eq(coll_removes[1] and coll_removes[1].path, "/cache/book/full.epub",
        "clearBookCache path")
    eq(coll_removes[1] and coll_removes[1].name, "weread",
        "clearBookCache collection name")
    eq(coll_removes[1] and coll_removes[1].no_write, false,
        "clearBookCache writes immediately")
end

-- clearAllCache removes every cached_file with deferred writes.
coll_adds, coll_removes, coll_writes = {}, {}, 0
do
    local host = make_cache_host({
        a = { cached_file = "/cache/a/full.epub", cached_full_book = "/cache/a/full.epub" },
        b = { cached_file = "/cache/b/full.epub", cached_full_book = "/cache/b/full.epub" },
    })
    host:clearAllCache()
    eq(#coll_removes, 2, "clearAllCache removes each book")
    eq(coll_removes[1] and coll_removes[1].no_write, true, "clearAllCache deferred write")
    eq(coll_writes >= 1 and true or false, true, "clearAllCache batch write")
end

-- clearAllMPCache only removes MP books.
coll_adds, coll_removes, coll_writes = {}, {}, 0
do
    local host = make_cache_host({
        normal = {
            cached_file = "/cache/n/full.epub",
            cached_full_book = "/cache/n/full.epub",
        },
        ["MP_WXS_1"] = { cached_file = "/cache/mp/article.epub" },
    })
    host:clearAllMPCache()
    eq(#coll_removes, 1, "clearAllMPCache removes only MP")
    eq(coll_removes[1] and coll_removes[1].path, "/cache/mp/article.epub",
        "clearAllMPCache path")
end

rawset(os, "execute", real_os_execute)

print(string.format(
    "local_bookshelf_collection_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
