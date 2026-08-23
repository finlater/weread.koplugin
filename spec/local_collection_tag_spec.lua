-- Unit tests for weread/lib/local_collection.lua.
-- Covers keyword merge, sidecar/bookinfo tagging, collection add, and backfill.
-- Run from the repo root with:
--   luajit spec/local_collection_tag_spec.lua

package.path = "./?.lua;" .. package.path

local failures, checks = 0, 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local function is_true(got, label)
    eq(got and true or false, true, label)
end

package.preload["readcollection"] = function()
    return {
        coll = {},
        _read = function() end,
        addCollection = function() end,
        isFileInCollection = function() return false end,
        addItem = function() end,
        write = function() end,
    }
end

local LocalCollection = require("weread.lib.local_collection")

eq(LocalCollection.TAG, "weread", "tag constant")
eq(LocalCollection.COLLECTION_NAME, "weread", "collection name")

eq(LocalCollection.merge_keywords(nil), "weread", "empty becomes tag")
eq(LocalCollection.merge_keywords(""), "weread", "blank becomes tag")
eq(LocalCollection.merge_keywords("history"), "history\nweread",
    "keeps existing keyword")
eq(LocalCollection.merge_keywords("history, fiction"), "history\nfiction\nweread",
    "splits comma-separated keywords")
eq(LocalCollection.merge_keywords("history\nweread"), "history\nweread",
    "does not duplicate the weread tag")
eq(LocalCollection.merge_keywords("weread, history"), "weread\nhistory",
    "keeps weread when it is already first")

local xml = LocalCollection.epub_keyword_xml()
is_true(xml:find("<dc:subject>weread</dc:subject>", 1, true) ~= nil,
    "EPUB xml includes dc:subject")
is_true(xml:find('content="weread"', 1, true) ~= nil,
    "EPUB xml includes keywords meta")

-- apply_tag writes merged custom keywords and updates CoverBrowser.
do
    local stored = { ["/book.epub"] = "history" }
    local bookinfo = { ["/book.epub"] = "history" }
    local extracted = {}
    LocalCollection.apply_tag("/book.epub", {
        read_keywords = function(path) return stored[path] end,
        write_keywords = function(path, keywords) stored[path] = keywords end,
        get_bookinfo_keywords = function(path) return bookinfo[path] end,
        set_bookinfo_keywords = function(path, keywords)
            bookinfo[path] = keywords
        end,
        extract_bookinfo = function(path) extracted[#extracted + 1] = path end,
        file_exists = function() return true end,
    })
    eq(stored["/book.epub"], "history\nweread", "sidecar keywords merged")
    eq(bookinfo["/book.epub"], "history\nweread",
        "existing bookinfo row is updated")
    eq(#extracted, 0, "existing bookinfo row is not re-extracted")
end

-- Missing CoverBrowser row triggers extraction after sidecar write.
do
    local stored = {}
    local extracted = {}
    LocalCollection.apply_tag("/new.epub", {
        read_keywords = function() return nil end,
        write_keywords = function(path, keywords) stored[path] = keywords end,
        get_bookinfo_keywords = function() return nil end,
        set_bookinfo_keywords = function() end,
        extract_bookinfo = function(path) extracted[#extracted + 1] = path end,
        file_exists = function() return true end,
    })
    eq(stored["/new.epub"], "weread", "new sidecar gets the tag")
    eq(#extracted, 1, "missing bookinfo row is extracted")
end

-- Missing files are skipped.
do
    local writes = 0
    local ok = LocalCollection.apply_tag("/missing.epub", {
        file_exists = function() return false end,
        write_keywords = function() writes = writes + 1 end,
    })
    eq(ok, false, "missing file returns false")
    eq(writes, 0, "missing file is not tagged")
end

-- add_full_book adds the collection item then tags.
do
    local coll_adds = {}
    local tagged = {}
    package.loaded["readcollection"] = {
        coll = {},
        _read = function() end,
        addCollection = function(self, name)
            self.coll[name] = self.coll[name] or {}
        end,
        isFileInCollection = function() return false end,
        addItem = function(_self, path, name)
            coll_adds[#coll_adds + 1] = { path = path, name = name }
        end,
        write = function() end,
    }
    LocalCollection.add_full_book("/full.epub", {
        read_keywords = function() return nil end,
        write_keywords = function(path, keywords) tagged[path] = keywords end,
        get_bookinfo_keywords = function() return "weread" end,
        set_bookinfo_keywords = function() end,
        extract_bookinfo = function() end,
        file_exists = function() return true end,
    })
    eq(#coll_adds, 1, "full book is added to the collection")
    eq(coll_adds[1] and coll_adds[1].name, "weread", "collection name")
    eq(tagged["/full.epub"], "weread", "full book is tagged")
end

-- backfill tags every existing collection file.
do
    local tagged = {}
    package.loaded["readcollection"] = {
        coll = {
            weread = {
                ["/a.epub"] = { file = "/a.epub" },
                ["/b.epub"] = { file = "/b.epub" },
                ["/gone.epub"] = { file = "/gone.epub" },
            },
        },
        _read = function() end,
    }
    local n = LocalCollection.backfill({
        read_keywords = function() return nil end,
        write_keywords = function(path, keywords) tagged[path] = keywords end,
        get_bookinfo_keywords = function() return "weread" end,
        set_bookinfo_keywords = function() end,
        extract_bookinfo = function() end,
        file_exists = function(path) return path ~= "/gone.epub" end,
    })
    eq(n, 2, "backfill tags existing files only")
    eq(tagged["/a.epub"], "weread", "backfill tags first book")
    eq(tagged["/b.epub"], "weread", "backfill tags second book")
    eq(tagged["/gone.epub"], nil, "backfill skips missing files")
end

print(string.format(
    "local_collection_tag_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
