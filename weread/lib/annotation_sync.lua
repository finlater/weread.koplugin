-- Resumable chapter pipeline. Each resume performs at most one network request
-- or a bounded piece of local matching. No KOReader UI or scheduling here.
local External = require("weread.lib.external_annotations")
local Chapters = require("weread.lib.annotation_chapters")
local Source = require("weread.lib.annotation_source")
local Annotations = require("weread.lib.annotations")
local logger = require("weread.lib.logger")
local Sync = {}
Sync.__index = Sync
Sync.NETWORK_REQUIRED = "annotation_network_required"
Sync.PERSISTENCE_VERSION = 1
-- A single pathological chapter must not block the whole-book sync: bound its
-- whole-book fallback calls and abort its matching after this much CPU.
Sync.CHAPTER_BUDGET = 60
Sync.MAX_CHAPTER_FALLBACKS = 4
-- Bound one annotation-sync HTTP attempt so a stalled download fails and the
-- existing retry/pause path runs instead of hanging the job. The transport's
-- idle timeout is left alone; only the whole request is bounded. Non-sync
-- callers (book/chapter/epub downloads) never pass this option.
Sync.NETWORK_TOTAL_TIMEOUT = 60

-- One cheap, greppable line per phase so a device log can no longer be silent
-- across a whole download/persist window:
--   grep annotation_batch_perf crash.log     -- one line per review-batch attempt
--   grep annotation_persist_perf crash.log   -- one line per local persist write
--   grep annotation_source_perf crash.log    -- one line per source-text fetch
--   grep annotation_request_failed crash.log -- one line per exhausted request
local BATCH_PERF = "annotation_batch_perf"
local PERSIST_PERF = "annotation_persist_perf"
local SOURCE_PERF = "annotation_source_perf"
local REQUEST_FAILED = "annotation_request_failed"

-- ui/time.now() is an fts (microseconds), so convert it to the milliseconds
-- this pipeline's elapsed helpers expect.
local ok_time, time = pcall(require, "ui/time")
local function now_ms()
    if ok_time and type(time) == "table" and type(time.now) == "function" then
        if type(time.to_ms) == "function" then
            return time.to_ms(time.now())
        end
        return time.now() / 1000
    end
    return os.time() * 1000
end

local function elapsed_ms(started, finished)
    return math.max(0, (finished or started) - started)
end

