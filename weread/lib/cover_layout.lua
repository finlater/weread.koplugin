-- Pure geometry for a readable, screen-filling bookshelf cover grid.

local CoverLayout = {}

local function positive(value, fallback)
    value = tonumber(value)
    if not value or value <= 0 then return fallback end
    return value
end

local function nonnegative(value, fallback)
    value = tonumber(value)
    if not value or value < 0 then return fallback end
    return value
end

function CoverLayout.calculate(options)
    options = options or {}
    local width = positive(options.width, 600)
    local height = positive(options.height, 800)
    local size_scale = positive(options.size_scale, 1)
    local card_scale = positive(options.card_scale, math.sqrt(size_scale))
    local min_cell_width = math.max(1, positive(
        options.min_cell_width, math.ceil(170 * card_scale)
    ))
    local min_cell_height = math.max(1, positive(
        options.min_cell_height, math.ceil(210 * card_scale)
    ))
    local reserved_height = nonnegative(
        options.reserved_height, math.ceil(225 * size_scale)
    )
    local content_height = math.max(1, height - math.min(reserved_height, height - 1))
    local columns = math.max(1, math.floor(width / min_cell_width))
    local rows = math.max(1, math.floor(content_height / min_cell_height))
    return {
        columns = columns,
        rows = rows,
        page_size = columns * rows,
        cell_width = math.max(1, math.floor(width / columns)),
        cell_height = math.max(1, math.floor(content_height / rows)),
        content_height = content_height,
    }
end

return CoverLayout
