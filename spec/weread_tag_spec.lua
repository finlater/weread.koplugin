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

local archive_files = {}
local function clear_archive()
    for key in pairs(archive_files) do
        archive_files[key] = nil
    end
end
package.preload["ffi/archiver"] = function()
    local Writer = {}
    function Writer:new() return setmetatable({}, { __index = self }) end
    function Writer:open(path)
        local file = assert(io.open(path, "wb"))
        file:write("partial")
        file:close()
        return true
    end
    function Writer:setZipCompression() return true end
    function Writer:addFileFromMemory(name, data)
        archive_files[name] = data
        return true
    end
    function Writer:addPath() return true end
    function Writer:close() end
    return { Writer = Writer }
end

local real_os_execute = os.execute
rawset(os, "execute", function() return 0 end)

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

do
    local settings = {
        cache_dir = ".",
        get = function(_self, _key, default) return default end,
    }
    clear_archive()
    local path = Content.save_book_epub(settings, {
        book_id = "book",
        title = "Tagged",
        cache_dir = ".",
    }, { { chapterUid = 1, title = "One" } }, { ["1"] = "<p>body</p>" }, "book")
    local opf = archive_files["OEBPS/content.opf"] or ""
    eq(opf:find("<dc:subject>weread</dc:subject>", 1, true) ~= nil, true,
        "full-book OPF includes dc:subject")
    eq(opf:find('name="keywords" content="weread"', 1, true) ~= nil, true,
        "full-book OPF includes keywords meta")
    if type(path) == "string" then pcall(os.remove, path) end

    clear_archive()
    local chapter_path = Content.save_chapter_epub(settings, {
        book_id = "book",
        title = "Tagged",
        cache_dir = ".",
    }, { chapterUid = 1, title = "One" }, "<p>body</p>")
    local chapter_opf = archive_files["OEBPS/content.opf"] or ""
    eq(chapter_opf:find("<dc:subject>weread</dc:subject>", 1, true) == nil, true,
        "chapter EPUB does not embed the weread subject")
    if type(chapter_path) == "string" then pcall(os.remove, chapter_path) end
end

rawset(os, "execute", real_os_execute)

print(string.format("weread_tag_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
