--[[--
Thought popup content builder.

Normalized review items (weread.lib.annotations records: abstract, author,
content, likes_count) become a widget-independent block tree consumed by
widget.lua:

    { kind="paragraph", variant=<quote|meta|content>, text=..., fg=gray level }

Size variants for each block live in face_factory.lua (VARIANTS); the gray
levels below match the WeRead reader's footnote styling.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local util = require("util")

local ContentBuilder = {}

-- Gray levels used by the popup blocks, indexed 0 (pure black) to 15
-- (lightest). The eInk palette is COLOR_GRAY_1..7 and COLOR_GRAY_9 plus the
-- COLOR_DARK_GRAY / COLOR_GRAY / COLOR_GRAY_B / COLOR_LIGHT_GRAY /
-- COLOR_GRAY_D / COLOR_GRAY_E / COLOR_WHITE aliases; keep the Color8 values
-- (isColor8 only accepts Color8 cdata).
local GRAY_LEVELS = {
    [0] = Blitbuffer.COLOR_BLACK,   --  0 (0x00)
    Blitbuffer.COLOR_GRAY_1,        --  1 (0x11)
    Blitbuffer.COLOR_GRAY_2,        --  2 (0x22)
    Blitbuffer.COLOR_GRAY_3,        --  3 (0x33)
    Blitbuffer.COLOR_GRAY_4,        --  4 (0x44)
    Blitbuffer.COLOR_GRAY_5,        --  5 (0x55)
    Blitbuffer.COLOR_GRAY_6,        --  6 (0x66)
    Blitbuffer.COLOR_GRAY_7,        --  7 (0x77)
    Blitbuffer.COLOR_DARK_GRAY,     --  8 (0x88)
    Blitbuffer.COLOR_GRAY_9,        --  9 (0x99)
    Blitbuffer.COLOR_GRAY,          -- 10 (0xAA)
    Blitbuffer.COLOR_GRAY_B,        -- 11 (0xBB)
    Blitbuffer.COLOR_LIGHT_GRAY,    -- 12 (0xCC)
    Blitbuffer.COLOR_GRAY_D,        -- 13 (0xDD)
    Blitbuffer.COLOR_GRAY_E,        -- 14 (0xEE)
    Blitbuffer.COLOR_WHITE,         -- 15 (0xFF)
}

--- Gray level -> Color8 value, clamped to the palette.
local function grayForLevel(level)
    level = math.max(0, math.min(15, level))
    return GRAY_LEVELS[level] or Blitbuffer.COLOR_GRAY_5
end

--- Apply the contrast delta to a base gray level. Level 0 is pure black and
--- 15 the lightest, so a positive delta (higher contrast) darkens the text
--- linearly and a negative delta lightens it. The maximum delta (9) pushes
--- every block down to pure black.
local function adjustedGray(level, contrast)
    local delta = tonumber(contrast) or 0
    return grayForLevel(level - delta)
end

--- UTF-8-safe truncation with an ellipsis suffix.
--- Character splitting uses koreader util.splitToChars (merges WTF-8 surrogate pairs).
local function truncateRunes(str, max_runes)
    if type(str) ~= "string" or type(max_runes) ~= "number" or max_runes <= 0 then
        return ""
    end
    local chars = util.splitToChars(str)
    if #chars <= max_runes then
        return str
    end
    local parts = {}
    for i = 1, max_runes do
        parts[i] = chars[i]
    end
    return table.concat(parts) .. "…"
end

--- Strip leading/trailing whitespace (including newlines and common Unicode
--- blanks). A trailing newline would add an extra empty line at the end of
--- the paragraph. WeRead data occasionally has \n+ZWNJ / ZWSP+\n / full-width
--- spaces; Lua %s only covers ASCII whitespace. Inner \n\n breaks are kept.
local function isEdgeBlankAt(s, i, len)
    local b = s:byte(i)
    if not b then return false, 0 end
    if b == 0x09 or b == 0x0A or b == 0x0B or b == 0x0C or b == 0x0D or b == 0x20 then
        return true, 1
    end
    if b == 0xC2 and i + 1 <= len and s:byte(i + 1) == 0xA0 then
        return true, 2
    end
    if b == 0xE2 and i + 2 <= len and s:byte(i + 1) == 0x80 then
        local b3 = s:byte(i + 2)
        if b3 == 0x8B or b3 == 0x8C then
            return true, 3
        end
    end
    if b == 0xE3 and i + 2 <= len and s:byte(i + 1) == 0x80 and s:byte(i + 2) == 0x80 then
        return true, 3
    end
    if b == 0xEF and i + 2 <= len and s:byte(i + 1) == 0xBB and s:byte(i + 2) == 0xBF then
        return true, 3
    end
    return false, 0
end

local function trimText(s)
    if type(s) ~= "string" then return s end
    local len = #s
    if len == 0 then return s end
    local start = 1
    while start <= len do
        local blank, n = isEdgeBlankAt(s, start, len)
        if not blank then break end
        start = start + n
    end
    local finish = len
    while finish >= start do
        local i = finish
        while i > start do
            local b = s:byte(i)
            if not b or b < 0x80 or b >= 0xC0 then break end
            i = i - 1
        end
        local blank, n = isEdgeBlankAt(s, i, len)
        if not blank or i + n - 1 ~= finish then break end
        finish = i - 1
    end
    if start == 1 and finish == len then return s end
    if start > finish then return "" end
    return s:sub(start, finish)
end

--- Quote rendering: first paragraph only (with an ellipsis when more
--- paragraphs follow), truncated to 50 runes, wrapped in 「」.
local function buildQuoteText(quote)
    if type(quote) ~= "string" or quote == "" then return nil end
    quote = trimText(quote)
    if quote == "" then return nil end
    local nl = quote:find("[\r\n]")
    if nl then
        local first = quote:sub(1, nl - 1)
        if quote:sub(nl + 1):match("%S") then
            quote = first .. "…"
        else
            quote = first
        end
    end
    local q = truncateRunes(quote, 50)
    return "「" .. q .. "」"
end

--- Build the block list for a thought popup.
--- @param items table[] review items { abstract, author, content, likes_count }
--- @param contrast number|nil contrast delta applied to every block's gray
---   level (positive darkens the text)
--- @return table[] blocks
function ContentBuilder.build(items, contrast)
    local blocks = {}
    if type(items) ~= "table" or #items == 0 then
        return blocks
    end

    local quote = buildQuoteText(items[1] and items[1].abstract)
    if quote then
        blocks[#blocks + 1] = {
            kind = "paragraph",
            variant = "quote",
            text = quote,
            fg = adjustedGray(6, contrast),
        }
    end

    for _, item in ipairs(items) do
        local meta = "▸ " .. tostring(item.author or "匿名")
        local likes = tonumber(item.likes_count) or 0
        if likes > 0 then
            meta = meta .. " · ♥ " .. tostring(likes)
        end
        blocks[#blocks + 1] = {
            kind = "paragraph",
            variant = "meta",
            text = meta,
            fg = adjustedGray(9, contrast),
        }

        local content = trimText(item.content or "")
        if content ~= "" then
            blocks[#blocks + 1] = {
                kind = "paragraph",
                variant = "content",
                text = content,
                fg = adjustedGray(5, contrast),
            }
        end
    end

    return blocks
end

return ContentBuilder
