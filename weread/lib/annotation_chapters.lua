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

-- Resolve identity independently of catalog order. Only unique names are
-- automatic; duplicate names need a unique parent context.
function Chapters.map(document, catalog, descriptor)
    local ok, toc = pcall(document.getToc, document)
    toc = ok and type(toc) == "table" and toc or {}
    catalog = descriptor and descriptor.chapters or catalog
    local indexes, counts = { {}, {}, {} }, { {}, {}, {} }
    local function keys(title)
        return { tostring(title or ""), normalized_chapter_title(title), relaxed_chapter_title(title) }
    end
    local parents, stack = {}, {}
    for i, entry in ipairs(toc) do
        local depth = tonumber(entry.depth) or 1
        while #stack > 0 and (tonumber(toc[stack[#stack]].depth) or 1) >= depth do
            table.remove(stack)
        end
        parents[i] = stack[#stack]
        stack[#stack + 1] = i
        for n, key in ipairs(keys(entry.title)) do
            indexes[n][key] = indexes[n][key] or {}
            table.insert(indexes[n][key], i)
        end
    end
    for _, chapter in ipairs(catalog) do
        for n, key in ipairs(keys(chapter.title)) do counts[n][key] = (counts[n][key] or 0) + 1 end
    end
    local chosen, occupied, candidates = {}, {}, {}
    for i, chapter in ipairs(catalog) do
        local uid = Chapters.uid(chapter)
        local chapter_keys = keys(chapter.title)
        for n, key in ipairs(chapter_keys) do
            if indexes[n][key] then
                candidates[uid] = indexes[n][key]
                if key ~= "" and not descriptor and #indexes[n][key] == 1 and counts[n][key] == 1 then
                    local target = indexes[n][key][1]
                    if not occupied[target] then chosen[uid], occupied[target] = target, uid end
                end
                break
            end
        end
        if descriptor and toc[i] and not occupied[i] then
            chosen[uid], occupied[i] = i, uid
        end
    end
    -- Resolve duplicate children only inside an already identified parent.
    -- Avoid quadratic work for pathological catalogs of repeated headings.
    local scope, scope_counts = {}, {}
    stack = {}
    for i, chapter in ipairs(catalog) do
        local depth = tonumber(chapter.level) or 1
        while #stack > 0 and (tonumber(catalog[stack[#stack]].level) or 1) >= depth do
            table.remove(stack)
        end
        local uid = Chapters.uid(chapter)
        scope[uid] = tostring(stack[#stack] or 0) .. "\n" .. normalized_chapter_title(chapter.title)
        scope_counts[scope[uid]] = (scope_counts[scope[uid]] or 0) + 1
        stack[#stack + 1] = i
    end
    stack = {}
    for i, chapter in ipairs(catalog) do
        local depth = tonumber(chapter.level) or 1
        while #stack > 0 and (tonumber(catalog[stack[#stack]].level) or 1) >= depth do
            table.remove(stack)
        end
        local uid = Chapters.uid(chapter)
        local parent = stack[#stack] and chosen[Chapters.uid(catalog[stack[#stack]])]
        local options = candidates[uid] or {}
        if not chosen[uid] and parent and #options <= 32
            and scope_counts[scope[uid]] == 1 then
            local target, ambiguous
            for _, candidate in ipairs(options) do
                if parents[candidate] == parent and not occupied[candidate] then
                    if target then ambiguous = true end
                    target = candidate
                end
            end
            if target and not ambiguous then
                chosen[uid], occupied[target] = target, uid
            end
        end
        stack[#stack + 1] = i
    end
    local matched, selected, ranges = {}, {}, {}
    for _, chapter in ipairs(catalog) do
        local uid = Chapters.uid(chapter)
        local i = chosen[uid]
        if i and toc[i].xpointer then matched[#matched + 1] = { chapter = chapter, index = i } end
    end
    table.sort(matched, function(a, b) return a.index < b.index end)
    -- Compute sibling boundaries once, including unmapped local entries.
    local stops = {}
    stack = {}
    for i, entry in ipairs(toc) do
        while #stack > 0 and (tonumber(toc[stack[#stack]].depth) or 1) >= (tonumber(entry.depth) or 1) do
            stops[table.remove(stack)] = i
        end
        stack[#stack + 1] = i
    end
    local doc_end = Chapters.documentEnd(document)
    for i, match in ipairs(matched) do
        local entry = toc[match.index]
        local stop = stops[match.index]
        local next_match = matched[i + 1]
        if next_match and (not stop or next_match.index < stop) then stop = next_match.index end
        ranges[Chapters.uid(match.chapter)] = {
            start_xpointer = entry.xpointer, end_xpointer = stop and toc[stop].xpointer or doc_end,
            title = entry.title, toc_index = match.index,
        }
        selected[#selected + 1] = match.chapter
    end
    -- Preserve the existing API's unbound entries; callers filter by ranges.
    for _, chapter in ipairs(catalog) do
        if not ranges[Chapters.uid(chapter)] then selected[#selected + 1] = chapter end
    end
    return selected, ranges
end

-- Versioned range identity also invalidates checkpoints from older algorithms.
function Chapters.rangeKey(range)
    if not range then return nil end
    return "mapping-v2:" .. tostring(range.start_xpointer) .. "\n" .. tostring(range.end_xpointer)
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
