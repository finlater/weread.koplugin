package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local files, directories, modified = {}, {}, {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            local attributes
            if directories[path] then
                attributes = { mode = "directory", size = 0, modification = 0 }
            elseif files[path] then
                attributes = {
                    mode = "file",
                    size = #files[path],
                    modification = modified[path] or 0,
                }
            end
            return field and attributes and attributes[field] or attributes
        end,
        mkdir = function(path)
            directories[path] = true
            return true
        end,
        dir = function(path)
            local names = { ".", ".." }
            local prefix = path .. "/"
            for file_path in pairs(files) do
                if file_path:sub(1, #prefix) == prefix then
                    names[#names + 1] = file_path:sub(#prefix + 1)
                end
            end
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
    }
end

local CoverCache = require("weread.lib.cover_cache")
local function open_file(path, mode)
    expect(mode == "wb", "cover cache did not use binary writes")
    local data
    return {
        write = function(_self, value) data = value return true end,
        close = function() files[path] = data return true end,
    }
end
local function rename_file(from, to)
    files[to], files[from] = files[from], nil
    modified[to] = modified[from] or 0
    modified[from] = nil
    return true
end
local function remove_file(path)
    if files[path] then files[path] = nil return true end
    return nil
end

local cache = CoverCache:new({ data_dir = "/data/weread" }, {
    open_file = open_file,
    rename_file = rename_file,
    remove_file = remove_file,
    render_thumbnail = function(source, target, width, height)
        expect(width == 300 and height == 450,
            "cover cache used the wrong thumbnail bounds")
        expect(files[source] ~= nil, "thumbnail source was not written first")
        files[target] = "\137PNG\r\n\26\n" .. string.rep("t", 20)
        return target
    end,
})
local book = { bookId = "one", cover = "https://cdn.example/one" }

expect(cache.dir == "/data/weread/shelf-covers", "cover cache used the wrong directory")
expect(cache:key(book) == cache:key(book) and #cache:key(book) == 32,
    "cover cache key was not a stable MD5 hash")
expect(cache:pathFor(book) == nil, "missing cover unexpectedly resolved to a file")

local jpeg = "\255\216\255" .. string.rep("j", 20)
local jpeg_path = assert(cache:store(book, jpeg))
expect(jpeg_path:match("%.thumb%.png$") and cache:pathFor(book) == jpeg_path,
    "JPEG cover was not converted to a bounded thumbnail")
expect(directories[cache.dir], "cover cache directory was not created")
files[jpeg_path] = ""
expect(cache:pathFor(book) == nil,
    "truncated cached cover was treated as renderable")
files[jpeg_path] = jpeg

local png_book = { cover = "https://cdn.example/two" }
local png = "\137PNG\r\n\26\n" .. string.rep("p", 20)
local png_path = assert(cache:store(png_book, png))
expect(png_path:match("%.thumb%.png$"), "PNG cover did not use the thumbnail suffix")
local legacy_book = { cover = "https://cdn.example/legacy" }
local legacy_path = cache.dir .. "/" .. cache:key(legacy_book) .. ".jpg"
files[legacy_path] = jpeg
expect(cache:sourcePathFor(legacy_book) == legacy_path,
    "legacy full-resolution cover was not found as a migration source")
local migrated_path = assert(cache:thumbnailFromCached(legacy_book))
expect(migrated_path:match("%.thumb%.png$") and files[legacy_path] == nil,
    "legacy cover was not replaced by a bounded thumbnail")
files[migrated_path] = nil
expect(cache:store({ cover = "https://cdn.example/bad" }, "not an image") == nil,
    "unsupported cover data was cached")
expect(cache:store({ cover = "https://cdn.example/tiny" }, "\255\216\255") == nil,
    "truncated image header was cached")

modified[jpeg_path], modified[png_path] = 1, 2
local removed = cache:prune(#files[png_path])
expect(removed == 1 and files[jpeg_path] == nil and files[png_path] ~= nil,
    "cover cache did not evict the oldest file at its size limit")

print(("cover_cache_spec: %d checks"):format(checks))
