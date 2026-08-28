-- Bounded on-disk cache for bookshelf thumbnails.

local Crypto = require("weread.lib.crypto")
local lfs = require("libs/libkoreader-lfs")

local CoverCache = {}
CoverCache.__index = CoverCache

CoverCache.MAX_BYTES = 32 * 1024 * 1024
CoverCache.MAX_IMAGE_BYTES = 3 * 1024 * 1024
CoverCache.MIN_IMAGE_BYTES = 16
CoverCache.THUMBNAIL_WIDTH = 300
CoverCache.THUMBNAIL_HEIGHT = 450

local extensions = { "jpg", "png", "webp", "gif" }

local function image_extension(data)
    if type(data) ~= "string" then return nil end
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return "gif" end
    return nil
end

local function valid_cached_file(path)
    local attributes = lfs.attributes(path)
    return attributes and attributes.mode == "file"
        and (tonumber(attributes.size) or 0) >= CoverCache.MIN_IMAGE_BYTES
end

function CoverCache:new(settings, dependencies)
    dependencies = dependencies or {}
    return setmetatable({
        dir = (settings.data_dir or settings.cache_dir or ".") .. "/shelf-covers",
        open_file = dependencies.open_file or io.open,
        rename_file = dependencies.rename_file or os.rename,
        remove_file = dependencies.remove_file or os.remove,
        render_thumbnail = dependencies.render_thumbnail or function(...)
            return require("weread.lib.cover_thumbnail").render(...)
        end,
    }, self)
end

function CoverCache:key(book)
    local url = type(book) == "table" and book.cover or nil
    if type(url) ~= "string" or url == "" then return nil end
    return Crypto.md5_hex(url)
end

function CoverCache:pathFor(book)
    local key = self:key(book)
    if not key then return nil end
    local path = self.dir .. "/" .. key .. ".thumb.png"
    if valid_cached_file(path) then return path end
    return nil
end

-- Covers cached by the first cover-shelf release were stored at their source
-- resolution. Keep them as migration inputs, but never expose them to the UI.
function CoverCache:sourcePathFor(book)
    local key = self:key(book)
    if not key then return nil end
    for _, extension in ipairs(extensions) do
        local path = self.dir .. "/" .. key .. "." .. extension
        if valid_cached_file(path) then return path end
    end
    return nil
end

function CoverCache:_ensureDir()
    if lfs.attributes(self.dir, "mode") then return true end
    local created, mkdir_err = lfs.mkdir(self.dir)
    if created or lfs.attributes(self.dir, "mode") then return true end
    return nil, tostring(mkdir_err or "cover cache directory creation failed")
end

function CoverCache:_thumbnailFromSource(book, source)
    local key = self:key(book)
    if not key then return nil, "cover URL is missing" end
    local ready, dir_err = self:_ensureDir()
    if not ready then return nil, dir_err end

    local path = self.dir .. "/" .. key .. ".thumb.png"
    local temporary = self.dir .. "/" .. key .. ".thumb.part.png"
    self.remove_file(temporary)
    local rendered, render_result, render_err = pcall(
        self.render_thumbnail,
        source,
        temporary,
        self.THUMBNAIL_WIDTH,
        self.THUMBNAIL_HEIGHT
    )
    if not rendered or not render_result or not valid_cached_file(temporary) then
        self.remove_file(temporary)
        return nil, tostring(render_err or render_result or "cover thumbnail failed")
    end
    local renamed, rename_err = self.rename_file(temporary, path)
    if not renamed then
        self.remove_file(temporary)
        return nil, tostring(rename_err or "cover thumbnail commit failed")
    end

    -- Remove old full-resolution cache entries only after the thumbnail has
    -- been committed atomically.
    for _, extension in ipairs(extensions) do
        local legacy = self.dir .. "/" .. key .. "." .. extension
        if legacy ~= source then self.remove_file(legacy) end
    end
    if source ~= path then self.remove_file(source) end
    return path
end

function CoverCache:thumbnailFromCached(book)
    local cached = self:pathFor(book)
    if cached then return cached end
    local source = self:sourcePathFor(book)
    if not source then return nil, "cached cover source is missing" end
    return self:_thumbnailFromSource(book, source)
end

function CoverCache:store(book, data)
    local key = self:key(book)
    if not key then return nil, "cover URL is missing" end
    if type(data) ~= "string" or #data < self.MIN_IMAGE_BYTES then
        return nil, "cover response is empty or truncated"
    end
    if #data > self.MAX_IMAGE_BYTES then
        return nil, "cover response is too large"
    end
    local extension = image_extension(data)
    if not extension then return nil, "unsupported cover image" end
    local ready, dir_err = self:_ensureDir()
    if not ready then return nil, dir_err end
    local temporary = self.dir .. "/" .. key .. ".source.part." .. extension
    local file, open_err = self.open_file(temporary, "wb")
    if not file then return nil, tostring(open_err or "cover cache open failed") end
    local wrote, write_err = file:write(data)
    local closed, close_err = file:close()
    if not wrote or not closed then
        self.remove_file(temporary)
        return nil, tostring(write_err or close_err or "cover cache write failed")
    end
    local path, thumbnail_err = self:_thumbnailFromSource(book, temporary)
    if not path then self.remove_file(temporary) end
    return path, thumbnail_err
end

function CoverCache:prune(max_bytes)
    max_bytes = math.max(0, tonumber(max_bytes) or self.MAX_BYTES)
    if not lfs.attributes(self.dir, "mode") then return 0 end
    local files, total = {}, 0
    for name in lfs.dir(self.dir) do
        if name ~= "." and name ~= ".." and not name:match("%.part$") then
            local path = self.dir .. "/" .. name
            local attributes = lfs.attributes(path)
            if attributes and attributes.mode == "file" then
                local size = tonumber(attributes.size) or 0
                total = total + size
                files[#files + 1] = {
                    path = path,
                    size = size,
                    modified = tonumber(attributes.modification) or 0,
                }
            end
        end
    end
    if total <= max_bytes then return 0 end
    table.sort(files, function(a, b) return a.modified < b.modified end)
    local removed = 0
    for _, entry in ipairs(files) do
        if total <= max_bytes then break end
        if self.remove_file(entry.path) then
            total = total - entry.size
            removed = removed + 1
        end
    end
    return removed
end

return CoverCache
