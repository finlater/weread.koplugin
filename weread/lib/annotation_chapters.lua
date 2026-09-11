-- Chapter identity and bounds, independent of the book download form.
local Chapters = {}
function Chapters.uid(chapter)
    return tostring(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid or "")
end
local UPDATE_SUFFIX_KEYWORDS = { "更", "求", "订", "阅", "票", "藏", "赏" }
local CHAPTER_ENDINGS = { "章", "节", "回", "卷", "部", "集", "篇" }
local NUMBER_TOKENS = {
    "零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九",
    "十", "百", "千", "万", "两",
}

local function has_update_keyword(text)
    for _i, keyword in ipairs(UPDATE_SUFFIX_KEYWORDS) do
        if text:find(keyword, 1, true) then return true end
    end
    return false
end

local function strip_update_suffix(title)
    local function strip_group(value, opening, closing)
        local last_open, from = nil, 1
        while true do
            local pos = value:find(opening, from, true)
            if not pos then break end
            last_open, from = pos, pos + #opening
        end
        local close_at = #value - #closing + 1
        if last_open and close_at > last_open
            and value:sub(close_at, close_at + #closing - 1) == closing
            and has_update_keyword(value:sub(last_open + #opening, close_at - 1)) then
            return value:sub(1, last_open - 1)
        end
        return value
    end
    local previous
    repeat
        previous = title
        title = strip_group(title, "（", "）")
        title = strip_group(title, "(", ")")
    until title == previous
    return title
end

local function is_chapter_number(value)
    local original = tostring(value or "")
    if original == "" then return false end
    local number = original:gsub("%d", "")
    for _i, token in ipairs(NUMBER_TOKENS) do
        number = number:gsub(token, "")
    end
    return number == ""
end

local function strip_chapter_number(value)
    if value:sub(1, #"第") ~= "第" then return value end
    local rest = value:sub(#"第" + 1)
    local ending_pos, ending_len
    for _i, ending in ipairs(CHAPTER_ENDINGS) do
        local pos = rest:find(ending, 1, true)
        if pos and (not ending_pos or pos < ending_pos) then
            ending_pos, ending_len = pos, #ending
        end
    end
    if not ending_pos or ending_pos <= 1
        or not is_chapter_number(rest:sub(1, ending_pos - 1)) then
        return value
    end
    return rest:sub(ending_pos + ending_len)
end

local function normalized_chapter_title(value)
    local title = tostring(value or "")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    -- Normalize full-width punctuation and spaces to ASCII up front so the
    -- patterns below never place multi-byte characters inside a class.
    title = title:gsub("\xE3\x80\x80", " ") -- full-width space U+3000
    title = title:gsub("\xEF\xBC\x9A", ":") -- full-width colon ：
    title = title:gsub("\xE3\x80\x81", ",") -- ideographic comma 、
    title = title:gsub("\239\188([\144-\153])", function(digit)
        return string.char(digit:byte() - 96)
    end)
    title = strip_update_suffix(title)
    local stripped = strip_chapter_number(title)
    if stripped ~= title then
        stripped = stripped:gsub("^[%s,:%.%-]+", "")
            :gsub("^%s+", ""):gsub("%s+$", "")
        -- Keep short titles such as 上/下 tied to their chapter number.
        if #stripped >= 6 then title = stripped end
    end
    title = title:gsub(
        "^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%divxlcdmIVXLCDM%d]+[%s:%.%-]*", "")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title:gsub("%s+", " ")
end

local function is_outline_number(value)
    local original = tostring(value or "")
    if original == "" then return false end
    local number = original:gsub("%d", "")
        :gsub("[IVXLCDMivxlcdm]", "")
    for _, token in ipairs(NUMBER_TOKENS) do
        number = number:gsub(token, "")
    end
    return number == ""
end

-- Local EPUBs and WeRead catalogs often spell the same outline heading as
-- `二、标题`, `二 标题`, `二. 标题` or `（二）标题`. Keep the strict key as the
-- first choice, then use the title body as a conservative fallback. Very short
-- bodies retain their full title because headings such as `一、上` repeat often.
local function relaxed_chapter_title(value)
    local title = normalized_chapter_title(value)
    title = title:gsub("\xEF\xBC\x88", "(") -- full-width opening parenthesis （
    title = title:gsub("\xEF\xBC\x89", ")") -- full-width closing parenthesis ）
    title = title:gsub("\xEF\xBC\x8C", ",") -- full-width comma ，
    title = title:gsub("\xEF\xBC\x8E", ".") -- full-width full stop ．
    local number, rest = title:match("^%((.-)%)[%s,:%.%-]*(.+)$")
    if not number then
        number, rest = title:match("^([^,%s:%.%-%)]+)[,%s:%.%-%)]+(.+)$")
    end
    if number and rest and is_outline_number(number) then
        rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
        if #rest >= 6 then return rest end
    end
    return title
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
    local by_title, by_exact, by_relaxed = {}, {}, {}
    for index, item in ipairs(toc) do
        local norm = normalized_chapter_title(item.title)
        by_title[norm] = by_title[norm] or {}
        table.insert(by_title[norm], index)
        local relaxed = relaxed_chapter_title(item.title)
        by_relaxed[relaxed] = by_relaxed[relaxed] or {}
        table.insert(by_relaxed[relaxed], index)
        local exact = tostring(item.title or "")
        by_exact[exact] = by_exact[exact] or {}
        table.insert(by_exact[exact], index)
    end
    local remote_relaxed_counts = {}
    for _, chapter in ipairs(catalog) do
        local relaxed = relaxed_chapter_title(chapter.title)
        remote_relaxed_counts[relaxed] = (remote_relaxed_counts[relaxed] or 0) + 1
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
            or by_title[normalized_chapter_title(chapter.title)]
        if not candidates then
            local relaxed = relaxed_chapter_title(chapter.title)
            local local_candidates = by_relaxed[relaxed]
            -- A relaxed key is safe only when it identifies one chapter on
            -- both sides. Exact/strict duplicate titles still use TOC order.
            if remote_relaxed_counts[relaxed] == 1
                and local_candidates and #local_candidates == 1 then
                candidates = local_candidates
            end
        end
        candidates = candidates or {}
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
            title = entry.title, toc_index = match.index,
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
