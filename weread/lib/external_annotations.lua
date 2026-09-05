-- Formal data model and XPointer locator for WeRead annotations on local books.
-- This module never edits the document and has no KOReader UI dependencies.
local Annotations = require("weread.lib.annotations")
local logger = require("weread.lib.logger")

local ExternalAnnotations = {}
ExternalAnnotations.SCHEMA_VERSION = 2
ExternalAnnotations.MATCHER_VERSION = 2
ExternalAnnotations.MAX_SEARCH_HITS = 16
ExternalAnnotations.CHAPTER_SEARCH_HITS = 1
ExternalAnnotations.FALLBACK_QUOTE_BYTES = 90
ExternalAnnotations.PERF_TAG = "external_annotation_perf"

local PERF = ExternalAnnotations.PERF_TAG

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

local function clean_quote(value)
    local text = scalar(value)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("[\226][\128][\139-\141]", "")
    text = text:gsub("\239\187\191", "")
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

-- ---------------------------------------------------------------------------
-- Performance logging.  Every line carries the stable "external_annotation_perf"
-- token so a device log can be filtered with:
--   grep -n "external_annotation_perf" crash.log
-- Full quotation text is never logged: only the sequence number, the byte
-- length and a short non-cryptographic hash of the quote.

local function elapsed_ms(started)
    return (os.clock() - started) * 1000
end

