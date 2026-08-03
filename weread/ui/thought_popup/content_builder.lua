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

local ContentBuilder = {}

--- UTF-8-safe truncation with an ellipsis suffix.
local function truncateRunes(str, max_runes)
    if type(str) ~= "string" or max_runes <= 0 then return "" end
    local parts = {}
    local count = 0
    local len = #str
    local i = 1
    while i <= len do
        local byte = str:byte(i)
        local rune_len
        if byte < 0x80 then
            rune_len = 1
        elseif byte < 0xE0 then
            rune_len = 2
        elseif byte < 0xF0 then
            rune_len = 3
        else
            rune_len = 4
        end
        if count >= max_runes then
            return table.concat(parts) .. "…"
        end
        parts[#parts + 1] = str:sub(i, i + rune_len - 1)
        count = count + 1
        i = i + rune_len
    end
    return str
end

--- Trim surrounding whitespace (including newlines): a trailing newline would
--- make TextBoxWidget render an extra empty line at the end of the paragraph.
--- Inner blank lines (\n\n paragraph breaks) are preserved.
local function trimText(s)
    if type(s) ~= "string" then return s end
    return (s:match("^%s*(.-)%s*$") or "")
end

--- Quote rendering: first paragraph only (with an ellipsis when more
--- paragraphs follow), truncated to 50 runes, wrapped in 「」.
local function buildQuoteText(quote)
    if type(quote) ~= "string" or quote == "" then return nil end
    quote = quote:match("^%s*(.-)%s*$") or quote
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

    -- The first item's abstract is the quoted text (「」, gray, italic).
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
