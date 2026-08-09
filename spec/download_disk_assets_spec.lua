package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/reader/" .. tostring(book_id)
                .. "/" .. tostring(chapter_uid or "")
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end

local archive_calls = {}
local archive_should_fail = false
package.preload["ffi/archiver"] = function()
    local Writer = {}
    function Writer:new() return setmetatable({}, { __index = self }) end
    function Writer:open(path)
        self.path = path
        local file = assert(io.open(path, "wb"))
        file:write("partial archive")
        file:close()
        return true
    end
    function Writer:setZipCompression(method)
        archive_calls[#archive_calls + 1] = { kind = "compression", method = method }
        return true
    end
    function Writer:addFileFromMemory(name, data)
        archive_calls[#archive_calls + 1] = {
            kind = "memory", name = name, bytes = #data,
        }
        return true
    end
    function Writer:addPath(name, path, recursive)
        archive_calls[#archive_calls + 1] = {
            kind = "path", name = name, path = path, recursive = recursive,
        }
        if archive_should_fail then
            self.err = "injected archive failure"
            return false
        end
        -- Match KOReader's wrapper: a successful disk walk terminates at EOF
        -- and currently returns false without setting err.
        return false
    end
    function Writer:close() end
    return { Writer = Writer }
end
package.preload["ffi/util"] = function()
    return {
        purgeDir = function(path)
            return os.execute("rm -rf " .. string.format("%q", path))
        end,
    }
end
package.preload["lfs"] = function()
    return {
        attributes = function(path, attribute)
            local probe = io.popen("test -d " .. string.format("%q", path)
                .. " && echo directory")
            local mode = probe:read("*l")
            probe:close()
            if attribute == "mode" then return mode end
            return mode and { mode = mode } or nil
        end,
        dir = function(path)
            local listing = io.popen("ls -a " .. string.format("%q", path))
            return function()
                local name = listing:read("*l")
                if not name then listing:close() end
                return name
            end
        end,
    }
end

local Content = require("weread.lib.content")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local workspace = {
    path = root .. "/.weread-download-100-123456",
}
workspace.incoming_dir = workspace.path .. "/incoming"
workspace.asset_dir = workspace.path .. "/images"
assert(os.execute("mkdir -p " .. string.format("%q", workspace.incoming_dir)))
assert(os.execute("mkdir -p " .. string.format("%q", workspace.asset_dir)))

local function tar_header(name, size)
    local header = name .. string.rep("\0", 100 - #name)
    header = header .. string.rep("0", 24)
    local octal = string.format("%011o\0", size)
    header = header .. octal
    header = header .. string.rep("0", 20)
    header = header .. "0"
    return header .. string.rep("\0", 512 - #header)
end

local image_count = 24
local image_size = 256 * 1024
local fake_client = {}
function fake_client:download_to_file(_url, path)
    local file = assert(io.open(path, "wb"))
    for index = 1, image_count do
        local name = string.format("image-%03d.jpg", index)
        file:write(tar_header(name, image_size))
        file:write("\255\216\255", string.rep("x", image_size - 3))
        local padding = (512 - image_size % 512) % 512
        if padding > 0 then file:write(string.rep("\0", padding)) end
    end
    file:write(string.rep("\0", 1024))
    file:close()
    return path
end

collectgarbage("collect")
local before_kb = collectgarbage("count")
local assets, src_map = Content.download_chapter_assets_to_files(
    fake_client, { book_id = "book" },
    { chapterUid = 7, tar = "https://example.test/chapter.tar" },
    {}, workspace)
collectgarbage("collect")
local after_kb = collectgarbage("count")
expect(#assets == image_count, "not all TAR images were extracted")
expect(assets[1].data == nil and type(assets[1].path) == "string",
    "extracted image remained resident in an asset data field")
expect(src_map["image-001.jpg"] == "../images/image-001.jpg",
    "file-backed image map was wrong")
expect(after_kb - before_kb < 1024,
    "file-backed extraction retained resource-sized Lua memory")
local first = assert(io.open(assets[1].path, "rb"))
expect(first:read(3) == "\255\216\255", "extracted image bytes were corrupted")
first:close()
expect(io.open(workspace.incoming_dir .. "/chapter-7.tar", "rb") == nil,
    "source TAR was not removed after extraction")

local settings = {
    cache_dir = root,
    get = function(_self, _key, default) return default end,
}
local book = { book_id = "book", title = "Disk Assets", cache_dir = root }
local output = Content.save_book_epub(settings, book,
    { { chapterUid = 7, title = "Chapter" } },
    { ["7"] = "<p>body</p>" }, "book", assets, "body{}")
local used_path = false
local path_calls = 0
for _, call in ipairs(archive_calls) do
    if call.kind == "path" then
        path_calls = path_calls + 1
        if call.name == "OEBPS/images" then
            used_path = call.path == workspace.asset_dir
                and call.recursive == true
        end
    end
end
expect(used_path and path_calls == 1,
    "EPUB writer did not stream the staged image directory with one addPath")
expect(io.open(output .. ".part", "rb") == nil,
    "successful EPUB build left a partial archive")

local old = assert(io.open(output, "wb"))
old:write("known-good-old-epub")
old:close()
archive_should_fail = true
local ok = pcall(function()
    Content.save_book_epub(settings, book,
        { { chapterUid = 7, title = "Chapter" } },
        { ["7"] = "<p>body</p>" }, "book", assets, "body{}")
end)
expect(not ok, "injected archive failure was not propagated")
old = assert(io.open(output, "rb"))
expect(old:read("*a") == "known-good-old-epub",
    "failed atomic build damaged the previous EPUB")
old:close()
expect(io.open(output .. ".part", "rb") == nil,
    "failed EPUB build left a partial archive")

local stale = root .. "/.weread-download-200-654321"
assert(os.execute("mkdir -p " .. string.format("%q", stale)))
local orphan = assert(io.open(root .. "/orphan.epub.part", "wb"))
orphan:write("partial")
orphan:close()
local recovery_settings = {
    cache_dir = root,
    get = function(_self, key, default)
        if key == "books" then
            return { book = { book_id = "book", cache_dir = root } }
        end
        return default
    end,
}
local removed = Content.cleanup_stale_downloads(recovery_settings)
expect(removed == 3 and io.open(root .. "/orphan.epub.part", "rb") == nil,
    "startup recovery did not remove stale workspace and partial EPUB: "
        .. tostring(removed))

local lfs = require("lfs")
expect(lfs.attributes(workspace.path, "mode") == nil,
    "startup recovery did not remove the active-looking stale workspace")
assert(os.execute("rm -rf " .. string.format("%q", root)))
print(("download_disk_assets_spec: %d checks"):format(checks))
