local PositionMapper = require("weread.lib.position_mapper")

local logger = require("weread.lib.logger").scoped("ProgressSync")

local ProgressSync = {}
ProgressSync.__index = ProgressSync

-- Rune helpers for the text-space conversion (P1/P4).
-- Lua has no utf8 library on this device, and `#s` counts bytes, so both the
-- conversion and the anchor extraction need the same counting rule.
local function rune_len(value)
    local text = tostring(value or "")
    local index, count = 1, 0
    while index <= #text do
        local byte = text:byte(index)
        local size = 1
        if byte and byte >= 0xF0 then size = 4
        elseif byte and byte >= 0xE0 then size = 3
        elseif byte and byte >= 0xC0 then size = 2 end
        index, count = index + size, count + 1
    end
    return count
end

local function rune_sub(text, from, count)
    text = tostring(text or "")
    count = tonumber(count) or 0
    if count <= 0 then return "" end
    local index, rune, started = 1, 0, nil
    while index <= #text and count > 0 do
        local byte = text:byte(index)
        local size = 1
        if byte and byte >= 0xF0 then size = 4
        elseif byte and byte >= 0xE0 then size = 3
        elseif byte and byte >= 0xC0 then size = 2 end
        rune = rune + 1
        if rune >= (tonumber(from) or 1) then
            started = started or index
            count = count - 1
            if count == 0 then return text:sub(started, index + size - 1) end
        end
        index = index + size
    end
    return started and text:sub(started) or ""
end

local OPEN_DELAY_SECONDS = 0.6
local RESUME_RECHECK_SECONDS = 5 * 60
local PULL_RETRY_DELAY_SECONDS = 15
local PULL_MAX_RETRIES = 3
local BUSY_RETRY_SECONDS = 2
local BUSY_RETRY_LIMIT = 10
local SAME_THRESHOLD_PERCENT = 2
local SOURCE_CONFLICT_THRESHOLD_PERCENT = 2

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

function ProgressSync:new(options)
    options = options or {}
    assert(options.settings, "progress sync settings are required")
    assert(options.client, "progress sync client is required")
    assert(options.scheduler, "progress sync scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")
    assert(type(options.get_book) == "function", "get_book callback is required")
    assert(type(options.get_chapters) == "function", "get_chapters callback is required")
    assert(type(options.get_file_context) == "function", "get_file_context callback is required")
    assert(type(options.run_online) == "function", "run_online callback is required")
    assert(type(options.upload_position) == "function", "upload_position callback is required")
    assert(type(options.goto_fraction) == "function", "goto_fraction callback is required")
    -- Optional P4 hook: jump to an exact piece of text
    -- instead of a whole-book percentage. Missing means "percent only".
    assert(type(options.open_chapter) == "function", "open_chapter callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        get_document = options.get_document,
        get_footer = options.get_footer,
        get_toc = options.get_toc,
        detect_book = options.detect_book,
        get_book = options.get_book,
        get_chapters = options.get_chapters,
        refresh_catalog = options.refresh_catalog,
        get_file_context = options.get_file_context,
        run_online = options.run_online,
        upload_position = options.upload_position,
        goto_fraction = options.goto_fraction,
        goto_anchor = options.goto_anchor,
        open_chapter = options.open_chapter,
        is_online = options.is_online or function() return true end,
        on_choice = options.on_choice or function(context)
            context.keep_local()
        end,
        notify = options.notify or function() end,
        now = options.now or os.time,
        state = "idle",
        generation = 0,
        pull_retry_token = 0,
        dirty = false,
        verified = false,
    }
    return setmetatable(object, self)
end

function ProgressSync:_config()
    return self.settings:get("sync", {})
end

function ProgressSync:_persist(book_id, patch)
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then return false end
    local books = self.settings:get("books", {})
    local book = books[book_id] or { book_id = book_id }
    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = copy(value)
        end
    end
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return true
end

function ProgressSync:_local_fraction()
    local document = self.get_document()
    if not document then return nil end

    local footer = self.get_footer and self.get_footer()
    local footer_value = footer and tonumber(footer.percent_finished)
    if footer_value then
        if footer_value > 1 then footer_value = footer_value / 100 end
        return math.max(0, math.min(1, footer_value))
    end

    local page
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if not page and type(document.getPageNumber) == "function" then
        local ok, value = pcall(document.getPageNumber, document)
        if ok then page = tonumber(value) end
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = tonumber(value) end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    local current_pos = tonumber(document.current_pos)
    local doc_height = tonumber(document.info and document.info.doc_height)
        or tonumber(document.doc_height)
    if current_pos and doc_height and doc_height > 0 then
        return math.max(0, math.min(1, current_pos / doc_height))
    end
    return nil
end

