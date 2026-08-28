-- Render bounded bookshelf thumbnails without involving ImageWidget's global
-- image cache. This module is used from a subprocess on real devices.

local RenderImage = require("ui/renderimage")

local Thumbnail = {}

local function free(buffer)
    if buffer and type(buffer.free) == "function" then
        pcall(buffer.free, buffer)
    end
end

function Thumbnail.render(source, target, max_width, max_height)
    max_width = math.max(1, math.floor(tonumber(max_width) or 300))
    max_height = math.max(1, math.floor(tonumber(max_height) or 450))

    local image, scaled
    local ok, result = xpcall(function()
        image = assert(RenderImage:renderImageFile(source, false, nil, nil),
            "cover decode failed")
        local width = math.max(1, tonumber(image:getWidth()) or 1)
        local height = math.max(1, tonumber(image:getHeight()) or 1)
        local ratio = math.min(1, max_width / width, max_height / height)
        local target_width = math.max(1, math.floor(width * ratio + 0.5))
        local target_height = math.max(1, math.floor(height * ratio + 0.5))

        if target_width ~= width or target_height ~= height then
            scaled = assert(RenderImage:scaleBlitBuffer(
                image, target_width, target_height, false), "cover scale failed")
        else
            scaled = image
        end
        -- KOReader's writePNG raises on failure and returns no value on success.
        scaled:writePNG(target)
        return target
    end, debug.traceback)

    if scaled ~= image then free(scaled) end
    free(image)
    if not ok then return nil, result end
    return result
end

return Thumbnail
