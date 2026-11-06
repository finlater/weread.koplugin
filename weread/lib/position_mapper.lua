local PositionMapper = {}

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
local function effective_len(item, options)
    if not item then return 0, false end
    local resolve = options and options.chapter_len
    if type(resolve) == "function" and item.uid ~= nil then
        local ok, value = pcall(resolve, item.uid)
        value = ok and tonumber(value) or nil
        if value and value > 0 then return value, true end
    end
    return item.words, false
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
    local len, is_html = effective_len(item, options)
    if item and remote.has_chapter_offset
        and len > 0 and item.words > 0 and map.total_words > 0 then
        -- chapterOffset is an htmlPos offset; turn it into a chapter fraction
        -- first so the book percentage stays in word units.
        local fraction = clamp(remote.chapter_offset, 0, len) / len
        remote.percent = clamp(
            (item.before + fraction * item.words) / map.total_words * 100,
            0,
            100
        )
        -- The word fallback behaves exactly like the old code, so it keeps
        -- the old basis name; only the html path is new.
        remote.position_basis = is_html and "chapter_html_offset"
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

-- One place builds the position record, so the upload path and the pull path
-- cannot disagree about where a position is.
local function make_position(selected, chapter_fraction, overall_fraction,
    options, map)
    local len = effective_len(selected, options)
    if len <= 0 then len = selected.words end
    local offset = clamp(math.floor(chapter_fraction * len), 0, len)

    return {
        -- Percent stays a float: the payload floors it once on the way out, and
        -- the caller needs the continuous value for comparison and for the jump.
        percent = clamp(overall_fraction, 0, 1) * 100,
        fraction = clamp(overall_fraction, 0, 1),
        chapter_uid = selected.uid,
        chapter_idx = selected.chapter_idx,
        chapter_offset = offset,
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
    local len = effective_len(target, options)
    if target and has_offset and len > 0 and target.words > 0 then
        chapter_fraction = clamp(remote.chapter_offset, 0, len) / len
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
        same_chapter = same_chapter,
        requires_chapter_open = not same_chapter,
    }
end

function PositionMapper.compare(local_position, remote, threshold)
    if type(local_position) ~= "table" or type(remote) ~= "table" then
        return "unknown", 0
    end
    threshold = math.max(0, tonumber(threshold) or 2)
    local delta = (tonumber(remote.percent) or 0)
        - (tonumber(local_position.percent) or 0)
    if local_position.chapter_uid ~= nil and remote.chapter_uid ~= nil
        and tostring(local_position.chapter_uid)
            ~= tostring(remote.chapter_uid)
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