-- Chapter length in WeRead's chapterOffset space: the rune
-- length of the chapter's source HTML, taken from the annotation span index
-- that the downloader already writes to disk. Returns nil when the chapter was
-- never downloaded; callers then fall back to wordCount, which keeps the old
-- behaviour instead of making it worse.
-- Which book version a chapter's cached offsets describe.
-- WeRead bumps `updateTime` when the publisher replaces the text or its markup;
-- the cached spans then describe a chapter that no longer exists on the server,
-- so dividing the cloud's current `co` by their length would silently rescale
-- the position. Unknown on both sides means "trust the cache" (old behaviour).
function ProgressSync:_book_version(book_id)
    local cache = self._book_version_cache
    if cache and cache.book_id == book_id then return cache.value end
    local value
    local ok = pcall(function()
        local book = self.get_book and self.get_book(book_id) or nil
        if type(book) ~= "table" then return end
        local raw = book.updateTime or book.version or book.bookVersion
        if raw ~= nil and tostring(raw) ~= "" and tostring(raw) ~= "0" then
            value = tostring(raw)
        end
    end)
    if not ok then value = nil end
    self._book_version_cache = { book_id = book_id, value = value }
    return value
end

function ProgressSync:_chapter_source_version(book_id, uid)
    if not self.settings then return nil end
    local ok, entry = pcall(function()
        local Store = require("weread.lib.annotation_store")
        self.annotation_store = self.annotation_store or Store:new(self.settings)
        return self.annotation_store:get(
            tostring(book_id), "source_version", tostring(uid))
    end)
    if not ok or type(entry) ~= "table" then return nil end
    local value = tostring(entry.v or "")
    return value ~= "" and value or nil
end

-- Cached spans for one chapter, version-guarded (P3).
-- Returns nil when the chapter was never indexed or the cache predates the book
-- version it would be interpreted against.
function ProgressSync:_chapter_spans(book_id, uid)
    if not self.settings then return nil end
    local ok, spans = pcall(function()
        local Store = require("weread.lib.annotation_store")
        self.annotation_store = self.annotation_store
            or Store:new(self.settings)
        return self.annotation_store:get(
            tostring(book_id), "original", tostring(uid))
    end)
    if not ok or type(spans) ~= "table" or #spans == 0 then
        return nil, "source_cache_missing"
    end
    -- 单片 spans（纯文本书，Source.plain）也要留着：它的 html 与文本同空间，
    -- 换算是恒等映射，正好是 txt 书需要的。
    -- The cached length is only meaningful for the version it
    -- was measured on. A newer book means a different chapter text, so fall back
    -- to the estimated length instead of rescaling the cloud's offset.
    local cached_version = self:_chapter_source_version(book_id, uid)
    local current_version = self:_book_version(book_id)
    if cached_version and current_version
        and cached_version ~= current_version then
        logger.info("progress source cache is stale:", tostring(book_id),
            "chapter=", tostring(uid), "cached=", cached_version,
            "current=", current_version)
        return nil, "source_version_mismatch"
    end
    return spans
end

function ProgressSync:_read_chapter_html_len(book_id, uid)
    local space, reason = self:_chapter_space(book_id, uid)
    if space then return space.html_len end
    return nil, reason
end

-- P1: build the "html offset <-> visible text" mapping for
-- one chapter. Every offset conversion on both the upload and the pull side goes
-- through it, so the two ends finally share one ruler.
function ProgressSync:_chapter_space(book_id, uid)
    -- 键里必须带 book_id：章节 uid 在不同书之间会重复（都是 1、2、3…）。
    local key = tostring(book_id) .. ":" .. tostring(uid)
    local cache = self._chapter_space_cache
    if type(cache) ~= "table" then cache = {}; self._chapter_space_cache = cache end
    local hit = cache[key]
    if hit ~= nil then return hit or nil end
    local spans, reason = self:_chapter_spans(book_id, uid)
    if not spans then cache[key] = false; return nil, reason end

    -- 只保留「有可见文本」的片段，并让起止/rune 数三者同序，避免跳段后错位。
    local segments, html_len, text_len = {}, 0, 0
    for _i, span in ipairs(spans) do
        if type(span) == "table" then
            local start, stop = tonumber(span[1]), tonumber(span[2])
            local piece = type(span[3]) == "string" and span[3] or ""
            if stop and stop > html_len then html_len = stop end
            if start and stop and stop > start and piece ~= "" then
                local length = rune_len(piece)
                if length > 0 then
                    segments[#segments + 1] = {
                        start = start, stop = stop, runes = length, piece = piece,
                    }
                    text_len = text_len + length
                end
            end
        end
    end
    if html_len <= 0 or text_len <= 0 or #segments == 0 then
        cache[key] = false
        return nil
    end
    local pieces = {}
    for index = 1, #segments do pieces[index] = segments[index].piece end
    local text = table.concat(pieces)

    local function to_text(co)
        local offset, before = tonumber(co) or 0, 0
        for index = 1, #segments do
            local segment = segments[index]
            if offset <= segment.start then return before end
            if offset >= segment.stop then
                before = before + segment.runes
            else
                -- A segment can be longer in html than in text
                -- when it contains entities (&amp; stays raw in the cached span).
                -- Distribute proportionally so both ends stay exact.
                local within = offset - segment.start
                local span = segment.stop - segment.start
                if span == segment.runes then
                    return before + within
                end
                return before + math.floor(within * segment.runes / span)
            end
        end
        return before
    end

    local function to_html(text_offset)
        local offset, before = tonumber(text_offset) or 0, 0
        -- 章首就是章首：文本 0 之前只有标签，co 应写 0 而不是「第一个可见字的位置」。
        if offset <= 0 then return 0 end
        for index = 1, #segments do
            local segment = segments[index]
            if offset <= before then return segment.start end
            if offset <= before + segment.runes then
                local within = offset - before
                local span = segment.stop - segment.start
                if span == segment.runes then
                    return segment.start + within
                end
                return math.min(segment.stop,
                    segment.start + math.floor(within * span / segment.runes))
            end
            before = before + segment.runes
        end
        return html_len
    end

    local space = {
        html_len = html_len,
        text_len = text_len,
        text = text,
        to_text = to_text,
        to_html = to_html,
        text_at = function(offset, count)
            return rune_sub(text, (tonumber(offset) or 0) + 1, count)
        end,
    }
    -- 一部 1400 章的书不该把所有空间都留在内存里；开书/换书时清一次足够。
    local count = 0
    for _k in pairs(cache) do count = count + 1 end
    if count > 12 then
        cache = {}
        self._chapter_space_cache = cache
    end
    cache[key] = space
    return space
