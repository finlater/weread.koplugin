-- Unit tests for WeRead keyword tagging on Content.
-- Run from the repo root with:
--   luajit spec/weread_tag_spec.lua

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

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { reader_url = function() return "" end }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["readcollection"] = function()
    return { coll = {}, _read = function() end }
end

local Content = require("weread.lib.content")

eq(Content.WEREAD_TAG, "weread", "tag constant")
eq(Content.merge_weread_keywords(nil), "weread", "empty becomes tag")
eq(Content.merge_weread_keywords(""), "weread", "blank becomes tag")
eq(Content.merge_weread_keywords("history"), "history\nweread",
    "keeps existing keyword")
eq(Content.merge_weread_keywords("history, fiction"), "history\nfiction\nweread",
    "splits comma-separated keywords")
eq(Content.merge_weread_keywords("history\nweread"), "history\nweread",
    "does not duplicate the weread tag")
eq(Content.merge_weread_keywords("weread, history"), "weread\nhistory",
    "keeps weread when it is already first")

do
    local stored = { ["/book.epub"] = "history" }
    local bookinfo = { ["/book.epub"] = "history" }
    local extracted = {}
    Content.apply_weread_tag("/book.epub", {
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

do
    local stored = {}
    local extracted = {}
    Content.apply_weread_tag("/new.epub", {
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

do
    local writes = 0
    local ok = Content.apply_weread_tag("/missing.epub", {
        file_exists = function() return false end,
        write_keywords = function() writes = writes + 1 end,
    })
    eq(ok, false, "missing file returns false")
    eq(writes, 0, "missing file is not tagged")
end

do
    local writes = 0
    Content.apply_weread_tag("/done.epub", {
        file_exists = function() return true end,
        read_keywords = function() return "history\nweread" end,
        write_keywords = function() writes = writes + 1 end,
    })
    eq(writes, 0, "already tagged books are not rewritten")
end

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
    local n = Content.backfill_weread_tags({
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

print(string.format("weread_tag_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
