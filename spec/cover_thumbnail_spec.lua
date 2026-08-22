package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local freed, scaled_to, written_to = {}, nil, nil
local function buffer(width, height, name)
    return {
        getWidth = function() return width end,
        getHeight = function() return height end,
        -- Real KOReader writePNG returns nil on success.
        writePNG = function(_self, path) written_to = path end,
        free = function() freed[name] = (freed[name] or 0) + 1 end,
    }
end

local source = buffer(1200, 1800, "source")
local scaled = buffer(300, 450, "scaled")
package.preload["ui/renderimage"] = function()
    return {
        renderImageFile = function(_self, path)
            expect(path == "/tmp/source.png", "thumbnail renderer opened the wrong source")
            return source
        end,
        scaleBlitBuffer = function(_self, image, width, height)
            expect(image == source, "thumbnail renderer scaled the wrong buffer")
            scaled_to = { width, height }
            return scaled
        end,
    }
end

local Thumbnail = require("weread.lib.cover_thumbnail")
expect(Thumbnail.render("/tmp/source.png", "/tmp/thumb.png", 300, 450)
        == "/tmp/thumb.png", "thumbnail renderer did not return its output path")
expect(scaled_to[1] == 300 and scaled_to[2] == 450,
    "large portrait cover was not bounded to 300x450")
expect(written_to == "/tmp/thumb.png", "thumbnail PNG used the wrong target")
expect(freed.source == 1 and freed.scaled == 1,
    "thumbnail renderer leaked decoded image buffers")

print(("cover_thumbnail_spec: %d checks"):format(checks))