end

function ProgressSync:_chapter_space_resolver(book_id)
    return function(uid)
        local ok, space = pcall(self._chapter_space, self, book_id, uid)
        return ok and space or nil
    end
end

-- html-per-word ratio for books whose chapters were never
-- indexed (downloaded before the span cache existed -- the 39-volume omnibus is
-- one). Sampled from the indexed chapters around the book, through the same
-- memoised resolver, so opening such a book costs at most a few small reads.
local RATIO_SAMPLE_LIMIT = 3

function ProgressSync:_book_html_ratio(book_id, cached)
    if type(cached) ~= "table" then return nil end
    if cached.html_ratio ~= nil then return cached.html_ratio or nil end
    local samples = {}
    local catalog = cached.position_catalog
    local resolve = cached.chapter_len
    local chapters = type(catalog) == "table" and catalog.chapters or nil
    if type(chapters) == "table" and #chapters > 0
        and type(resolve) == "function" then
        local step = math.max(1, math.floor(#chapters / RATIO_SAMPLE_LIMIT))
        local index = step
        while index <= #chapters and #samples < RATIO_SAMPLE_LIMIT do
            local item = chapters[index]
            local words = tonumber(item and item.words) or 0
            if words > 0 and item.uid ~= nil then
                local ok, length = pcall(resolve, item.uid)
                length = ok and tonumber(length) or nil
                if length and length > 0 then
                    samples[#samples + 1] = length / words
                end
            end
            index = index + step
        end
    end
    local ratio
    if #samples > 0 then
        table.sort(samples)
        ratio = samples[math.floor((#samples + 1) / 2)]
    end
    cached.html_ratio = ratio or false
    return ratio
end

-- One resolver per open document, memoised per chapter: capture_local runs on
-- every page update and must not touch the database again for a known chapter.
function ProgressSync:_chapter_len_resolver(book_id)
    local cache = {}
    local function resolve(uid)
        local key = tostring(uid)
        local hit = cache[key]
        if hit ~= nil then return hit or nil end
        local value = self:_read_chapter_html_len(book_id, key)
        cache[key] = value or false
        return value
    end
    return resolve
end

-- percent_finished is pageno/pages, i.e. a *page* fraction.
-- In a book whose pages are not proportional to its text (an omnibus with
-- per-volume front matter, an image-heavy title) that number drifts away from
-- the real reading position and drags the uploaded chapter with it. KOReader's
-- TOC knows the actual chapter, so prefer it whenever it can be resolved.
local function normalize_title(value)
    local text = tostring(value or ""):lower()
    text = text:gsub("%s+", "")
    text = text:gsub("^[%(%[]?[%d%.、，,%-]+[%)%]]?", "")
    return text
end

function ProgressSync:_chapter_title_map(cached)
    if cached.title_map then return cached.title_map end
    local map = {}
    local catalog = cached.position_catalog
    for _, item in ipairs(catalog and catalog.chapters or {}) do
        local key = normalize_title(item.source and item.source.title)
        if key ~= "" then
            map[key] = map[key] or {}
            table.insert(map[key], item)
        end
    end
    cached.title_map = map
    return map
end

-- Walk a container entry (a volume title in an omnibus) down to the chapter
-- that holds the given fraction of that container's words.
local function resolve_block(block, fraction)
    local total = 0
    for _, item in ipairs(block) do total = total + item.words end
    if total <= 0 then return nil end
    local target = fraction * total
    local seen = 0
    for _, item in ipairs(block) do
        if target < seen + item.words or item == block[#block] then
            local inside = item.words > 0
                and math.max(0, math.min(1, (target - seen) / item.words))
                or 0
            return item, inside
        end
        seen = seen + item.words
    end
    return nil
end

function ProgressSync:_toc_position(chapters, cached, fraction, options)
    local toc = self.get_toc and self.get_toc()
    if type(toc) ~= "table" or type(toc.getTocIndexByPage) ~= "function" then
        return nil
    end
    local document = self.get_document()
    local page
    if document and type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if not page then return nil end

    local index_ok, index = pcall(toc.getTocIndexByPage, toc, page)
    local entries = toc.toc
    if not index_ok or not index or type(entries) ~= "table" then return nil end
    local entry = entries[index]
    if type(entry) ~= "table" or entry.title == nil then return nil end

    local key = normalize_title(entry.title)
    if key == "" then return nil end
    local candidates = self:_chapter_title_map(cached)[key]
    if not candidates then return nil end

    -- Titles repeat across volumes; the percent estimate picks the right one
    -- unless the two disagree by more than a volume, which is the case this
    -- whole mechanism exists to fix.
    local catalog = cached.position_catalog
    local estimate = (tonumber(fraction) or 0) * catalog.total_words
    local chosen = candidates[1]
    if #candidates > 1 then
        local best
        for _, item in ipairs(candidates) do
            local distance = math.abs(item.before - estimate)
            if not best or distance < best then best, chosen = distance, item end
        end
    end

    local page_ok, done = pcall(toc.getChapterPagesDone, toc, page)
    local total_ok, chapter_pages = pcall(toc.getChapterPageCount, toc, page)
    if not page_ok or not total_ok then return nil end
    done, chapter_pages = tonumber(done), tonumber(chapter_pages)
    if not chapter_pages or chapter_pages <= 0 then return nil end
    local inside_block = math.max(0,
        math.min(1, ((done or 0) + 1) / chapter_pages))

    -- A TOC that is far coarser than the catalog lists containers, not
    -- chapters: spread the page fraction over the container's words.
    local coarse = #entries * 2 < #catalog.chapters
    if coarse then
        local level = tonumber(chosen.source and chosen.source.level) or 1
        local block = { chosen }
        local start_index
        for block_index, item in ipairs(catalog.chapters) do
            if item == chosen then start_index = block_index; break end
        end
        if start_index then
            for block_index = start_index + 1, #catalog.chapters do
                local item = catalog.chapters[block_index]
                local item_level = tonumber(
                    item.source and item.source.level) or 1
                if item_level <= level then break end
                table.insert(block, item)
            end
        end
        if #block > 1 then
            local item, inside = resolve_block(block, inside_block)
            if not item then return nil end
            return PositionMapper.chapter_position(
                chapters, item.uid, inside, options)
        end
    end

    return PositionMapper.chapter_position(
        chapters, chosen.uid, inside_block, options)
end

function ProgressSync:capture_local()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then
        return nil, "document_not_weread"
    end
    book_id = tostring(book_id)
    local document = self.get_document()
    local path = document_path(document)
    if not document or not path then return nil, "document_unavailable" end
    local cached = self.document_context
    local book
    local chapters
    local current_chapter
    local is_full_book
    if cached and cached.book_id == book_id and cached.path == path then
        book = cached.book
        chapters = cached.chapters
        current_chapter = cached.current_chapter
        is_full_book = cached.is_full_book
    else
        book = self.get_book(book_id)
        if type(book) ~= "table" then return nil, "book_not_found" end
        chapters = self.get_chapters(book)
        if type(chapters) ~= "table" or #chapters == 0 then
            return nil, "catalog_unavailable"
        end
        local _index
        _index, current_chapter, is_full_book =
            self.get_file_context(book, path)
        self.document_context = {
            book_id = book_id,
            book = book,
            chapters = chapters,
            position_catalog = PositionMapper.catalog(chapters),
            chapter_len = self:_chapter_len_resolver(book_id),
            chapter_space = self:_chapter_space_resolver(book_id),
            current_chapter = current_chapter,
            is_full_book = is_full_book == true,
            path = path,
        }
        cached = self.document_context
    end
    if not cached.chapter_len then
        cached.chapter_len = self:_chapter_len_resolver(book_id)
    end
    if not cached.chapter_space then
        cached.chapter_space = self:_chapter_space_resolver(book_id)
    end
    if cached.html_ratio == nil then
        cached.html_ratio = self:_book_html_ratio(book_id, cached) or false
    end
    local fraction = self:_local_fraction()
    if fraction == nil then return nil, "position_unavailable" end
    local pages
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then pages = tonumber(value) end
    end
    local mapper_options = {
        catalog = cached.position_catalog,
        is_full_book = is_full_book == true,
        current_chapter_uid = current_chapter
            and (current_chapter.chapterUid or current_chapter.chapterId),
        chapter_len = cached.chapter_len,
        chapter_space = cached.chapter_space,
        chapter_ratio = cached.html_ratio or nil,
        document_pages = pages,
        summary = book.summary or book.title or "",
    }
    local position, reason = self:_toc_position(
        chapters, cached, fraction, mapper_options)
    if not position then
        position, reason = PositionMapper.local_to_remote(
            chapters, fraction, mapper_options)
    end
    if not position then return nil, reason end
    position.book_id = book_id
    position.captured_at = self.now()
    position.current_chapter_uid = current_chapter
        and (current_chapter.chapterUid or current_chapter.chapterId)
    position.is_full_book = is_full_book == true
    return position, nil, {
        book_id = book_id,
        book = book,
        chapters = chapters,
        chapter_len = cached.chapter_len,
        chapter_space = cached.chapter_space,
        html_ratio = cached.html_ratio or nil,
        current_chapter = current_chapter,
        is_full_book = is_full_book == true,
        path = path,
    }
end

function ProgressSync:_mark_verified(book_id, reason, local_position, remote)
    self.current_book_id = tostring(book_id)
    self.verified = true
    self.verified_at = self.now()
    self.verified_reason = reason
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.state = "verified"
    self:_persist(book_id, {
        verified_at = self.verified_at,
        verified_source = reason,
        last_local_position = local_position,
        last_remote_position = remote,
        last_sync_error = false,
    })
    log("info", "verified:",
        "book=", tostring(book_id),
        "reason=", tostring(reason),
        "local=", tostring(local_position and local_position.percent or "-"),
        "remote=", tostring(remote and remote.percent or "-"))
end

function ProgressSync:_clear_verified(reason)
    self.verified = false
    self.verified_at = nil
    self.verified_reason = reason
    if self.current_book_id then
        self:_persist(self.current_book_id, {
            verified_at = false,
            verified_source = reason or "cleared",
        })
    end
end

function ProgressSync:_fetch_remote(book_id, chapters, chapter_len, chapter_ratio,
    chapter_space)
    local gateway
    local web
    local gateway_error
    local web_error
    local options = {
        chapter_len = chapter_len,
        -- Same length basis as the upload side, so a pull
        -- lands where the upload said it was.
        chapter_ratio = chapter_ratio,
        chapter_space = chapter_space,
    }
    if self.settings:is_api_configured() then
        local ok, result = pcall(self.client.get_progress, self.client, book_id)
        if ok then
            gateway, gateway_error = PositionMapper.normalize_remote(
                result, book_id, "gateway", chapters, options)
        else
            gateway_error = tostring(result)
        end
    end
    if self.settings:is_cookie_configured() then
        local ok, result = pcall(
            self.client.get_web_progress, self.client, book_id)
        if ok then
            web, web_error = PositionMapper.normalize_remote(
                result, book_id, "web", chapters, options)
        else
            web_error = tostring(result)
        end
    end
    local selected = PositionMapper.choose_remote(
        web,
        gateway,
        SOURCE_CONFLICT_THRESHOLD_PERCENT
    )
    if not selected then
        return nil, gateway_error or web_error or "remote_unavailable"
    end
    return selected
end

-- P4: the anchor is 32 runes of the *cloud* chapter text
-- taken at the target position. It is derived locally from the same spans the
-- offsets come from, so nothing extra has to be stored in the cloud.
local ANCHOR_RUNES = 32
local ANCHOR_MIN_RUNES = 8

-- 空白判定要覆盖三种：ASCII 空白、NBSP(U+00A0)、全角空格(U+3000)。
local function is_space_rune(value)
    if value == " " or value == "\t" or value == "\n" or value == "\r" then return true end
    return value == "\194\160" or value == "\227\128\128"
end

-- 取一段**不含空白**的锚点。
-- 排版引擎会把源文里的换行与缩进归一成自己的空白（或直接吞掉），所以带换行的
-- 查询在 findAllText 里必然搜不到——2026-11-17 首次真机验收就是这样 miss 的
-- （锚点里带着 `\r\n  `）。改成「从当前位置跳过空白，取到下一个空白为止」，
-- 长度不足 8 rune 就跳到下一段再试一次。
local function anchor_segment(space, text_offset)
    local cursor = tonumber(text_offset) or 0
    for _attempt = 1, 2 do
        local raw = space.text_at(cursor, ANCHOR_RUNES + 16)
        if type(raw) ~= "string" or raw == "" then return nil end
        local index, start_byte, end_byte, count = 1, nil, nil, 0
        while index <= #raw do
            local byte = raw:byte(index)
            local size = 1
            if byte and byte >= 0xF0 then size = 4
            elseif byte and byte >= 0xE0 then size = 3
            elseif byte and byte >= 0xC0 then size = 2 end
            local char = raw:sub(index, index + size - 1)
            if not start_byte then
                if not is_space_rune(char) then start_byte = index; count = 1 end
            elseif is_space_rune(char) then
                break
            else
                count = count + 1
                end_byte = index + size - 1
                if count >= ANCHOR_RUNES then break end
            end
            index = index + size
        end
        if start_byte and end_byte then
            local piece = raw:sub(start_byte, end_byte)
            if rune_len(piece) >= ANCHOR_MIN_RUNES then return piece end
            -- 这一段太短（标题、短句）：整段跳过，从下一段开头再取
            cursor = cursor + rune_len(piece)
        end
        cursor = cursor + 1
    end
    return nil
end

function ProgressSync:_anchor_for(book_id, uid, text_offset)
    if uid == nil or text_offset == nil then return nil end
    local space = self:_chapter_space(book_id, uid)
    if not space then return nil end
    local text = anchor_segment(space, text_offset)
    if type(text) ~= "string" or text == "" then return nil end
    -- Entities stay raw in the cached span text but are decoded in the document,
    -- so an anchor containing one would never match. Let the percent path handle
    -- those few positions.
    if text:find("&", 1, true) then return nil end
    if rune_len(text) < ANCHOR_MIN_RUNES then return nil end
    local anchor = { text = text, chapter_uid = tostring(uid), text_offset = text_offset }
    anchor.runes = rune_len(text)
    return anchor
end

-- Jump by anchor when possible, otherwise fall back to the book percentage.
function ProgressSync:_jump_to(target, book_id)
    if type(target) ~= "table" then return false, "jump_target_missing" end
    local anchor = self:_anchor_for(book_id, target.chapter_uid,
        target.chapter_text_offset)
    if anchor and type(self.goto_anchor) == "function" then
        local called, jumped = pcall(self.goto_anchor, anchor, target.fraction)
        if called and jumped == true then return true end
    end
    return self.goto_fraction(target.fraction)
end

function ProgressSync:_apply_remote(remote, context, options)
    options = options or {}
    local target, reason = PositionMapper.remote_to_local(
        context.chapters,
        remote,
        {
            is_full_book = context.is_full_book,
            chapter_len = context.chapter_len,
            chapter_ratio = context.html_ratio,
            chapter_space = context.chapter_space,
            current_chapter_uid = context.current_chapter
                and (context.current_chapter.chapterUid
                    or context.current_chapter.chapterId),
        }
    )
    if not target then return false, reason end

    if target.requires_chapter_open then
        self:_clear_verified("switching_chapter")
        self.dirty = false
        self.pending_jump = {
            book_id = context.book_id,
            chapter_uid = target.chapter
                and (target.chapter.chapterUid or target.chapter.chapterId),
            fraction = target.fraction,
            text_offset = target.chapter_text_offset,
            remote = copy(remote),
            notify = options.manual == true,
        }
        self.state = "switching_chapter"
        local open_ok, opened, open_error = pcall(
            self.open_chapter, context.book, target.chapter)
        if not open_ok or opened == false then
            self.pending_jump = nil
            self.state = "error"
            return false, (open_ok and open_error or opened)
                or "target_chapter_unavailable"
        end
        return true
    end
    local ok, err = self:_jump_to(target, context.book_id)
    if not ok then return false, err or "jump_failed" end
    self.dirty = false
    self:_mark_verified(
        context.book_id,
        "remote_selected",
        self.local_position,
        remote
    )
    if options.manual then
        self.notify("remote_applied", { position = remote })
    end
    self.scheduler:scheduleIn(0.15, function()
        local position = self:capture_local()
        if position then
            -- P4 观测点：锚点跳转若落到了别的章，说明那段
            -- 文本在本书里并非唯一（或目录映射有偏差）。这里只记日志、不改状态：
            -- 先攒证据，避免把误判变成新的弹窗来源。参考实现的日志里就出现过
            -- `ProgressJumpVerify matched=false`，所以这个风险是真实存在的。
            if target.chapter_uid and position.chapter_uid
                and tostring(position.chapter_uid) ~= tostring(target.chapter_uid) then
                logger.warn("progress jump landed in another chapter:",
                    "want=", tostring(target.chapter_uid),
                    "got=", tostring(position.chapter_uid),
                    "book=", tostring(context.book_id))
            end
            self.local_position = position
            self.dirty = false
            self:_persist(context.book_id, {
                last_local_position = position,
            })
        end
    end)
    return true
end

function ProgressSync:_upload_snapshot(position, reason, show_result)
    if type(position) ~= "table" then return false end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    if book_id == "" or self.uploading then return false end
    self:_persist(book_id, {
        pending_upload_position = position,
        pending_upload_reason = reason or "unspecified",
    })
    if not self.is_online() then
        self.state = "offline"
        if show_result then self.notify("offline", {}) end
        return false
    end
    self.uploading = true
    self.state = "uploading"
    local attempts = 0
    local attempt
    attempt = function()
        attempts = attempts + 1
        local ok, accepted, outcome = pcall(
            self.upload_position,
            book_id,
            copy(position),
            0
        )
        if ok and not accepted and type(outcome) == "table"
            and outcome.error_kind == "busy"
            and attempts < BUSY_RETRY_LIMIT then
            self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, attempt)
            return
        end
        self.uploading = false
        if ok and accepted then
            self.state = "verified"
            self.dirty = false
            self.last_uploaded_position = copy(position)
            self:_persist(book_id, {
                last_local_position = position,
                last_uploaded_position = position,
                last_upload_at = self.now(),
                pending_upload_position = false,
                pending_upload_reason = false,
                last_sync_error = false,
            })
            log("info", "upload accepted:",
                "book=", book_id,
                "percent=", tostring(position.percent),
                "reason=", tostring(reason))
            if show_result then
                self.notify("upload_success", { position = position })
            end
            return
        end
        local error_message = ok and type(outcome) == "table"
            and outcome.error or outcome
        self.state = "error"
        self:_persist(book_id, {
            last_sync_error = tostring(error_message or "upload_failed"),
        })
        log("warn", "upload failed:", tostring(error_message))
        if show_result then
            self.notify("upload_failed", {
                error = tostring(error_message or "upload_failed"),
            })
        end
    end
    local started = self.run_online("progress_upload", attempt)
    if not started then
        self.uploading = false
        self.state = "offline"
    end
    return started == true
end

function ProgressSync:_keep_local(local_position, remote, options)
    options = options or {}
    self.dirty = not PositionMapper.same_position(local_position, remote)
    self:_mark_verified(
        local_position.book_id,
        "local_selected",
        local_position,
        remote
    )
    if options.upload_now then
        self:_upload_snapshot(local_position, options.reason, true)
    elseif options.manual then
        self.notify("local_kept", { position = local_position })
    end
end

function ProgressSync:_resolve(local_position, remote, context, options)
    options = options or {}
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    local comparison = PositionMapper.compare(
        local_position,
        remote,
        SAME_THRESHOLD_PERCENT
    )

    if comparison == "same" and not remote.conflict then
        self.dirty = false
        self:_mark_verified(
            context.book_id,
            "positions_match",
            local_position,
            remote
        )
        if options.manual then
            self.notify("already_synced", { position = local_position })
        end
        return
    end

    local ask = self:_config().ask_on_conflict ~= false
    if remote.conflict or ask then
        self.state = "awaiting_choice"
        local choice_generation = self.generation
        local function choice_is_current()
            return choice_generation == self.generation
                and tostring(self.detect_book() or "") == context.book_id
        end
        self.on_choice({
            book_title = context.book.title or context.book_id,
            local_position = copy(local_position),
            remote_position = copy(remote),
            source_conflict = remote.conflict == true,
            use_remote = function()
                if not choice_is_current() then return end
                local ok, reason = self:_apply_remote(
                    remote, context, { manual = options.manual })
                if not ok then
                    self.state = "error"
                    self.notify("jump_failed", { error = reason })
                end
            end,
            keep_local = function()
                if not choice_is_current() then return end
                self:_keep_local(local_position, remote, {
                    manual = options.manual,
                    upload_now = true,
                    reason = "explicit_local_choice",
                })
            end,
        })
        return
    end

    if comparison == "remote_ahead" then
        local ok, reason = self:_apply_remote(
            remote, context, { manual = options.manual })
        if not ok then
            self.state = "error"
            self.notify("jump_failed", { error = reason })
        end
    else
        self:_keep_local(local_position, remote, {
            manual = options.manual,
            upload_now = options.manual == true,
            reason = "manual_sync",
        })
    end
end

function ProgressSync:_schedule_pull_retry(options, retry_token)
    local attempt = (options.retry or 0) + 1
    if attempt > PULL_MAX_RETRIES then
        log("warn", "pull retries exhausted:",
            "book=", tostring(self.current_book_id))
        return false
    end
    local generation = self.generation
    self.scheduler:scheduleIn(PULL_RETRY_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        if retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling then return end
        if self.state == "awaiting_choice" then return end
        self:_pull({
            manual = false,
            retry = attempt,
            retry_token = retry_token,
        })
    end)
    log("info", "pull retry scheduled:",
        "book=", tostring(self.current_book_id),
        "attempt=", tostring(attempt),
        "delay=", tostring(PULL_RETRY_DELAY_SECONDS))
    return true
end

function ProgressSync:_pull(options)
    options = options or {}
    if self.pulling then return false end
    local retry_token = options.retry_token
    if retry_token == nil then
        self.pull_retry_token = self.pull_retry_token + 1
        retry_token = self.pull_retry_token
    elseif retry_token ~= self.pull_retry_token then
        return false
    end
    local local_position, reason, context = self:capture_local()
    if not local_position then
        if not (options.manual == true
            and reason == "catalog_unavailable"
            and type(self.refresh_catalog) == "function") then
            if options.manual then
                self.notify("local_unavailable", { error = reason })
            end
            return false
        end
    end
    if not self.settings:is_api_configured()
        and not self.settings:is_cookie_configured() then
        if options.manual then self.notify("authentication_required", {}) end
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
        return false
    end

    local generation = self.generation
    self.pulling = true
    self.state = "pulling"
    local started = self.run_online("progress_pull", function()
        if not local_position then
            local book_id = tostring(self.detect_book() or "")
            local refresh_ok, refreshed, refresh_error = pcall(
                self.refresh_catalog, book_id)
            if not refresh_ok then
                refresh_error = refreshed
                refreshed = nil
            end
            self.document_context = nil
            local_position, reason, context = self:capture_local()
            if not local_position then
                self.pulling = false
                self.state = "error"
                self.notify("local_unavailable", {
                    error = refresh_error or reason,
                })
                return
            end
            if type(refreshed) ~= "table" or #refreshed == 0 then
                log("warn", "catalog refresh returned no chapters for:", book_id)
            end
        end
        local remote, pull_error = self:_fetch_remote(
            context.book_id,
            context.chapters,
            context.chapter_len,
            context.html_ratio,
            context.chapter_space
        )
        self.pulling = false
        if generation ~= self.generation
            or tostring(self.detect_book() or "") ~= context.book_id then
            return
        end
        if not remote then
            self.state = "error"
            self:_persist(context.book_id, {
                last_pull_at = self.now(),
                last_sync_error = tostring(pull_error),
            })
            if options.manual then
                self.notify("pull_failed", { error = tostring(pull_error) })
            end
            return
        end
        self:_persist(context.book_id, {
            last_remote_position = remote,
            last_local_position = local_position,
            last_pull_at = self.now(),
            last_sync_error = false,
        })
        self:_resolve(local_position, remote, context, options)
    end, { silent_offline = true })
    if not started then
        self.pulling = false
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
    end
    return started == true
end

function ProgressSync:_apply_pending_jump(book_id)
    local pending = self.pending_jump
    if not pending or tostring(pending.book_id) ~= tostring(book_id) then
        return false
    end
    local local_position, _reason, context = self:capture_local()
    if not context or not context.current_chapter
        or tostring(context.current_chapter.chapterUid or context.current_chapter.chapterId)
            ~= tostring(pending.chapter_uid) then
        return false
    end
    self.pending_jump = nil
    local ok, err = self:_jump_to({
        fraction = pending.fraction,
        chapter_uid = pending.chapter_uid,
        chapter_text_offset = pending.text_offset,
    }, book_id)
    if not ok then
        self.state = "error"
        self.notify("jump_failed", { error = err })
        return true
    end
    self.dirty = false
    self:_mark_verified(
        book_id,
        "remote_chapter_applied",
        local_position,
        pending.remote
    )
    if pending.notify then
        self.notify("remote_applied", { position = pending.remote })
    end
    self.scheduler:scheduleIn(0.15, function()
        local position = self:capture_local()
        if position then
            self.local_position = position
            self:_persist(book_id, { last_local_position = position })
        end
    end)
    return true
end

function ProgressSync:cancel_pending_jump(reason)
    if not self.pending_jump then return false end
    self.pending_jump = nil
    self.dirty = false
    self.state = "unverified"
    self:_clear_verified(tostring(reason or "pending_jump_cancelled"))
    return true
end

function ProgressSync:on_reader_ready()
    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = nil
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.verified = false
    self.dirty = false
    self.state = "waiting"

    self.scheduler:scheduleIn(OPEN_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        local book_id = self.detect_book()
        if not book_id or is_mp_book(book_id) then
            self.state = "unsupported"
            return
        end
        book_id = tostring(book_id)
        self.current_book_id = book_id
        if self:_apply_pending_jump(book_id) then return end

        local local_position, reason = self:capture_local()
        if not local_position then
            self.state = "unsafe"
            log("warn", "local position unavailable:", tostring(reason))
            return
        end
        self.local_position = local_position
        self:_persist(book_id, { last_local_position = local_position })
        if self:_config().pull_on_open ~= true then
            self.state = "unverified"
            return
        end
        self:_pull({ manual = false })
    end)
end

function ProgressSync:on_page_update()
    if not self.current_book_id then return end
    local position = self:capture_local()
    if not position then return end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
end

function ProgressSync:on_close_document()
    local position = self:capture_local() or self.local_position
    if position and self.verified
        and self:_config().upload_on_close == true then
        if not self.local_position
            or not PositionMapper.same_position(position, self.local_position) then
            self.dirty = true
        end
        if self.dirty then
            self:_upload_snapshot(position, "document_close", false)
        end
    end
    self.generation = self.generation + 1
    self.current_book_id = nil
    self.verified = false
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
end

function ProgressSync:on_suspend()
    self.suspended_at = self.now()
    local position = self:capture_local() or self.local_position
    if position and self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    if position and self.verified and self.dirty
        and self:_config().upload_on_close == true then
        self:_upload_snapshot(position, "suspend", false)
    end
end

function ProgressSync:on_resume()
    local slept = self.suspended_at and self.now() - self.suspended_at or 0
    self.suspended_at = nil
    if slept >= RESUME_RECHECK_SECONDS
        and self:_config().pull_on_open == true then
        self:_clear_verified("resume_recheck")
        self:_pull({ manual = false })
    end
end

function ProgressSync:sync_now()
    return self:_pull({ manual = true })
end

function ProgressSync:position_for_report(book_id)
    local current = self.detect_book()
    if not current or tostring(current) ~= tostring(book_id)
        or is_mp_book(book_id) then
        return nil, nil, false
    end
    if not self.verified then
        return nil, "progress_unverified", true
    end
    local position, reason = self:capture_local()
    if not position then
        return nil, reason or "position_unavailable", true
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
    return position, nil, true
end

function ProgressSync:status()
    return {
        state = self.state,
        book_id = self.current_book_id,
        verified = self.verified,
        dirty = self.dirty,
        pulling = self.pulling == true,
        uploading = self.uploading == true,
        local_position = copy(self.local_position),
        remote_position = copy(self.remote_position),
    }
end

return ProgressSync