local function log_fields(tag, fields)
    local parts = { tag }
    for _, field in ipairs(fields) do
        parts[#parts + 1] = tostring(field[1]) .. "=" .. tostring(field[2])
    end
    logger.info(table.concat(parts, " "))
end

local function format_ms(value)
    return string.format("%.1f", value)
end

-- Gateway batches normally contain 30 ranges. Keep the local write path
-- bounded too, in case a future endpoint response is larger than expected.
-- A single oversized thought is retained rather than silently truncated.
local MAX_PERSIST_RANGES = 100
local MAX_PERSIST_THOUGHTS = 2000
local MAX_PERSIST_BYTES = 256 * 1024

local function unique_underlines(rows)
    local seen, result = {}, {}
    for _, row in ipairs(rows) do
        local range = type(row) == "table" and row.range
        if range and not seen[tostring(range)] then
            seen[tostring(range)] = true
            result[#result + 1] = row
        end
    end
    return result
end

local function underlines_by_range(rows)
    local result = {}
    for _, row in ipairs(rows or {}) do
        result[tostring(row.range or "")] = row
    end
    return result
end

local function thought_ranges(source)
    local result = {}
    for _, row in ipairs(source and source.underlines or {}) do
        result[tostring(row.range or "")] = true
    end
    return next(result) and result or nil
end

local function popup_items_bytes(items)
    local bytes = 32
    for _, item in ipairs(items or {}) do
        bytes = bytes + 64
        for _, key in ipairs({ "abstract", "author", "content" }) do
            bytes = bytes + #(tostring(item[key] or ""))
        end
    end
    return bytes
end

function Sync:new(options)
    local job = setmetatable(options, self)
    job.index, job.completed = 0, 0
    job.thread = coroutine.create(function() job:run() end)
    return job
end

function Sync:now_ms()
    return (self.clock or now_ms)()
end

function Sync:yield(stage, delay, detail)
    local state = { stage = stage, delay = delay or 0.01,
        index = self.index, total = #self.chapters, completed = self.completed }
    for key, value in pairs(detail or {}) do state[key] = value end
    coroutine.yield(state)
end

function Sync:requireNetwork()
    -- `offline` is captured before the job starts. Do not poll KOReader's
    -- link-state API while a request is running: it can momentarily report
    -- disconnected although the HTTP route remains usable. Actual request
    -- results and retries are the authoritative signal after startup.
    if self.offline then
        error(Sync.NETWORK_REQUIRED, 0)
    end
end

-- The UI adapter runs yielded network work outside this pipeline coroutine.
-- Only returned data is resumed here, so checkpoints and document access stay
-- in the parent. Headless prefetch keeps its existing synchronous worker path.
function Sync:callNetwork(fn, label)
    if self.async_network then return coroutine.yield({ network = fn, network_label = label or "request" }) end
    return fn()
end

function Sync:request(fn, progress, log_attempt)
    self:requireNetwork()
    for attempt = 1, 3 do
        self:yield(progress and progress.stage or "download",
            attempt == 1 and 0.3 or 2 ^ attempt, progress)
        self:requireNetwork()
        local started = self:now_ms()
        local ok, data, err = self:callNetwork(fn, progress and progress.stage or "download")
        local waited = elapsed_ms(started, self:now_ms())
        if log_attempt then log_attempt(ok, data, waited, attempt) end
        if ok and type(data) == "table" then return data end
        self:requireNetwork()
        if attempt == 3 then
            log_fields(REQUEST_FAILED, {
                { "book_id", self.book_id },
                { "stage", progress and progress.stage or "download" },
                { "waited_ms", format_ms(waited) },
                { "error", tostring(err or "invalid response") },
            })
            error(err or "Invalid annotation response")
        end
    end
end

function Sync:run()
    local store, book_id = self.store, self.book_id
    if self.clear_existing then
        self:requireNetwork()
        store:clearChapters(book_id, self.chapters)
        if self.on_reset then self.on_reset() end
    end
    if self.refresh then
        local changes = {}
        for _, chapter in ipairs(self.chapters) do
            local uid = Chapters.uid(chapter)
            changes[#changes + 1] = { kind = "refresh", key = uid, uid = uid, value = true }
            changes[#changes + 1] = { kind = "download", key = uid }
            changes[#changes + 1] = { kind = "batch", uid = uid }
            changes[#changes + 1] = { kind = "matching", uid = uid }
        end
        store:write(book_id, changes)
    end
    for index, chapter in ipairs(self.chapters) do
        self.index = index
        local uid = Chapters.uid(chapter)
        local started = self.perf and self.perf("chapter_cache_begin", nil, "chapter_uid=", uid)
        local range_key = Chapters.rangeKey(self.ranges and self.ranges[uid])
        local refreshing = store:get(book_id, "refresh", uid)
        local source_status = store:get(book_id, "source_status", uid)
        if source_status and not refreshing
            and source_status.persistence_version ~= Sync.PERSISTENCE_VERSION then
            -- Do not decode a legacy chapter snapshot just to convert it: it
            -- may contain the oversized review payload this format replaces.
            -- Automatic paths leave it untouched; an explicit user sync
            -- performs the bounded rebuild below.
            if not self.reset_legacy then
                self:yield("legacy")
                goto next_chapter
            end
            self:requireNetwork()
            store:write(book_id, {
                { kind = "source", key = uid }, { kind = "source_status", key = uid },
                { kind = "download", key = uid }, { kind = "batch", uid = uid },
                { kind = "thought", uid = uid }, { kind = "refresh", key = uid },
                { kind = "matching", uid = uid }, { kind = "projection", uid = uid },
                { kind = "status", uid = uid },
            })
            source_status = nil
            -- These rows are what the reader is currently displaying. Notify
            -- the UI for this chapter only: pausing or failing before the
            -- rebuild's first network request must not leave stale overlay
            -- records or completed-chapter statistics behind.
            if self.on_reset then self.on_reset(uid) end
        end
        if source_status and not refreshing then
            local status = self.document_key and store:get(book_id, "status",
                store:projectionKey(self.document_key, uid))
            if not self.document or (status
                and status.revision == source_status.revision
                and status.matcher_version == External.MATCHER_VERSION
                and status.range_key == range_key
                and not status.aborted) then
                if self.perf then self.perf("chapter_cached", started, "chapter_uid=", uid) end
                self.completed = self.completed + 1
                self:yield("saved")
                goto next_chapter
            end
        end
        local previous_source = refreshing and store:get(book_id, "source", uid)
        local source = not refreshing and store:get(book_id, "source", uid)
        -- Numeric generations are committed together with their per-range
        -- thoughts below. Legacy imports have not materialized those yet.
        local reuse_source = source and source_status
            and source_status.revision == source.revision
            and tonumber(source.revision) ~= nil
        if self.perf then
            started = self.perf("chapter_source_cache", started,
                "chapter_uid=", uid, "cache_hit=", source ~= nil)
        end
        local stale_thoughts, persisted_thoughts = nil, nil
        if not source then
            local stage = store:get(book_id, "download", uid)
            if not stage then
                local result = self:request(function()
                    local ok, data, err = self.client:get_chapter_underlines(book_id,
                        chapter.chapterUid or chapter.chapterId or chapter.chapter_uid,
                        { total_timeout = Sync.NETWORK_TOTAL_TIMEOUT })
                    if ok and (type(data) ~= "table" or type(data.underlines) ~= "table") then
                        return false, nil, "Invalid underline response"
                    end
                    return ok, data, err
                end, { stage = "underlines" })
                stage = { underlines = unique_underlines(result.underlines), next_batch = 1,
                    previous_thoughts = thought_ranges(previous_source) }
            end
            if not stage.revision then
                -- A persistent generation avoids hashing megabytes of thought
                -- text synchronously on small devices, and survives every resume.
                local generation = (store:get(book_id, "generation", uid) or 0) + 1
                stage.revision = tostring(generation)
                store:write(book_id, {
                    { kind = "generation", key = uid, uid = uid, value = generation },
                    { kind = "download", key = uid, uid = uid, value = stage },
                })
            end
            local ranges = {}
            for _, row in ipairs(stage.underlines) do ranges[#ranges + 1] = row.range end
            local batches = self.client:build_chapter_review_batches(ranges)
            if stage.batch_count and stage.batch_count ~= #batches then
                -- The batch layout changed (for example a plugin upgrade
                -- changed the gateway chunk size): batch-index checkpoints no
                -- longer describe the stored raw batches, and thoughts already
                -- persisted under the old layout may no longer match the fresh
                -- data, so drop both and download everything again.
                stage.next_batch, stage.next_persist_batch, stage.next_persist_review = 1, nil, nil
                stage.persisted_thoughts = nil
                store:write(book_id, {
                    { kind = "batch", uid = uid },
                    { kind = "thought", uid = uid },
                    { kind = "download", key = uid, uid = uid, value = stage },
                })
            end
            stage.batch_count = #batches
            local downloaded = 0
            for batch_index = 1, (stage.next_batch or 1) - 1 do
                downloaded = downloaded + #(batches[batch_index] or {})
            end
            for batch_index = stage.next_batch or 1, #batches do
                local batch_rows = batches[batch_index]
                local result = self:request(function()
                    local ok, data, err = self.client:get_chapter_reviews_batch(book_id,
                        chapter.chapterUid or chapter.chapterId or chapter.chapter_uid, batch_rows,
                        { total_timeout = Sync.NETWORK_TOTAL_TIMEOUT })
                    if ok and (type(data) ~= "table" or type(data.reviews) ~= "table") then
                        return false, nil, "Invalid thoughts response"
                    end
                    return ok, data, err
                end, { stage = "thoughts", current = downloaded, count = #ranges },
                function(ok, data, waited)
                    local reviews = ok and type(data) == "table" and #(data.reviews or {}) or 0
                    log_fields(BATCH_PERF, {
                        { "book_id", book_id }, { "chapter_uid", uid },
                        { "batch", batch_index .. "/" .. #batches },
                        { "ranges", #batch_rows }, { "reviews", reviews },
                        { "ms", format_ms(waited) }, { "error", ok ~= true },
                    })
                end)
                stage.next_batch = batch_index + 1
                store:write(book_id, {
                    { kind = "batch", key = uid .. ":" .. batch_index, uid = uid, value = result.reviews },
                    { kind = "download", key = uid, uid = uid, value = stage },
                })
                downloaded = math.min(downloaded + #batches[batch_index], #ranges)
                self:yield("thoughts", nil, {
                    current = downloaded, count = #ranges,
                })
            end

            -- Raw responses remain resumable staging data only. Convert one
            -- saved batch at a time to compact per-range popup records, then
            -- remove that raw batch in the same transaction as its checkpoint.
            -- This never builds a chapter-sized review object in memory or in
            -- a single SQLite payload.
            local by_range = underlines_by_range(stage.underlines)
            local persist_batch = stage.next_persist_batch or 1
            local persist_review = stage.next_persist_review or 1
            local persist_rows
            while persist_batch <= #batches do
                local persist_started = self:now_ms()
                local write_batch = persist_batch
                if not persist_rows then
                    persist_rows = store:get(book_id, "batch", uid .. ":" .. persist_batch)
                    assert(persist_rows, "Missing saved thoughts batch")
                end
                local changes, range_count, thought_count, byte_count = {}, 0, 0, 0
                while persist_review <= #persist_rows do
                    local review = persist_rows[persist_review]
                    local range = type(review) == "table" and review.range or nil
                    if range == nil or tostring(range) == "" then
                        -- The gateway can return malformed review entries (JSON null
                        -- decodes to a function, other scalars to numbers/booleans).
                        -- Skipping them keeps the checkpoint advancing; aborting here
                        -- made every resume retry the same element forever while the
                        -- staging rows stayed behind.
                        logger.warn("annotation persist skipped a malformed review entry:",
                            "chapter_uid=", tostring(uid),
                            "index=", tostring(persist_review),
                            "type=", type(review))
                        persist_review = persist_review + 1
                        goto continue_persist
                    end
                    range = tostring(range)
                    local items = Annotations.buildThoughtPopupItems(review)
                    local item_bytes = popup_items_bytes(items)
                    local would_exceed = range_count > 0 and (range_count >= MAX_PERSIST_RANGES
                        or thought_count + #items > MAX_PERSIST_THOUGHTS
                        or byte_count + item_bytes > MAX_PERSIST_BYTES)
                    if would_exceed then break end
                    local underline = by_range[range]
                    if underline and External.quote_for(underline, {}) == "" then
                        local quote = External.quote_for(underline, { review })
                        if quote ~= "" then underline.markText = quote end
                    end
                    changes[#changes + 1] = { kind = "thought", key = uid .. ":" .. range,
                        uid = uid, value = items }
                    if stage.previous_thoughts then
                        stage.persisted_thoughts = stage.persisted_thoughts or {}
                        stage.persisted_thoughts[range] = true
                    end
                    range_count = range_count + 1
                    thought_count = thought_count + #items
                    byte_count = byte_count + item_bytes
                    persist_review = persist_review + 1
                    ::continue_persist::
                end
                if persist_review > #persist_rows then
                    changes[#changes + 1] = { kind = "batch", key = uid .. ":" .. persist_batch }
                    persist_batch, persist_review = persist_batch + 1, 1
                    persist_rows = nil
                end
                stage.next_persist_batch = persist_batch
                stage.next_persist_review = persist_review
                changes[#changes + 1] = { kind = "download", key = uid, uid = uid, value = stage }
                store:write(book_id, changes)
                log_fields(PERSIST_PERF, {
                    { "book_id", book_id }, { "chapter_uid", uid },
                    { "batch", write_batch .. "/" .. #batches },
                    { "ranges", range_count }, { "thoughts", thought_count },
                    { "bytes", byte_count },
                    { "ms", format_ms(elapsed_ms(persist_started, self:now_ms())) },
                })
                local persisted = 0
                for batch_index = 1, persist_batch - 1 do
                    persisted = persisted + #(batches[batch_index] or {})
                end
                self:yield("persist", nil, {
                    current = math.min(persisted, #ranges), count = #ranges,
                })
            end
            source = { book_id = book_id, chapter_uid = uid,
                underlines = stage.underlines, reviews = {} }
            local missing = false
            for _, row in ipairs(source.underlines) do
                if External.quote_for(row, source.reviews) == "" then missing = true; break end
            end
            if missing then
                local original = store:get(book_id, "original", uid)
                if (not original or refreshing) and self.fetch_source then
                    self:requireNetwork()
                    self:yield("source", 0.3)
                    self:requireNetwork()
                    local source_started = self:now_ms()
                    local fetched = self.fetch_source(chapter)
                    log_fields(SOURCE_PERF, {
                        { "book_id", book_id }, { "chapter_uid", uid },
                        { "bytes", type(fetched) == "string" and #fetched or 0 },
                        { "ms", format_ms(elapsed_ms(source_started, self:now_ms())) },
                    })
                    original = type(fetched) == "table" and fetched or Source.index(fetched)
                    store:put(book_id, "original", uid, original, uid)
                end
                if original then
                    for _, row in ipairs(source.underlines) do
                        if External.quote_for(row, source.reviews) == "" then
                            row.markText = Source.quote(original, row.range)
                        end
                    end
                end
            end
            source.revision = stage.revision
            if self.perf then started = self.perf("chapter_source_ready", started, "chapter_uid=", uid) end
            stale_thoughts = stage.previous_thoughts
            persisted_thoughts = stage.persisted_thoughts
        end
        local projection, document_key = nil, self.document_key
        if self.document then
            local key = store:projectionKey(document_key, uid)
            projection = store:get(book_id, "projection", key)
            if self.perf then
                started = self.perf("chapter_projection_cache", started,
                    "chapter_uid=", uid, "cache_hit=", projection ~= nil)
            end
            if not projection or projection.revision ~= source.revision
                or projection.matcher_version ~= External.MATCHER_VERSION
                or projection.range_key ~= range_key then
                local match_current = 0
                self:yield("match", nil, { current = 0, count = #source.underlines })
                local saved = store:get(book_id, "matching", key)
                if saved and (saved.revision ~= source.revision
                    or saved.matcher_version ~= External.MATCHER_VERSION or saved.range_key ~= range_key) then
                    saved = nil
                end
                if saved then match_current = math.max(0, (saved.next_index or 1) - 1) end
                if self.perf then
                    started = self.perf("chapter_match_begin", started,
                        "chapter_uid=", uid, "underlines=", #source.underlines,
                        "resumed=", saved ~= nil)
                end
                local records, stats = External.locate(self.document, { source }, {
                    chapter_ranges = self.ranges,
                    resume = saved,
                    include_items = false,
                    max_fallbacks = self.max_chapter_fallbacks or Sync.MAX_CHAPTER_FALLBACKS,
                    chapter_budget = self.chapter_budget or Sync.CHAPTER_BUDGET,
                    walk_yield = function(hint)
                        local total = #source.underlines
                        if hint and hint.progress and total > 0 then
                            match_current = math.max(match_current,
                                math.floor(hint.progress * total))
                        end
                        self:yield("match", nil, { current = match_current, count = total })
                    end,
                    yield = function(current, count)
                        if current then match_current = math.max(match_current, current) end
                        self:yield("match", nil, {
                            current = match_current, count = count or #source.underlines,
                        })
                    end,
                    fallback_yield = function()
                        self:yield("match", nil, {
                            current = match_current, count = #source.underlines,
                        })
                    end,
                    checkpoint = function(state)
                        state.range_key = range_key
                        state.revision = source.revision
                        state.matcher_version = External.MATCHER_VERSION
                        store:put(book_id, "matching", key, state, uid)
                    end,
                })
                if self.perf then
                    started = self.perf("chapter_match", started, "chapter_uid=", uid,
                        "located=", stats.located, "unmatched=", stats.unmatched)
                end
                if stats.aborted and self.perf then
                    self.perf("chapter_match_aborted", started, "chapter_uid=", uid,
                        "located=", stats.located, "unmatched=", stats.unmatched)
                end
                if projection and #(projection.records or {}) > 0
                    and stats.total > 0 and stats.located == 0 and not stats.aborted then
                    error("No underlines could be matched. Previous chapter results were preserved.")
                end
                projection = { revision = source.revision, range_key = range_key,
                    matcher_version = External.MATCHER_VERSION, records = records,
                    stats = stats, complete = not stats.aborted }
            end
        end
        -- Reprojection only changes coordinates. Keep the committed source
        -- and thoughts intact instead of rebuilding and rewriting them.
        local changes = {}
        if not reuse_source then
            changes = {
                { kind = "source", key = uid, uid = uid, value = source },
                { kind = "source_status", key = uid, uid = uid,
                    value = { revision = source.revision, total = #source.underlines,
                        persistence_version = Sync.PERSISTENCE_VERSION } },
                { kind = "download", key = uid }, { kind = "batch", uid = uid },
                { kind = "refresh", key = uid },
            }
            for range in pairs(stale_thoughts or {}) do
                if not (persisted_thoughts and persisted_thoughts[range]) then
                    changes[#changes + 1] = { kind = "thought", key = uid .. ":" .. range }
                end
            end
        end
        if document_key then
            local key = store:projectionKey(document_key, uid)
            changes[#changes + 1] = { kind = "projection", key = key, uid = uid, value = projection }
            changes[#changes + 1] = { kind = "matching", key = key }
            changes[#changes + 1] = { kind = "status", key = key, uid = uid,
                value = { stats = projection.stats, revision = projection.revision,
                    matcher_version = projection.matcher_version, range_key = range_key,
                    aborted = projection.stats.aborted or nil } }
        end
        store:write(book_id, changes)
        if self.perf then self.perf("chapter_save", started, "chapter_uid=", uid) end
        self.completed = self.completed + 1
        if self.on_chapter then self.on_chapter(uid, projection) end
        self:yield("saved")
        ::next_chapter::
    end
    return { stage = "complete", completed = self.completed, total = #self.chapters }
end

function Sync:step(...)
    if self.cancelled then return true, { stage = "paused" } end
    local ok, value = coroutine.resume(self.thread, ...)
    if not ok then return nil, tostring(value) end
    return coroutine.status(self.thread) == "dead", value
end

return Sync
