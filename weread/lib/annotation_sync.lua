-- Resumable chapter pipeline. Each resume performs at most one network request
-- or a bounded piece of local matching. No KOReader UI or scheduling here.
local External = require("weread.lib.external_annotations")
local Chapters = require("weread.lib.annotation_chapters")
local Source = require("weread.lib.annotation_source")
local Sync = {}
Sync.__index = Sync

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

function Sync:new(options)
    local job = setmetatable(options, self)
    job.index, job.completed = 0, 0
    job.thread = coroutine.create(function() job:run() end)
    return job
end

function Sync:yield(stage, delay, detail)
    local state = { stage = stage, delay = delay or 0.01,
        index = self.index, total = #self.chapters, completed = self.completed }
    for key, value in pairs(detail or {}) do state[key] = value end
    coroutine.yield(state)
end

function Sync:request(fn, progress)
    if self.offline then error("Annotation data is not cached. Connect to continue.") end
    for attempt = 1, 3 do
        self:yield(progress and progress.stage or "download",
            attempt == 1 and 0.3 or 2 ^ attempt, progress)
        local ok, data, err = fn()
        if ok and type(data) == "table" then return data end
        if attempt == 3 then error(err or "Invalid annotation response") end
    end
end

function Sync:run()
    local store, book_id = self.store, self.book_id
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
        local refreshing = store:get(book_id, "refresh", uid)
        local source_status = store:get(book_id, "source_status", uid)
        if source_status and not refreshing then
            local status = self.document_key and store:get(book_id, "status",
                store:projectionKey(self.document_key, uid))
            if not self.document or (status
                and status.revision == source_status.revision
                and status.matcher_version == External.MATCHER_VERSION) then
                self.completed = self.completed + 1
                self:yield("saved")
                goto next_chapter
            end
        end
        local source = not refreshing and store:get(book_id, "source", uid)
        if not source then
            local stage = store:get(book_id, "download", uid)
            if not stage then
                local result = self:request(function()
                    local ok, data, err = self.client:get_chapter_underlines(book_id,
                        chapter.chapterUid or chapter.chapterId or chapter.chapter_uid)
                    if ok and (type(data) ~= "table" or type(data.underlines) ~= "table") then
                        return false, nil, "Invalid underline response"
                    end
                    return ok, data, err
                end, { stage = "underlines" })
                stage = { underlines = unique_underlines(result.underlines), next_batch = 1 }
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
            local downloaded = 0
            for batch_index = 1, (stage.next_batch or 1) - 1 do
                downloaded = downloaded + #(batches[batch_index] or {})
            end
            for batch_index = stage.next_batch or 1, #batches do
                local result = self:request(function()
                    local ok, data, err = self.client:get_chapter_reviews_batch(book_id,
                        chapter.chapterUid or chapter.chapterId or chapter.chapter_uid, batches[batch_index])
                    if ok and (type(data) ~= "table" or type(data.reviews) ~= "table") then
                        return false, nil, "Invalid thoughts response"
                    end
                    return ok, data, err
                end, { stage = "thoughts", current = downloaded, count = #ranges })
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
            source = { book_id = book_id, chapter_uid = uid,
                underlines = stage.underlines, reviews = {} }
            for batch_index = 1, #batches do
                local rows = store:get(book_id, "batch", uid .. ":" .. batch_index)
                assert(rows, "Missing saved thoughts batch")
                for _, review in ipairs(rows) do source.reviews[#source.reviews + 1] = review end
            end
            local missing = false
            for _, row in ipairs(source.underlines) do
                if External.quote_for(row, source.reviews) == "" then missing = true; break end
            end
            if missing then
                local original = store:get(book_id, "original", uid)
                if (not original or refreshing) and self.fetch_source and not self.offline then
                    self:yield("source", 0.3)
                    local fetched = self.fetch_source(chapter)
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
        end
        local projection, document_key = nil, self.document_key
        if self.document then
            local key = store:projectionKey(document_key, uid)
            projection = store:get(book_id, "projection", key)
            if not projection or projection.revision ~= source.revision
                or projection.matcher_version ~= External.MATCHER_VERSION then
                local match_current = 0
                self:yield("match", nil, { current = 0, count = #source.underlines })
                local saved = store:get(book_id, "matching", key)
                if saved and (saved.revision ~= source.revision
                    or saved.matcher_version ~= External.MATCHER_VERSION) then
                    saved = nil
                end
                if saved then match_current = math.max(0, (saved.next_index or 1) - 1) end
                local records, stats = External.locate(self.document, { source }, {
                    chapter_ranges = self.ranges,
                    resume = saved,
                    yield = function(current, count)
                        if current then match_current = current end
                        self:yield("match", nil, {
                            current = match_current, count = count or #source.underlines,
                        })
                    end,
                    checkpoint = function(state)
                        state.revision = source.revision
                        state.matcher_version = External.MATCHER_VERSION
                        store:put(book_id, "matching", key, state, uid)
                    end,
                })
                if projection and #(projection.records or {}) > 0
                    and stats.total > 0 and stats.located == 0 then
                    error("No underlines could be matched. Previous chapter results were preserved.")
                end
                -- Keep small position rows in the projection. Thoughts are
                -- fetched on tap from the shared per-range cache below.
                for _, record in ipairs(records) do record.items = nil end
                projection = { revision = source.revision,
                    matcher_version = External.MATCHER_VERSION, records = records,
                    stats = stats, complete = true }
            end
        end
        local items = {}
        for _, review in ipairs(source.reviews or {}) do
            local range = tostring(review.range or "")
            items[#items + 1] = { kind = "thought", key = uid .. ":" .. range, uid = uid,
                value = require("weread.lib.annotations").buildThoughtPopupItems(review) }
        end
        -- Stage per-range items and the chapter snapshot in one transaction;
        -- source/projection commit also removes the resumable staging rows.
        local changes = {
            { kind = "source", key = uid, uid = uid, value = source },
            { kind = "source_status", key = uid, uid = uid,
                value = { revision = source.revision, total = #source.underlines } },
            { kind = "download", key = uid }, { kind = "batch", uid = uid },
            { kind = "refresh", key = uid }, { kind = "thought", uid = uid },
        }
        for _, item in ipairs(items) do changes[#changes + 1] = item end
        if document_key then
            local key = store:projectionKey(document_key, uid)
            changes[#changes + 1] = { kind = "projection", key = key, uid = uid, value = projection }
            changes[#changes + 1] = { kind = "matching", key = key }
            changes[#changes + 1] = { kind = "status", key = key, uid = uid,
                value = { stats = projection.stats, revision = projection.revision,
                    matcher_version = projection.matcher_version } }
        end
        store:write(book_id, changes)
        self.completed = self.completed + 1
        if self.on_chapter then self.on_chapter(uid, projection) end
        self:yield("saved")
        ::next_chapter::
    end
    return { stage = "complete", completed = self.completed, total = #self.chapters }
end

function Sync:step()
    if self.cancelled then return true, { stage = "paused" } end
    local ok, value = coroutine.resume(self.thread)
    if not ok then return nil, tostring(value) end
    return coroutine.status(self.thread) == "dead", value
end

return Sync
