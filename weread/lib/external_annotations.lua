-- Formal data model and XPointer locator for WeRead annotations on local books.
-- This module never edits the document and has no KOReader UI dependencies.
local Annotations = require("weread.lib.annotations")

local ExternalAnnotations = {}
ExternalAnnotations.SCHEMA_VERSION = 1
ExternalAnnotations.MAX_SEARCH_HITS = 16
ExternalAnnotations.FALLBACK_QUOTE_BYTES = 90

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    end
    return ""
end

function ExternalAnnotations.normalize_search(data)
    local output = {}
    local rows = type(data) == "table" and (data.results or data.books or data) or {}
    for _, row in ipairs(rows) do
        local candidates = type(row) == "table" and row.books or nil
        if type(candidates) ~= "table" then candidates = { row } end
        for _, candidate in ipairs(candidates) do
            local info = type(candidate) == "table"
                and (candidate.bookInfo or candidate) or {}
            local book_id = scalar(info.bookId or info.book_id)
            if book_id ~= "" then
                output[#output + 1] = {
                    book_id = book_id,
                    title = scalar(info.title),
                    author = scalar(info.author),
                    format = scalar(info.format),
                    source = info,
                }
            end
        end
    end
    return output
end

local function utf8_prefix(text, max_bytes)
    if #text <= max_bytes then return text end
    local cut = max_bytes
    while cut > 1 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut)
end

local function clean_quote(value)
    local text = scalar(value)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("[\226][\128][\139-\141]", "")
    return text
end

local function review_for_range(reviews, range)
    for _, review in ipairs(type(reviews) == "table" and reviews or {}) do
        if type(review) == "table" and tostring(review.range or "") == range then
            return review
        end
    end
end

function ExternalAnnotations.quote_for(underline, reviews)
    if type(underline) ~= "table" then return "" end
    for _, key in ipairs({ "markText", "bookmarkText", "rangeText", "abstract", "text" }) do
        local quote = clean_quote(underline[key])
        if quote ~= "" then return quote end
    end
    local review = review_for_range(reviews, tostring(underline.range or ""))
    local page = review and type(review.pageReviews) == "table"
        and review.pageReviews[1] or nil
    local item = page and (page.review or page) or nil
    return clean_quote(item and (item.abstract or item.contextAbstract or item.markText))
end

local function range_start(row)
    return tonumber(tostring(row and row.range or ""):match("^(%d+)")) or math.huge
end

local function search(document, quote)
    local ok, results = pcall(document.findAllText, document, quote, true, 0,
        ExternalAnnotations.MAX_SEARCH_HITS, false, 0)
    return ok and type(results) == "table" and results or {}
end

local function result_position(document, result)
    if type(result) ~= "table" or not result.start or not result["end"] then
        return nil
    end
    local ok, value = pcall(document.getPosFromXPointer, document, result.start)
    return ok and tonumber(value) or nil
end

local function choose_after(document, results, minimum)
    local selected, selected_pos
    for _, result in ipairs(results) do
        local pos = result_position(document, result)
        if pos and pos > minimum and (not selected_pos or pos < selected_pos) then
            selected, selected_pos = result, pos
        end
    end
    return selected, selected_pos
end

function ExternalAnnotations.locate(document, chapters)
    assert(type(document) == "table", "document is required")
    local records = {}
    local stats = { total = 0, located = 0, missing_text = 0, unmatched = 0, partial = 0 }
    local cursor = -math.huge

    for _, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        local underlines = {}
        for _, row in ipairs(type(chapter.underlines) == "table" and chapter.underlines or {}) do
            underlines[#underlines + 1] = row
        end
        table.sort(underlines, function(a, b) return range_start(a) < range_start(b) end)
        for _, underline in ipairs(underlines) do
            stats.total = stats.total + 1
            local range = tostring(underline.range or "")
            local quote = ExternalAnnotations.quote_for(underline, chapter.reviews)
            if quote == "" then
                stats.missing_text = stats.missing_text + 1
            else
                local results = search(document, quote)
                local partial = false
                if #results == 0 and #quote > ExternalAnnotations.FALLBACK_QUOTE_BYTES then
                    results = search(document,
                        utf8_prefix(quote, ExternalAnnotations.FALLBACK_QUOTE_BYTES))
                    partial = #results > 0
                end
                local result, pos = choose_after(document, results, cursor)
                if result then
                    cursor = pos
                    local review = review_for_range(chapter.reviews, range)
                    records[#records + 1] = {
                        id = table.concat({ tostring(chapter.book_id or ""),
                            tostring(chapter.chapter_uid or ""), range }, ":"),
                        pos0 = result.start,
                        pos1 = result["end"],
                        text = quote,
                        book_id = tostring(chapter.book_id or ""),
                        chapter_uid = tostring(chapter.chapter_uid or ""),
                        range = range,
                        items = review and Annotations.buildThoughtPopupItems(review) or {},
                        partial = partial or nil,
                    }
                    stats.located = stats.located + 1
                    if partial then stats.partial = stats.partial + 1 end
                else
                    stats.unmatched = stats.unmatched + 1
                end
            end
        end
    end
    return records, stats
end

return ExternalAnnotations
