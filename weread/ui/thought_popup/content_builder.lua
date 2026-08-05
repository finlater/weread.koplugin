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
--- @return table[] blocks
function ContentBuilder.build(items)
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
            fg = Blitbuffer.COLOR_GRAY_6,
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
            fg = Blitbuffer.COLOR_GRAY_9,
        }

        local content = trimText(item.content or "")
        if content ~= "" then
            blocks[#blocks + 1] = {
                kind = "paragraph",
                variant = "content",
                text = content,
                fg = Blitbuffer.COLOR_GRAY_5,
            }
        end
    end

    return blocks
end

return ContentBuilder
