-- Unit tests for lib/scan.lua (local-cache scanner).
-- Run from the repo root with a plain Lua interpreter:
--   lua spec/scan_spec.lua

package.path = "./?.lua;" .. package.path
local Scan = require("lib.scan")

local NOW = 1700000000

local function is_mp(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

-- Build an lfs-like fake from a flat map of path -> "dir" | file size.
local function make_fs(spec)
    local nodes = {}
    for path, v in pairs(spec) do
        if v == "dir" then
            nodes[path] = { mode = "directory" }
        else
            nodes[path] = { mode = "file", size = v }
        end
    end
    local fs = {}
    function fs.attributes(path)
        return nodes[path]
    end
    function fs.dir(path)
        local node = nodes[path]
        if not node or node.mode ~= "directory" then
            error("not a directory: " .. tostring(path))
        end
        local children = {}
        local prefix = path .. "/"
        for p in pairs(nodes) do
            if p:sub(1, #prefix) == prefix and not p:sub(#prefix + 1):find("/") then
                table.insert(children, p:sub(#prefix + 1))
            end
        end
        table.sort(children)
        local i = 0
        return function()
            i = i + 1
            return children[i]
        end
    end
    return fs
end

local function scan(fs, books, allowed, dry_run)
    return Scan.scan_root({
        root = "/root",
        fs = fs,
        books = books,
        allowed = allowed,
        is_mp = is_mp,
        dry_run = dry_run,
        now = NOW,
    })
end

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

test("unmatched dir with content is never imported", function()
    local fs = make_fs({
        ["/root"] = "dir",
        ["/root/My Calibre Book"] = "dir",
        ["/root/My Calibre Book/book.epub"] = 1000,
        ["/root/My Calibre Book/cover.jpg"] = 50,
    })
    local books = {}
    local added, updated = scan(fs, books, {})
    eq(added, 0, "added")
    eq(updated, 0, "updated")
    eq(next(books), nil, "books untouched")
end)

test("matched book dir is imported with shelf metadata", function()
    local fs = make_fs({
        ["/root"] = "dir",
        ["/root/123456"] = "dir",
        ["/root/123456/small.epub"] = 100,
        ["/root/123456/big.epub"] = 2000,
    })
    local books = {}
    local allowed = { ["123456"] = { book_id = "123456", title = "三体", author = "刘慈欣" } }
    local added, updated = scan(fs, books, allowed)
    eq(added, 1, "added")
    eq(updated, 0, "updated")
    local rec = books["123456"]
    eq(rec ~= nil, true, "record created")
    eq(rec.cache_dir, "/root/123456", "cache_dir")
    eq(rec.cached_file, "/root/123456/big.epub", "largest epub tracked")
    eq(rec.title, "三体", "title from shelf")
    eq(rec.author, "刘慈欣", "author from shelf")
    eq(rec.updated_at, NOW, "updated_at stamped")
end)

test("matched MP dir is imported without cached_file", function()
    local fs = make_fs({
        ["/root"] = "dir",
        ["/root/MP_WXS_abc"] = "dir",
        ["/root/MP_WXS_abc/article1.html"] = 300,
    })
    local books = {}
    local allowed = { ["MP_WXS_abc"] = { book_id = "MP_WXS_abc", title = "某公众号" } }
    local added = scan(fs, books, allowed)
    eq(added, 1, "added")
    eq(books["MP_WXS_abc"].cached_file, nil, "no cached_file for MP")
    eq(books["MP_WXS_abc"].cache_dir, "/root/MP_WXS_abc", "cache_dir")
end)

test("matched dir with wrong content type is ignored", function()
    -- A regular book dir holding only html, and an MP dir holding only epub.
    local fs = make_fs({
        ["/root"] = "dir",
        ["/root/123456"] = "dir",
        ["/root/123456/page.html"] = 100,
        ["/root/MP_WXS_abc"] = "dir",
        ["/root/MP_WXS_abc/file.epub"] = 100,
    })
    local allowed = {
        ["123456"] = { book_id = "123456" },
        ["MP_WXS_abc"] = { book_id = "MP_WXS_abc" },
    }
    local added, updated = scan(fs, {}, allowed)
    eq(added, 0, "added")
    eq(updated, 0, "updated")
end)

test("dry run does not mutate books", function()
    local fs = make_fs({
        ["/root"] = "dir",
        ["/root/123456"] = "dir",
        ["/root/123456/book.epub"] = 100,
    })
    local books = {}
    local allowed = { ["123456"] = { book_id = "123456", title = "T" } }
    local added = scan(fs, books, allowed, true)
    eq(added, 1, "added counted")
    eq(next(books), nil, "books untouched")
end)

test("metadata-only record binding fresh content counts as added", function()
    -- A record created by viewing book details (title/author but no cache
    -- paths) is not "cached" yet, so importing a freshly copied epub is an add,
    -- not an update. Existing metadata is still preserved.
    local fs = make_fs({
        ["/root"] = "dir",
        ["/root/123456"] = "dir",
        ["/root/123456/book.epub"] = 100,
    })
    local books = {
        ["123456"] = { book_id = "123456", title = "手动标题", author = "某人" },
    }
    local allowed = { ["123456"] = { book_id = "123456", title = "书架标题", author = "书架作者" } }
    local d_added, d_updated = scan(fs, books, allowed, true)
    eq(d_added, 1, "dry-run added")
    eq(d_updated, 0, "dry-run updated")
    local added, updated = scan(fs, books, allowed)
    eq(added, 1, "added")
    eq(updated, 0, "updated")
    eq(books["123456"].cache_dir, "/root/123456", "cache_dir set")
    eq(books["123456"].cached_file, "/root/123456/book.epub", "cached_file set")
    eq(books["123456"].title, "手动标题", "title preserved")
    eq(books["123456"].author, "某人", "author preserved")
    eq(books["123456"].updated_at, NOW, "updated_at stamped as new")
end)

test("unreadable root returns zeros", function()
    local fs = make_fs({})
    local added, updated = scan(fs, {}, {})
    eq(added, 0, "added")
    eq(updated, 0, "updated")
end)

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then
    os.exit(1)
end