local function perf(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    logger.info(PERF .. " " .. table.concat(parts, ""))
end

-- Short non-cryptographic fingerprint of a quote, for correlating perf logs.
-- Deliberately Lua 5.1/LuaJIT compatible (no `~` bitwise operators) and
-- overflow-safe: hash * 33 + byte stays far below 2^53 before the modulo.
local function short_hash(text)
    local hash = 5381
    for i = 1, #text do
        hash = (hash * 33 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

-- ---------------------------------------------------------------------------
-- Chapter text indexing.  A chapter bounded by two TOC XPointers is extracted
-- once (getTextFromXPointers is a plain DOM walk, no page formatting), quotes
-- are matched against a whitespace-normalized rendering in pure Lua, and a
-- A reverse visible-character walk maps flat-text byte offsets back to
-- XPointers.  Walking from the next chapter boundary avoids ambiguous TOC
-- element XPointers: CREngine may treat getNextVisibleChar(<heading element>)
-- as a move past the element rather than into its first text node.
-- This replaces one CREngine full-text search per underline, which CREngine
-- cannot bound to a chapter: findText with origin=0 always scans from the
-- current viewport page to the end of the book, and findAllText scans the
-- whole book.

local function char_len(byte)
    if byte < 0x80 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    return 4
end

-- Byte length of a whitespace character starting at text[i], or 0.  Kept
-- deliberately small (space, tab, line/paragraph separators and the common
-- Unicode spaces) so the walk stays in lockstep with the extracted text.
local function ws_len_at(text, i)
    local b = text:byte(i)
    if not b then return 0 end
    if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D
        or b == 0x0B or b == 0x0C then
        return 1
    end
    if b == 0xC2 and text:byte(i + 1) == 0xA0 then return 2 end -- U+00A0
    if b == 0xE2 and text:byte(i + 1) == 0x80 then
        local b3 = text:byte(i + 2)
        if b3 and (b3 >= 0x80 and b3 <= 0x8A) or b3 == 0xAF then return 3 end -- U+2000-200A / U+202F
    end
    if b == 0xE3 and text:byte(i + 1) == 0x80 and text:byte(i + 2) == 0x80 then
        return 3 -- U+3000
    end
    return 0
end

-- Downloaded EPUB chapters render converted footnote references as visible
-- bracketed numbers (for example, "[36]"). WeRead's annotation quotations
-- omit those generated labels, so they must not participate in matching.
local function footnote_marker_len_at(text, i)
    if text:byte(i) ~= 0x5B then return 0 end -- "["
    local start, stop = text:find("%[%d+%]", i)
    return start == i and stop - i + 1 or 0
end

local function ignored_footnote_bytes(text)
    local ignored = {}
    local i, n = 1, #text
    while i <= n do
        local marker_len = footnote_marker_len_at(text, i)
        if marker_len > 0 then
            for byte = i, i + marker_len - 1 do ignored[byte] = true end
            i = i + marker_len
        else
            i = i + char_len(text:byte(i))
        end
    end
    return ignored
end

-- Whitespace-agnostic rendering of a chapter text: paragraph separators,
-- spaces and punctuation-width spaces are removed so WeRead quotes match the
-- local EPUB text regardless of paragraph breaks and spacing.
function ExternalAnnotations.flatten_text(text)
    local chunks = {}
    local i, n = 1, #text
    while i <= n do
        local marker_len = footnote_marker_len_at(text, i)
        local wlen = marker_len == 0 and ws_len_at(text, i) or 0
        if marker_len > 0 then
            i = i + marker_len
        elseif wlen > 0 then
            i = i + wlen
        else
            local clen = char_len(text:byte(i))
            chunks[#chunks + 1] = text:sub(i, i + clen - 1)
            i = i + clen
        end
    end
    return table.concat(chunks)
end

-- Byte offsets of the next occurrence of quote in the flattened chapter text
-- at or after `from` (byte offset of the previous match's exclusive end).
-- Returns the quote's start byte offset and its exclusive end byte offset
-- (the start of the character after the quote), or nil.
function ExternalAnnotations.find_in_flat(flat, quote, from)
    local needle = ExternalAnnotations.flatten_text(quote)
    if needle == "" then return nil end
    local init = from and from > 0 and from or 1
    local s, e = flat:find(needle, init, true)
    if not s then return nil end
    return s, e + 1
end

local function char_start_before(text, byte_index)
    local index = byte_index
    while index > 1 do
        local byte = text:byte(index)
        if byte < 0x80 or byte >= 0xC0 then break end
        index = index - 1
    end
    return index
end

-- Reverse visible-character walk used to map flat-text byte offsets to
-- XPointers.  The next chapter's TOC XPointer is a stable exclusive boundary;
-- getPrevVisibleChar() from it lands on the final visible character of the
-- current chapter even when the current chapter's TOC XPointer names an
-- element instead of a text position.
function ExternalAnnotations.new_chapter_walk(document, extracted, end_xpointer)
    local flat_bytes = #ExternalAnnotations.flatten_text(extracted)
    return {
        document = document,
        extracted = extracted,
        xp = end_xpointer,
        ptr = #extracted,
        flat_byte = flat_bytes,
        xp_at = { [flat_bytes + 1] = end_xpointer },
        ignored_footnote_bytes = ignored_footnote_bytes(extracted),
        valid = true,
        n = #extracted,
    }
end

-- Advances walk until walk.xp_at[target_byte] (the XPointer of the character
-- starting at flat byte offset target_byte) is known.  Returns true on
-- success; marks the walk invalid and returns false when the walk diverges
-- from the extracted text (the caller must then fall back to whole-book
-- search).  Never moves the viewport.
function ExternalAnnotations.advance_chapter_walk(walk, target_byte)
    if not walk.valid then return false end
    if walk.xp_at[target_byte] then return true end
    local getPrevVisibleChar = walk.document.getPrevVisibleChar
    local extracted = walk.extracted
    local steps = 0
    while walk.ptr >= 1 and not walk.xp_at[target_byte] do
        steps = steps + 1
        if steps % 256 == 0 and walk.yield then walk.yield() end
        local char_start = char_start_before(extracted, walk.ptr)
        local byte = extracted:byte(char_start)
        if byte == 0x0A or byte == 0x0D then
            -- Block separator inserted by getTextFromXPointers: no visible
            -- character corresponds to it, so it consumes no walk step.
            walk.ptr = char_start - 1
        else
            local ok, previous_xp = pcall(getPrevVisibleChar,
                walk.document, walk.xp)
            if not ok or not previous_xp then
                walk.valid = false
                return false
            end
            walk.xp = previous_xp
            local clen = char_len(byte)
            if ws_len_at(extracted, char_start) == 0
                and not walk.ignored_footnote_bytes[char_start] then
                walk.flat_byte = walk.flat_byte - clen
                local offset = walk.flat_byte + 1
                if not walk.needed or walk.needed[offset] then walk.xp_at[offset] = walk.xp end
            end
            walk.ptr = char_start - 1
        end
    end
    if not walk.xp_at[target_byte] then
        walk.valid = false
        return false
    end
    return true
end

local function mapped_quote_matches(document, result, quote)
    if type(document.getTextFromXPointers) ~= "function" then return true end
    local ok, actual = pcall(document.getTextFromXPointers, document,
        result.start, result["end"])
    if type(document.clearSelection) == "function" then
        pcall(document.clearSelection, document)
    end
    return ok and type(actual) == "string"
        and ExternalAnnotations.flatten_text(actual)
            == ExternalAnnotations.flatten_text(quote)
end

-- ---------------------------------------------------------------------------
-- Fallback search paths.

-- Whole-book search.  Kept as the last resort for quotes that the chapter
-- text cannot explain.
local function search_all(document, quote)
    local ok, results = pcall(document.findAllText, document, quote, true, 0,
        ExternalAnnotations.MAX_SEARCH_HITS, false, 0)
    -- findAllText leaves its matches selected in the view; drop the marks so
    -- fallback matching never paints a transient highlight.
    if type(document.clearSelection) == "function" then
        pcall(document.clearSelection, document)
    end
    return ok and type(results) == "table" and results or {}
end

local pos_elapsed = 0

local function result_position(document, result)
    if type(result) ~= "table" or not result.start or not result["end"] then
        return nil
    end
    local started = os.clock()
    local ok, value = pcall(document.getPosFromXPointer, document, result.start)
    pos_elapsed = pos_elapsed + (os.clock() - started)
    return ok and tonumber(value) or nil
end

-- Cheap DOM-side XPointer comparison (no page formatting), when available.
local function compare_xps(document, a, b)
    if not a or not b or type(document.compareXPointers) ~= "function" then
        return nil
    end
    local ok, value = pcall(document.compareXPointers, document, a, b)
    if not ok then return nil end
    return value
end

-- True when start_xp (a candidate match start) lies inside
-- [range.start_xpointer, range.end_xpointer).
local function in_chapter_range(document, range, start_xp, end_xp)
    if not range or not range.start_xpointer then return true end
    local cmp = compare_xps(document, range.start_xpointer, start_xp)
    if cmp == nil then
        local start_pos = result_position(document, {
            start = range.start_xpointer, ["end"] = range.start_xpointer,
        })
        local pos = result_position(document, {
            start = start_xp, ["end"] = end_xp or start_xp,
        })
        if not start_pos or not pos or pos < start_pos then return false end
        if range.end_xpointer then
            local stop = result_position(document, {
                start = range.end_xpointer, ["end"] = range.end_xpointer,
            })
            if stop and pos >= stop then return false end
        end
        return true
    end
    if cmp == -1 then return false end
    if not range.end_xpointer then return true end
    local cmp_end = compare_xps(document, start_xp, range.end_xpointer)
    if cmp_end == nil or cmp_end ~= 1 then return false end
    if end_xp then
        local end_cmp = compare_xps(document, end_xp, range.end_xpointer)
        if end_cmp == -1 then return false end
    end
    return true
end

-- Earliest result at/after cursor_xp; strict advances beyond the prior start.
-- A nil cursor accepts the first
-- result. Prefers compareXPointers and falls back to rendered positions.
local function choose_after(document, results, cursor_xp, strict)
    local selected, selected_pos
    for _, result in ipairs(results) do
        local start_xp = result and result.start
        if start_xp then
            if not cursor_xp then
                if not selected then selected = result end
            else
                local cmp = compare_xps(document, cursor_xp, start_xp)
                if cmp == nil then
                    local pos = result_position(document, result)
                    local min_pos = result_position(document, {
                        start = cursor_xp, ["end"] = cursor_xp,
                    })
                    if pos and min_pos and (pos > min_pos or (not strict and pos == min_pos))
                        and (not selected_pos or pos < selected_pos) then
                        selected, selected_pos = result, pos
                    end
                elseif cmp == 1 or (not strict and cmp == 0) then
                    if not selected
                        or compare_xps(document, start_xp, selected.start) == 1 then
                        selected = result
                    end
                end
            end
        end
    end
    return selected
end

-- ---------------------------------------------------------------------------

-- Locates every downloaded underline of the given chapters.  options:
--   chapter_ranges      uid -> { start_xpointer, end_xpointer, title }
--   chapter_titles      uid -> WeRead catalog title (for perf logs)
--   chapter_local_titles uid -> matched local TOC title (for perf logs)
-- The caller is responsible for downloading the data; this function never
-- touches the network and never moves the reading position.
function ExternalAnnotations.locate(document, chapters, options)
    assert(type(document) == "table", "document is required")
    options = options or {}
    local records = options.resume and options.resume.records or {}
    local stats = options.resume and options.resume.stats or { total = 0, located = 0, missing_text = 0, unmatched = 0, partial = 0 }
    pos_elapsed = 0
    -- Whole-locate cursor for books without chapter ranges, so repeated
    -- quotes across chapters still resolve in document order.
    local global_cursor_xp = options.resume and options.resume.cursor_xp

    for _, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        local uid = tostring(chapter.chapter_uid or "")
        local book_id = tostring(chapter.book_id or "")
        local chapter_started = os.clock()
        local located_before = stats.located
        local unmatched_before = stats.unmatched
        local range = type(options.chapter_ranges) == "table"
            and options.chapter_ranges[uid] or nil
        local we_title = type(options.chapter_titles) == "table"
            and tostring(options.chapter_titles[uid] or "") or ""
        local local_title = type(options.chapter_local_titles) == "table"
            and tostring(options.chapter_local_titles[uid] or "") or ""

        local underlines = {}
        for _, row in ipairs(type(chapter.underlines) == "table" and chapter.underlines or {}) do
            underlines[#underlines + 1] = row
        end
        table.sort(underlines, function(a, b) return range_start(a) < range_start(b) end)
        if not options.resume then stats.total = stats.total + #underlines end

        -- Extract the chapter text once when both TOC bounds are known, so
        -- every quote can be located with pure Lua matching instead of one
        -- CREngine full-text search per underline.
        local flat, extracted
        local indexed = range and range.start_xpointer and range.end_xpointer
            and type(document.getTextFromXPointers) == "function"
            and type(document.getPrevVisibleChar) == "function"
        if indexed then
            local ok, text = pcall(document.getTextFromXPointers, document,
                range.start_xpointer, range.end_xpointer)
            if ok and type(text) == "string" and text ~= "" then
                extracted = text
                flat = ExternalAnnotations.flatten_text(text)
                if flat == "" then flat, extracted = nil, nil end
            end
            -- getTextFromXPointers marks a selection range in the view; clear
            -- it right away so syncing never paints a transient highlight.
            if type(document.clearSelection) == "function" then
                pcall(document.clearSelection, document)
            end
        end

        local walk = indexed and flat
            and ExternalAnnotations.new_chapter_walk(
                document, extracted, range.end_xpointer) or nil
        local search_origin = range and range.start_xpointer or global_cursor_xp
        if walk then walk.yield = options.yield end
        local cursor_byte = options.resume and options.resume.cursor_byte or 0
        local previous_range = options.resume and options.resume.previous_range
        local strict = false
        if walk then
            -- Retain coordinates only for requested endpoints, not every
            -- character of a long chapter. The reverse DOM walk is shared.
            walk.needed = {}
            local scan_cursor, scan_range = cursor_byte, previous_range
            for seq, underline in ipairs(underlines) do
                if seq >= (options.resume and options.resume.next_index or 1) then
                    local after = scan_range ~= nil and range_start(underline) > scan_range
                    local quote = ExternalAnnotations.quote_for(underline, chapter.reviews)
                    local first, last = ExternalAnnotations.find_in_flat(flat, quote,
                        scan_cursor + (after and 1 or 0))
                    if first then
                        walk.needed[first], walk.needed[last] = true, true
                        scan_cursor = first
                    end
                    scan_range = range_start(underline)
                end
            end
        end

        perf("book_id=", book_id, "chapter_uid=", uid,
            "we_title=\"", we_title, "\"", "local_title=\"", local_title, "\"",
            "start_xp=", tostring(range and range.start_xpointer ~= nil or false),
            "end_xp=", tostring(range and range.end_xpointer ~= nil or false),
            "indexed=", tostring(walk ~= nil),
            "underlines=", tostring(#underlines))

        -- Resolves one quote.  Returns result, partial, mode, hits.
        local function locate_quote(quote)
            -- 1. Chapter text index (fast path; never scans the book).
            if walk and walk.valid then
                local o0, o1 = ExternalAnnotations.find_in_flat(flat, quote, cursor_byte + (strict and 1 or 0))
                if o0 then
                    if ExternalAnnotations.advance_chapter_walk(walk, o0)
                        and ExternalAnnotations.advance_chapter_walk(walk, o1) then
                        local mapped = {
                            start = walk.xp_at[o0],
                            ["end"] = walk.xp_at[o1],
                        }
                        if mapped_quote_matches(document, mapped, quote) then
                            cursor_byte = o0
                            search_origin = mapped.start
                            return mapped, false, "chapter_text", 1
                        end
                        walk.valid = false
                    end
                    -- Walk diverged from the extracted text: fall through to
                    -- the whole-book path; the walk stays invalid.
                end
            end
            -- 3. Whole-book fallback.  The result is still range-filtered so
            -- out-of-chapter hits are never projected onto this chapter.
            local results = search_all(document, quote)
            local filtered = {}
            for _, candidate in ipairs(results) do
                if in_chapter_range(document, range, candidate.start, candidate["end"]) then
                    filtered[#filtered + 1] = candidate
                end
            end
            local result = choose_after(document, filtered, search_origin, strict)
            if result and in_chapter_range(document, range,
                    result.start, result["end"]) then
                search_origin = result.start
                return result, false, "findAllText", #results
            end
            return nil, false, "findAllText", #results
        end

        for seq, underline in ipairs(underlines) do
            if seq < (options.resume and options.resume.next_index or 1) then goto continue end
            strict = previous_range ~= nil and range_start(underline) > previous_range

            local quote_started = os.clock()
            local underline_range = tostring(underline.range or "")
            local quote = ExternalAnnotations.quote_for(underline, chapter.reviews)
            if quote == "" then
                stats.missing_text = stats.missing_text + 1
                perf("book_id=", book_id, "chapter_uid=", uid, "seq=", seq,
                    "mode=missing_text",
                    "ms=", string.format("%.1f", elapsed_ms(quote_started)))
            else
                local result, partial, mode, hits = locate_quote(quote)
                if result then
                    global_cursor_xp = result.start
                    local review = review_for_range(chapter.reviews, underline_range)
                    records[#records + 1] = {
                        id = table.concat({ book_id, uid, underline_range }, ":"),
                        pos0 = result.start,
                        pos1 = result["end"],
                        text = quote,
                        book_id = book_id,
                        chapter_uid = uid,
                        range = underline_range,
                        items = review and Annotations.buildThoughtPopupItems(review) or {},
                        partial = partial or nil,
                    }
                    stats.located = stats.located + 1
                    if partial then stats.partial = stats.partial + 1 end
                else
                    stats.unmatched = stats.unmatched + 1
                end
                perf("book_id=", book_id, "chapter_uid=", uid, "seq=", seq,
                    "len=", tostring(#quote), "hash=", short_hash(quote),
                    "mode=", mode, "hits=", tostring(hits),
                    "found=", tostring(result ~= nil), "partial=", tostring(partial),
                    "ms=", string.format("%.1f", elapsed_ms(quote_started)))
            end
            previous_range = range_start(underline)
            if options.checkpoint and (seq % 16 == 0 or seq == #underlines) then
                options.checkpoint({ records = records, stats = stats,
                    next_index = seq + 1, cursor_xp = search_origin,
                    cursor_byte = cursor_byte, previous_range = previous_range })
            end
            if options.yield and (seq % 16 == 0 or seq == #underlines) then
                options.yield(seq, #underlines, stats)
            end
            ::continue::
        end

        perf("book_id=", book_id, "chapter_uid=", uid, "stage=chapter",
            "located=", tostring(stats.located - located_before),
            "unmatched=", tostring(stats.unmatched - unmatched_before),
            "pos_ms=", string.format("%.3f", pos_elapsed * 1000),
            "chapter_ms=", string.format("%.1f", elapsed_ms(chapter_started)))
    end

    return records, stats
end

return ExternalAnnotations
