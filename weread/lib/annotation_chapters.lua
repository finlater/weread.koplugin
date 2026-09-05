-- Chapter identity and bounds, independent of the book download form.
local Chapters = {}
function Chapters.uid(chapter)
    return tostring(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid or "")
end
local UPDATE_SUFFIX_KEYWORDS = { "更", "求", "订", "阅", "票", "藏", "赏" }

local function has_update_keyword(text)
    for _i, keyword in ipairs(UPDATE_SUFFIX_KEYWORDS) do
        if text:find(keyword, 1, true) then return true end
    end
    return false
end

-- Strips a trailing （…）or (…) group that contains an update keyword.  Uses a
-- byte scan instead of Lua patterns, whose character classes operate on bytes
-- and would truncate multi-byte UTF-8 characters.  Paren positions point at
-- the first byte of each paren.
local function strip_update_suffix(title)
    for _ = 1, 3 do
        local close
        for i = #title, 1, -1 do
            local b = title:byte(i)
            if b == 0x29 then -- )
                close = i
                break
            end
            if b == 0x89 and i >= 3 -- ） (EF BC 89)
                and title:byte(i - 1) == 0xBC and title:byte(i - 2) == 0xEF then
                close = i - 2
                break
            end
        end
        if not close then return title end
        local open, open_len
        for i = close, 1, -1 do
            local b = title:byte(i)
            if b == 0x28 then -- (
                open, open_len = i, 1
                break
            end
            if b == 0x88 and i >= 3 -- （ (EF BC 88)
                and title:byte(i - 1) == 0xBC and title:byte(i - 2) == 0xEF then
                open, open_len = i - 2, 3
                break
            end
        end
        if not open then return title end
        local inner = title:sub(open + open_len, close - 1)
        if not has_update_keyword(inner) then return title end
        title = title:sub(1, open - 1)
    end
    return title
end

local function normalized_chapter_title(value)
    local title = tostring(value or "")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    -- Normalize full-width punctuation and spaces to ASCII up front so the
    -- patterns below never place multi-byte characters inside a class.
    title = title:gsub("\xE3\x80\x80", " ") -- full-width space U+3000
    title = title:gsub("\xEF\xBC\x9A", ":") -- full-width colon ：
    title = title:gsub("\xE3\x80\x81", ",") -- ideographic comma 、
    for _, marker in ipairs({ "章", "节", "回" }) do
        local stripped, count = title:gsub(
            "^第.-" .. marker .. "[%s:%.%-]*", "", 1)
        if count > 0 then
            title = stripped
            break
        end
    end
    title = title:gsub(
        "^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%divxlcdmIVXLCDM%d]+[%s:%.%-]*", "")
    title = strip_update_suffix(title)
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title:gsub("%s+", " ")
end


Chapters.normalize = normalized_chapter_title

function Chapters.documentEnd(document)
    if not document.getPageCount or not document.getPageXPointer
        or not document.getNextVisibleWordEnd then return nil end
    local ok, xp = pcall(function()
        return document:getPageXPointer(document:getPageCount())
    end)
    if not ok or not xp then return nil end
    local last
    for _ = 1, 10000 do
        local success, next_xp = pcall(document.getNextVisibleWordEnd, document, xp)
        if not success then return nil end
        if not next_xp or next_xp == xp then return last end
        last, xp = next_xp, next_xp
    end
end

function Chapters.map(document, catalog, descriptor)
    local ok, toc = pcall(document.getToc, document)
    toc = ok and type(toc) == "table" and toc or {}
    local by_title, by_exact = {}, {}
    for index, item in ipairs(toc) do
        local norm = normalized_chapter_title(item.title)
        by_title[norm] = by_title[norm] or {}
        table.insert(by_title[norm], index)
        local exact = tostring(item.title or "")
        by_exact[exact] = by_exact[exact] or {}
        table.insert(by_exact[exact], index)
    end
    local ranges, selected, matched, previous = {}, {}, {}, 0
    local allowed
    if descriptor then
        allowed = {}
        for _, chapter in ipairs(descriptor.chapters or {}) do
            allowed[Chapters.uid(chapter)] = true
        end
        -- Download manifests are authoritative, including partial/noncontiguous
        -- selections. Their TOC is generated in exactly the same order.
        catalog = descriptor.chapters or {}
    end
    for index, chapter in ipairs(catalog) do
        local uid = Chapters.uid(chapter)
        local candidates = by_exact[tostring(chapter.title or "")]
            or by_title[normalized_chapter_title(chapter.title)] or {}
        local chosen
        if descriptor and toc[index] then
            chosen = index
        else
            for _, candidate in ipairs(candidates) do
                if candidate > previous then chosen = candidate; break end
            end
        end
        if chosen and toc[chosen].xpointer then
            matched[#matched + 1] = { chapter = chapter, index = chosen }
            previous = chosen
        end
        if not allowed or allowed[uid] then selected[#selected + 1] = chapter end
    end
    local doc_end = Chapters.documentEnd(document)
    for index, match in ipairs(matched) do
        local entry = toc[match.index]
        local next_match = matched[index + 1]
        local end_xp = next_match and toc[next_match.index].xpointer
        -- Stop at an intervening sibling even if its title could not be
        -- matched. Child sections belong to this chapter unless they themselves
        -- are the next matched remote chapter.
        for j = match.index + 1, next_match and next_match.index or #toc do
            if (tonumber(toc[j].depth) or 1) <= (tonumber(entry.depth) or 1) then
                end_xp = toc[j].xpointer
                break
            end
        end
        ranges[Chapters.uid(match.chapter)] = {
            start_xpointer = entry.xpointer, end_xpointer = end_xp or doc_end,
            title = entry.title,
        }
    end
    return selected, ranges
end

function Chapters.descriptor(book, path)
    if not book then return nil end
    local explicit = book.annotation_documents and book.annotation_documents[path]
    if explicit then return explicit end
    local selected = {}
    for _, chapter in ipairs(book.chapters or {}) do
        if book.cached_chapters and book.cached_chapters[Chapters.uid(chapter)] == path then
            selected[#selected + 1] = chapter
        end
    end
    if #selected > 0 then return { chapters = selected, legacy = true } end
    -- Legacy combined EPUBs have no trustworthy full/partial distinction.
    -- The caller maps their actual TOC and only includes chapters with bounds.
end
return Chapters
