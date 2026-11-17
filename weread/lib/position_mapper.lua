local PositionMapper = {}

-- Two pages of drift counts as the same position: each
-- device quantizes to its own pages, so a one-page window would ask on every
-- open. The comparison happens in chapter-fraction space, never in percentage
-- points, because a 2% window is worth a dozen pages in a long book.
local SAME_TOLERANCE_PAGES = 2

-- P5: same-chapter drift measured in text runes when both
-- sides expose a text offset. 800 runes ≈ two pages of 400 characters.
local TEXT_TOLERANCE_RUNES = 800

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function chapter_uid(chapter)
    return chapter and (chapter.chapterUid or chapter.chapterId or chapter.chapter_uid)
end

local function chapter_idx(chapter)
    return tonumber(chapter and (
        chapter.chapterIdx or chapter.chapterIndex or chapter.chapter_idx
    )) or 0
end

local function chapter_words(chapter)
    return math.max(0, tonumber(chapter and (
        chapter.wordCount or chapter.word_count or chapter.words
    )) or 0)
end

local function catalog(chapters)
    local result = {
        chapters = {},
        total_words = 0,
        by_uid = {},
    }
    for index, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        local words = chapter_words(chapter)
        local item = {
            source = chapter,
            index = index,
            uid = chapter_uid(chapter),
            chapter_idx = chapter_idx(chapter),
            words = words,
            before = result.total_words,
        }
        item.after = item.before + words
        result.chapters[#result.chapters + 1] = item
        result.total_words = item.after
        if item.uid ~= nil then
            result.by_uid[tostring(item.uid)] = item
        end
    end
    return result
end

local function find_progress_node(value, book_id, depth)
    if type(value) ~= "table" or (depth or 0) > 7 then
        return nil
    end
    local has_progress = value.progress ~= nil
        or value.readingProgress ~= nil
        or value.bookProgress ~= nil
    local value_book_id = value.bookId or value.book_id
    if has_progress and (value_book_id == nil
        or tostring(value_book_id) == tostring(book_id or "")) then
        return value
    end
    for _key, child in pairs(value) do
        if type(child) == "table" then
            local found = find_progress_node(child, book_id, (depth or 0) + 1)
            if found then return found end
        end
    end
    return nil
end

local function raw_field(value, ...)
    for index = 1, select("#", ...) do
        local key = select(index, ...)
        if value[key] ~= nil then return value[key] end
    end
    return nil
end

-- WeRead's chapterOffset is an offset into the chapter's
-- source HTML (htmlPos), not a word count -- the official client converts with
-- ChapterIndex.txt2html before reporting. Chapter length must therefore come
-- from the cached span index when available; wordCount remains the fallback for
-- chapters that were never downloaded.
-- There are three states, not two: the chapter's real html
-- length is known; it is unknown but a book-wide html-per-word ratio can put the
-- value in the same space; or nothing is known. Writing wordCount into `co` in
-- the third state stores an offset the cloud cannot tell apart from a real html
-- one, so the next pull scales it by the wrong factor. Keep the old word
-- behaviour only as the last resort.
-- Text-space conversion.
-- The annotation store keeps, per chapter, the full "html rune offset -> visible
-- text" mapping. `co` lives in the html space while reading progress lives in
-- the text space, so every conversion has to go through it; assuming the two are
-- proportional (co / htmlLen) is only right when markup is evenly spread.
local function space_for(item, options)
    if not item or item.uid == nil then return nil end
    local resolve = options and options.chapter_space
    if type(resolve) ~= "function" then return nil end
    local ok, space = pcall(resolve, item.uid)
    if not ok or type(space) ~= "table" then return nil end
    local html_len, text_len = tonumber(space.html_len), tonumber(space.text_len)
    if not html_len or not text_len or html_len <= 0 or text_len <= 0 then return nil end
    if type(space.to_html) ~= "function" or type(space.to_text) ~= "function" then return nil end
    return space
end

local function effective_len(item, options)
    if not item then return 0, "words" end
    local resolve = options and options.chapter_len
    if type(resolve) == "function" and item.uid ~= nil then
        local ok, value = pcall(resolve, item.uid)
        value = ok and tonumber(value) or nil
        if value and value > 0 then return value, "html" end
    end
    local words = tonumber(item.words) or 0
    local ratio = tonumber(options and options.chapter_ratio)
    if ratio and ratio > 0 and words > 0 then
        return words * ratio, "estimated"
    end
    return item.words, "words"
end

function PositionMapper.catalog(chapters)
    return catalog(chapters)
end

function PositionMapper.normalize_remote(value, book_id, source, chapters, options)
    local node = find_progress_node(value, book_id)
    if not node then return nil, "progress_not_found" end
    local percent = tonumber(raw_field(
        node, "progress", "readingProgress", "bookProgress"
    ))
    if not percent then return nil, "progress_invalid" end

    local raw_offset = raw_field(
        node, "chapterOffset", "chapterPos", "offset", "chapter_offset"
    )
    local remote = {
        book_id = raw_field(node, "bookId", "book_id") or book_id,
        percent = clamp(percent, 0, 100),
        raw_percent = percent,
        chapter_uid = raw_field(
            node, "chapterUid", "chapterId", "chapter_uid"
        ),
        chapter_idx = tonumber(raw_field(
            node, "chapterIdx", "chapterIndex", "chapter_idx"
        )) or 0,
        chapter_offset = math.max(0, tonumber(raw_offset) or 0),
        has_chapter_offset = raw_offset ~= nil
            and tonumber(raw_offset) ~= nil,
        updated_at = tonumber(raw_field(
            node, "updateTime", "updatedAt", "update_time"
        )) or 0,
        summary = raw_field(node, "summary", "chapterTitle") or "",
        source = source or "unknown",
    }

    local map = catalog(chapters)
    local item = remote.chapter_uid ~= nil
        and map.by_uid[tostring(remote.chapter_uid)] or nil
    local space = space_for(item, options)
    local len, len_kind = effective_len(item, options)
    if item and remote.has_chapter_offset
        and len > 0 and item.words > 0 and map.total_words > 0 then
        -- Turn `co` into a *text* fraction first. With spans
        -- that is exact; without them the html ratio stays as a fallback.
        local fraction, text_offset
        if space then
            text_offset = clamp(space.to_text(remote.chapter_offset), 0, space.text_len)
            fraction = text_offset / space.text_len
            remote.chapter_text_offset = text_offset
            remote.chapter_text_len = space.text_len
            remote.fraction_space = "text"
            len = space.html_len
        else
            fraction = clamp(remote.chapter_offset, 0, len) / len
        end
        remote.chapter_fraction = fraction
        remote.chapter_len = len
        remote.percent = clamp(
            (item.before + fraction * item.words) / map.total_words * 100,
            0,
            100
        )
        -- The word fallback behaves exactly like the old code, so it keeps
        -- the old basis name; only the html/text paths are new.
        remote.position_basis = (space or len_kind == "html") and "chapter_html_offset"
            or len_kind == "estimated" and "chapter_html_estimated"
            or "chapter_offset"
    else
        remote.position_basis = "raw_percent"
    end
    return remote
end

function PositionMapper.choose_remote(web, gateway, threshold)
    threshold = math.max(0, tonumber(threshold) or 2)
    if not web then return gateway end
    if not gateway then return web end

    local percent_gap = math.abs(
        (tonumber(web.percent) or 0) - (tonumber(gateway.percent) or 0)
    )
    local chapter_differs = web.chapter_uid ~= nil
        and gateway.chapter_uid ~= nil
        and tostring(web.chapter_uid) ~= tostring(gateway.chapter_uid)
    local conflict = percent_gap > threshold
        or (chapter_differs and percent_gap > 0.5)
    local selected
    if (tonumber(gateway.updated_at) or 0) > (tonumber(web.updated_at) or 0) then
        selected = gateway
    else
        selected = web
    end
    local result = {}
    for key, item in pairs(selected) do result[key] = item end
    result.conflict = conflict
    result.sources = { web = web, gateway = gateway }
    return result
end

-- One place builds the position record so every entry point (percent-based or
-- chapter-based) produces exactly the same shape.
local function make_position(selected, chapter_fraction, overall_fraction,
    options, map)
    local space = space_for(selected, options)
    local len, len_kind, offset, text_offset
    if space then
        -- The page fraction inside a chapter is a text
        -- fraction. Land it on text first, then map to the html offset `co`
        -- expects -- never multiply it by the html length directly.
        text_offset = clamp(
            math.floor(chapter_fraction * space.text_len + 0.5), 0, space.text_len)
        offset = clamp(math.floor(space.to_html(text_offset) + 0.5), 0, space.html_len)
        len, len_kind = space.html_len, "text"
    else
        len, len_kind = effective_len(selected, options)
        if len <= 0 then len = selected.words; len_kind = "words" end
        offset = clamp(math.floor(chapter_fraction * len), 0, len)
    end

    local pages = tonumber(options.document_pages)
    local words_span = options.is_full_book
        and map.total_words or selected.words
    local chapter_pages
    if pages and pages > 0 and words_span > 0 then
        local words_per_page = words_span / pages
        chapter_pages = math.max(1,
            math.floor(selected.words / words_per_page + 0.5))
    end

    return {
        -- Percent stays a float: the payload floors it once on the way out, and
        -- the caller needs the continuous value for comparison and for the jump.
        percent = clamp(overall_fraction, 0, 1) * 100,
        fraction = clamp(overall_fraction, 0, 1),
        chapter_uid = selected.uid,
        chapter_idx = selected.chapter_idx,
        chapter_offset = offset,
        chapter_text_offset = text_offset,
        chapter_text_len = space and space.text_len or nil,
        fraction_space = space and "text" or nil,
        chapter_fraction = space and (text_offset / space.text_len)
            or (len > 0 and offset / len or 0),
        chapter_len = len,
        position_basis = len_kind == "text" and "chapter_html_offset"
            or len_kind == "html" and "chapter_html_offset"
            or len_kind == "estimated" and "chapter_html_estimated"
            or "chapter_offset",
        chapter_words = selected.words,
        chapter_pages = chapter_pages,
        summary = tostring(options.summary or ""),
        safe = true,
        is_full_book = options.is_full_book == true,
    }
end

function PositionMapper.local_to_remote(chapters, fraction, options)
    options = options or {}
    local map = options.catalog or catalog(chapters)
    if map.total_words <= 0 then return nil, "catalog_empty" end
    fraction = clamp(fraction, 0, 1)

    local selected
    local chapter_fraction
    local overall_fraction
    if options.is_full_book then
        local target = fraction * map.total_words
        -- Cumulative word counts are nondecreasing. The first end strictly
        -- after the target also skips empty chapters at a boundary.
        local low, high = 1, #map.chapters
        while low <= high do
            local middle = math.floor((low + high) / 2)
            if target < map.chapters[middle].after then high = middle - 1
            else low = middle + 1 end
        end
        selected = map.chapters[low]
        if not selected then
            for index = #map.chapters, 1, -1 do
                if map.chapters[index].words > 0 then
                    selected = map.chapters[index]
                    break
                end
            end
        end
        if not selected then return nil, "catalog_empty" end
        chapter_fraction = selected.words > 0
            and clamp((target - selected.before) / selected.words, 0, 1)
            or 0
        overall_fraction = fraction
    else
        local uid = options.current_chapter_uid
        selected = uid ~= nil and map.by_uid[tostring(uid)] or nil
        if not selected or selected.words <= 0 then
            return nil, "current_chapter_not_found"
        end
        chapter_fraction = clamp(fraction, 0, 1)
        overall_fraction = (selected.before
            + chapter_fraction * selected.words) / map.total_words
    end

    return make_position(selected, chapter_fraction, overall_fraction,
        options, map)
end

-- Build a position from a chapter that is already known (TOC lookup) instead of
-- deriving it from a whole-book fraction.
function PositionMapper.chapter_position(chapters, chapter_uid, chapter_fraction,
    options)
    options = options or {}
    local map = options.catalog or catalog(chapters)
    if map.total_words <= 0 then return nil, "catalog_empty" end
    local selected = chapter_uid ~= nil
        and map.by_uid[tostring(chapter_uid)] or nil
    if not selected then return nil, "chapter_not_found" end
    local fraction = clamp(chapter_fraction, 0, 1)
    local overall = (selected.before + fraction * selected.words)
        / map.total_words
    return make_position(selected, fraction, overall, options, map)
end

function PositionMapper.remote_to_local(chapters, remote, options)
    options = options or {}
    if type(remote) ~= "table" then return nil, "remote_invalid" end
    local map = catalog(chapters)
    local target = remote.chapter_uid ~= nil
        and map.by_uid[tostring(remote.chapter_uid)] or nil
    local raw_percent = clamp(remote.percent, 0, 100) / 100
    local overall_fraction = raw_percent
    local chapter_fraction

    local has_offset = remote.has_chapter_offset ~= false
        and remote.chapter_offset ~= nil
    -- Each side must be divided by the length of its own coordinate space.
    -- Dividing an htmlPos offset by wordCount is what made the jump overshoot.
    local space = space_for(target, options)
    local len = effective_len(target, options)
    local text_offset
    if target and has_offset and len > 0 and target.words > 0 then
        -- Same conversion as the upload side: `co` -> text.
        if space then
            text_offset = clamp(space.to_text(remote.chapter_offset), 0, space.text_len)
            chapter_fraction = text_offset / space.text_len
        else
            chapter_fraction = clamp(remote.chapter_offset, 0, len) / len
        end
        if map.total_words > 0 then
            overall_fraction = (target.before
                + chapter_fraction * target.words) / map.total_words
        end
    end

    if options.is_full_book then
        return {
            fraction = clamp(overall_fraction, 0, 1),
            overall_fraction = clamp(overall_fraction, 0, 1),
            chapter = target and target.source or nil,
            chapter_uid = target and target.uid or nil,
            chapter_text_offset = text_offset,
            chapter_text_len = space and space.text_len or nil,
            fraction_space = space and "text" or nil,
            requires_chapter_open = false,
        }
    end

    local current_uid = options.current_chapter_uid
    local same_chapter = target and current_uid ~= nil
        and tostring(target.uid) == tostring(current_uid)
    if not target then
        return nil, "remote_chapter_not_found"
    end
    if chapter_fraction == nil then
        return nil, "remote_offset_unavailable"
    end
    return {
        fraction = clamp(chapter_fraction, 0, 1),
        overall_fraction = clamp(overall_fraction, 0, 1),
        chapter = target.source,
        chapter_uid = target.uid,
        chapter_text_offset = text_offset,
        chapter_text_len = space and space.text_len or nil,
        fraction_space = space and "text" or nil,
        same_chapter = same_chapter,
        requires_chapter_open = not same_chapter,
    }
end

-- Same-chapter drift is judged in chapter-fraction space,
-- with a window measured in pages rather than in percentage points.
local function fraction_tolerance(local_position)
    local pages = tonumber(local_position.chapter_pages)
    if not pages or pages <= 0 then return nil end
    -- Never let the window swallow a quarter chapter: short chapters, tiny page
    -- counts and bogus estimates must stay distinguishable.
    return math.min(SAME_TOLERANCE_PAGES / pages, 0.25)
end

function PositionMapper.compare(local_position, remote, threshold)
    if type(local_position) ~= "table" or type(remote) ~= "table" then
        return "unknown", 0
    end
    threshold = math.max(0, tonumber(threshold) or 2)
    local delta = (tonumber(remote.percent) or 0)
        - (tonumber(local_position.percent) or 0)

    local local_uid = local_position.chapter_uid
    local remote_uid = remote.chapter_uid
    local same_chapter = local_uid ~= nil and remote_uid ~= nil
        and tostring(local_uid) == tostring(remote_uid)
    -- P5: with both sides in text space, compare rune
    -- offsets directly. The old path needed `document_pages` and a words-per-page
    -- guess to size a chapter, which image-heavy chapters break.
    local local_text = tonumber(local_position.chapter_text_offset)
    local remote_text = tonumber(remote.chapter_text_offset)
    if same_chapter and local_text and remote_text then
        local cap = math.huge
        for _i, value in ipairs({ tonumber(local_position.chapter_text_len),
            tonumber(remote.chapter_text_len) }) do
            if value and value > 0 and value < cap then cap = value end
        end
        local tolerance = math.min(TEXT_TOLERANCE_RUNES, cap * 0.25)
        local rune_delta = remote_text - local_text
        if math.abs(rune_delta) <= tolerance then return "same", delta end
        return rune_delta > 0 and "remote_ahead" or "local_ahead", delta
    end

    local local_fraction = tonumber(local_position.chapter_fraction)
    local remote_fraction = tonumber(remote.chapter_fraction)
    local tolerance = same_chapter and fraction_tolerance(local_position) or nil
    if tolerance and local_fraction and remote_fraction then
        local chapter_delta = remote_fraction - local_fraction
        if math.abs(chapter_delta) <= tolerance then return "same", delta end
        -- Both fractions share one length basis, so the sign is reliable even
        -- when the integer percentages happen to agree.
        return chapter_delta > 0 and "remote_ahead" or "local_ahead", delta
    end

    if local_uid ~= nil and remote_uid ~= nil and not same_chapter
        and math.abs(delta) <= threshold then
        return "different", delta
    end
    if math.abs(delta) <= threshold then return "same", delta end
    return delta > 0 and "remote_ahead" or "local_ahead", delta
end

function PositionMapper.same_position(left, right, tolerance)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    tolerance = math.max(0, tonumber(tolerance) or 0.5)
    return math.abs((tonumber(left.percent) or 0) - (tonumber(right.percent) or 0))
            <= tolerance
        and tostring(left.chapter_uid or "") == tostring(right.chapter_uid or "")
        and math.abs((tonumber(left.chapter_offset) or 0)
            - (tonumber(right.chapter_offset) or 0)) <= 1
end

return PositionMapper
