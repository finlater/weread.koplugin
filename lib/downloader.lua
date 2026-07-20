-- Book/chapter download engine.
--
-- Extracted from main.lua as an independent, dependency-injected object so the
-- plugin entry point keeps only thin menu wrappers. The host injects the API
-- client, settings, and a small set of UI/framework callbacks; the engine owns
-- the whole async download state machine and the device standby guard.
--
-- Standby guard: long downloads must not let the device suspend mid-transfer.
-- Every scheduled step runs through _scheduleGuarded, which wraps the step in
-- xpcall and always releases the guard (and closes the dialog + reports the
-- error) if the step throws. This is critical: a bare UIManager:scheduleIn that
-- threw would leak the guard and leave the device unable to sleep until reboot.

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local T = require("ffi/util").template

local Content = require("lib.content")
local DownloadDialog = require("ui.download_dialog")
local I18n = require("lib.i18n")
local Thoughts = require("lib.thoughts")
local WeRead = require("lib.weread")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local LOG_MODULE = "[WeRead]"

-- Chapter download retry parameters (matching original api.lua).
local CHAPTER_MAX_RETRIES = 5
local CHAPTER_MAX_RETRY_INTERVAL = 10 -- seconds

local function _(text)
    return I18n.tr(text)
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

-- Block OS-level standby (Kindle powerd, Kobo lid/menu-suspend, etc.)
local function preventOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = true
    end
end

local function allowOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = false
    end
end

-- ---------------------------------------------------------------------------
-- Chapter cache (per-chapter xhtml + assets persisted to disk)
-- ---------------------------------------------------------------------------

local function filename_safe(value)
    value = tostring(value or ""):gsub("[%z%c/\\:%*%?\"<>|]", "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return "_" end
    return value
end

local function chapter_cache_root(settings, book)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_resolved_dir(settings, book_id, book)
    return dir .. "/chapters"
end

local function chapter_xhtml_path(settings, book, chapter_uid)
    return chapter_cache_root(settings, book) .. "/" .. tostring(chapter_uid) .. ".xhtml"
end

local function chapter_assets_meta_path(settings, book, chapter_uid)
    return chapter_cache_root(settings, book) .. "/" .. tostring(chapter_uid) .. ".assets.json"
end

local function asset_file_path(settings, book, href)
    return chapter_cache_root(settings, book) .. "/assets/" .. filename_safe(href)
end

local function ensure_dir(path)
    os.execute("mkdir -p " .. string.format("%q", path))
end

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        return false, err
    end
    file:write(data)
    file:close()
    return true
end

--- Persist a fully-processed chapter so subsequent downloads can skip it.
-- Writes:  chapters/<uid>.xhtml   (final processed xhtml)
--          chapters/<uid>.assets.json  ([{href, media_type}, ...])
--          chapters/assets/<safe_href>  (binary asset data)
local function save_chapter_cache(settings, book, chapter_uid, xhtml, chapter_assets)
    local root = chapter_cache_root(settings, book)
    ensure_dir(root)
    ensure_dir(root .. "/assets")

    -- XHTML
    local xhtml_path = chapter_xhtml_path(settings, book, chapter_uid)
    if not write_file(xhtml_path, xhtml) then
        logger.warn(LOG_MODULE, "failed to write chapter xhtml cache:", xhtml_path)
        return false
    end

    -- Asset metadata + data
    if chapter_assets and #chapter_assets > 0 then
        local meta = {}
        for _, asset in ipairs(chapter_assets) do
            table.insert(meta, { href = asset.href, media_type = asset.media_type })
            local apath = asset_file_path(settings, book, asset.href)
            write_file(apath, asset.data)
        end
        local meta_path = chapter_assets_meta_path(settings, book, chapter_uid)
        local ok, encoded = pcall(function() return json.encode(meta) end)
        if ok then
            write_file(meta_path, encoded)
        else
            logger.warn(LOG_MODULE, "failed to encode chapter asset meta:", chapter_uid)
        end
    end

    logger.info(LOG_MODULE, "chapter cache saved:", "chapter_uid=", tostring(chapter_uid))
    return true
end

--- Load a cached chapter back into memory.
-- @return xhtml (string|nil), assets (table|nil)
local function load_chapter_cache(settings, book, chapter_uid)
    local xhtml_path = chapter_xhtml_path(settings, book, chapter_uid)
    local xhtml = read_file(xhtml_path)
    if not xhtml then
        return nil
    end

    local assets = {}
    local meta_path = chapter_assets_meta_path(settings, book, chapter_uid)
    local meta_raw = read_file(meta_path)
    if meta_raw then
        local ok, meta = pcall(function() return json.decode(meta_raw) end)
        if ok and type(meta) == "table" then
            for _, entry in ipairs(meta) do
                local apath = asset_file_path(settings, book, entry.href)
                local data = read_file(apath)
                if data then
                    table.insert(assets, {
                        href = entry.href,
                        data = data,
                        media_type = entry.media_type,
                    })
                end
            end
        end
    end

    logger.info(LOG_MODULE, "chapter cache hit:", "chapter_uid=", tostring(chapter_uid),
        "xhtml_bytes=", tostring(#xhtml), "assets=", tostring(#assets))
    return xhtml, assets
end

--- Check whether a chapter is cached on disk.
local function chapter_cache_exists(settings, book, chapter_uid)
    local xhtml_path = chapter_xhtml_path(settings, book, chapter_uid)
    local file = io.open(xhtml_path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Downloader
-- ---------------------------------------------------------------------------

local Downloader = {}
Downloader.__index = Downloader

-- o = {
--   client, settings,                       -- injected dependencies
--   show_info(text), show_transient(text, timeout),
--   refresh_ui(), refresh_shelf(),
--   open_file(path), safe_callback(label, fn),
--   require_login(cookie, api_key), run_online_task(label, fn),  -- host framework
-- }
function Downloader:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

-- Keep the device awake during long book downloads (reference counted so
-- multiple concurrent jobs share a single guard).
function Downloader:_beginStandby()
    self._standby_ref = (self._standby_ref or 0) + 1
    if self._standby_ref == 1 then
        UIManager:preventStandby()
        preventOsStandby()
    end
end

function Downloader:_endStandby()
    local ref = self._standby_ref or 0
    if ref > 0 then
        ref = ref - 1
        self._standby_ref = ref
        if ref == 0 then
            allowOsStandby()
            UIManager:allowStandby()
        end
    end
end

function Downloader:_releaseStandby(dl)
    if dl and dl.standby_guard then
        dl.standby_guard = false
        self:_endStandby()
    end
end

-- Schedule any download step behind xpcall so an uncaught error always releases
-- the standby guard, closes the progress dialog, and reports the failure.
function Downloader:_scheduleGuarded(dl, step_fn, delay)
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(step_fn, debug.traceback)
        if not ok and dl.standby_guard then
            self:_releaseStandby(dl)
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            logger.err(LOG_MODULE, "download step failed:", log_error(err))
            self.show_info(T(_("Download failed:\n%1"), display_error(err)))
        end
    end)
end

-- Public entry: start downloading the given chapters as one EPUB.
function Downloader:start(book, chapters, suffix, options)
    options = options or {}
    if not self.require_login(true, false) then
        return
    end
    local task_label = options.single_chapter and _("Download chapter and read") or _("Download full book")
    self.run_online_task(task_label, function()
        local ok_init, err_init = pcall(function()
            Content.ensure_reader_state(self.client, book)
        end)
        if not ok_init then
            logger.err(LOG_MODULE, "initialize book download failed:", log_error(err_init))
            self.show_info(T(_("Download failed:\n%1"), display_error(err_init)))
            return
        end

        self:_beginStandby()
        local total = #chapters
        local dl = {
            book = book,
            chapters = chapters,
            suffix = suffix or "book",
            index = 1,
            cancelled = false,
            selected = {},
            bodies = {},
            assets = {},
            state = {},
            total = total,
            failed = {},
            annotation_failed_batches = 0,
            aborted = false,
            abort_reason = nil,
            single_chapter = options.single_chapter == true,
            started_at = time.now(),
            standby_guard = true,
        }

        local progress_dialog = DownloadDialog:new{
            title = T(_("Downloading: %1"), book.title or ""),
            progress_max = total,
            buttons = {{
                {
                    text = _("Cancel download"),
                    callback = function()
                        dl.cancelled = true
                        if dl.progress_dialog then
                            dl.progress_dialog:close()
                            dl.progress_dialog = nil
                        end
                    end,
                },
            }},
        }
        dl.progress_dialog = progress_dialog
        progress_dialog:show()
        self.refresh_ui()

        self:_scheduleGuarded(dl, function() self:_step(dl) end)
    end)
end

function Downloader:_setStage(dl, title, progress)
    if not dl.progress_dialog then return end
    dl.progress_dialog:setTitle(title)
    if progress then
        dl.progress_dialog:reportProgress(progress)
    end
end

function Downloader:_perf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info(LOG_MODULE, "download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

--- Abort the download on a failed chapter (no skip — prevent incomplete books).
function Downloader:_failChapter(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    dl.aborted = true
    dl.abort_reason = T(
        _("Chapter %1/%2 (%3) failed:\n%4"),
        tostring(dl.index), tostring(dl.total),
        tostring(chapter and chapter.title or uid),
        display_error(err)
    )
    dl.current = nil
    dl.annotation = nil
    -- Jump to completion so the user sees the error and the standby guard is released.
    dl.index = dl.total + 1
    logger.err(LOG_MODULE, "chapter download failed (aborting):",
        "index=", tostring(dl.index - 1) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

--- Finalize a successfully-downloaded chapter and persist its cache.
function Downloader:_finishChapter(dl)
    if dl.cancelled or not dl.current then return end
    local chapter = dl.current.chapter
    local cache = self.settings:get("cache")
    local stage_text
    if cache.download_book_images then
        stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    else
        stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    end
    self:_setStage(dl,
        stage_text, dl.index - 0.1)
    local started = time.now()
    local ok, xhtml, chapter_assets = pcall(function()
        return Content.finalize_single_chapter_content(
            self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state
        )
    end)
    self:_perf(dl, "images_and_finalize", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, xhtml)
        return
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    dl.bodies[uid] = xhtml
    table.insert(dl.selected, chapter)
    for _i, asset in ipairs(chapter_assets or {}) do
        table.insert(dl.assets, asset)
    end

    -- Persist chapter cache so subsequent downloads can skip this chapter.
    save_chapter_cache(self.settings, dl.book, uid, xhtml, chapter_assets)

    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_applyAnnotations(dl)
    if dl.cancelled or not dl.current or not dl.annotation then return end
    local annotation = dl.annotation
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setStage(dl,
        T(_("Processing underlines and thoughts · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.15)
    local started = time.now()
    local ok, processed, annotation_css = pcall(function()
        return Thoughts.apply_data(self.settings, book_id, chapter.chapterUid,
            dl.current.xhtml, annotation.underlines, annotation.reviews)
    end)
    self:_perf(dl, "apply_annotations", started, "ok=", tostring(ok),
        "reviews=", tostring(#annotation.reviews))
    if not ok then
        self:_failChapter(dl, processed)
        return
    end
    dl.current.xhtml = processed
    dl.state.annotation_css_seen = dl.state.annotation_css_seen or {}
    if annotation_css ~= "" and not dl.state.annotation_css_seen[annotation_css] then
        dl.state.css = Thoughts.merge_css(dl.state.css, annotation_css)
        dl.state.annotation_css_seen[annotation_css] = true
    end
    self:_finishChapter(dl)
end

function Downloader:_annotationBatch(dl)
    if dl.cancelled then
        self:_releaseStandby(dl)
        self.show_transient(_("Download cancelled"), 2)
        return
    end
    local annotation = dl.annotation
    if not annotation then
        self:_finishChapter(dl)
        return
    end
    if annotation.batch_index > #annotation.batches then
        self:_applyAnnotations(dl)
        return
    end

    local batch_index = annotation.batch_index
    local batch_total = #annotation.batches
    local fractional = dl.index - 0.85 + 0.7 * batch_index / math.max(1, batch_total)
    self:_setStage(dl,
        T(_("Downloading thoughts %1/%2 · chapter %3/%4"),
            tostring(batch_index), tostring(batch_total), tostring(dl.index), tostring(dl.total)),
        fractional)

    local started = time.now()
    local ok, result, err = self.client:get_chapter_reviews_batch(
        dl.book.book_id or dl.book.bookId,
        dl.current.chapter.chapterUid,
        annotation.batches[batch_index]
    )
    self:_perf(dl, "thought_batch", started,
        "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
        "ok=", tostring(ok), "retry=", tostring(annotation.retry))

    if not ok then
        if annotation.retry < 2 then
            annotation.retry = annotation.retry + 1
            self:_setStage(dl,
                T(_("Retrying thoughts %1/%2 · attempt %3"),
                    tostring(batch_index), tostring(batch_total), tostring(annotation.retry)),
                fractional)
            self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.6 * annotation.retry)
            return
        end
        dl.annotation_failed_batches = dl.annotation_failed_batches + 1
        logger.warn(LOG_MODULE, "thought batch skipped:",
            "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
            "error=", log_error(err or "unknown"))
    elseif result and type(result.reviews) == "table" then
        for _i, review in ipairs(result.reviews) do
            annotation.reviews[#annotation.reviews + 1] = review
        end
    end

    annotation.batch_index = batch_index + 1
    annotation.retry = 0
    self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.3)
end

function Downloader:_startAnnotations(dl)
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setStage(dl,
        T(_("Downloading underlines · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.85)
    local started = time.now()
    local ok, underlines, ranges, err = Thoughts.fetch_underlines(
        self.client, self.settings, book_id, chapter.chapterUid
    )
    self:_perf(dl, "underlines", started, "ok=", tostring(ok),
        "ranges=", tostring(#(ranges or {})))
    if not ok or type(underlines) ~= "table" then
        logger.warn(LOG_MODULE, "skip chapter annotations:", log_error(err or "no data"))
        self:_finishChapter(dl)
        return
    end
    dl.annotation = {
        underlines = underlines,
        reviews = {},
        batches = self.client:build_chapter_review_batches(ranges),
        batch_index = 1,
        retry = 0,
    }
    if #dl.annotation.batches == 0 then
        self:_applyAnnotations(dl)
    else
        self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.1)
    end
end

function Downloader:_step(dl)
    if dl.cancelled then
        self:_releaseStandby(dl)
        self.show_transient(_("Download cancelled"), 2)
        return
    end

    if dl.index > dl.total then
        if dl.aborted then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            self:_releaseStandby(dl)
            logger.err(LOG_MODULE, "book download aborted:", log_error(dl.abort_reason))
            UIManager:show(ConfirmBox:new{
                text = T(_("Download aborted.\n\n%1"), dl.abort_reason),
                ok_text = _("Close"),
            })
            return
        end

        if #dl.selected == 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            self:_releaseStandby(dl)
            logger.err(LOG_MODULE, "book download failed: no chapters downloaded")
            self.show_info(_("No chapters were downloaded."))
            return
        end
        self:_setStage(dl, _("Building EPUB..."), dl.total)
        local save_started = time.now()
        local ok, path = pcall(function()
            if dl.single_chapter then
                local chapter = dl.selected[1]
                local uid = tostring(chapter.chapterUid or 1)
                return Content.save_chapter_epub(
                    self.settings, dl.book, chapter, dl.bodies[uid], dl.assets, dl.state.css
                )
            end
            local cover_data
            local cover_url = WeRead.normalize_cover_url(dl.book.cover)
            if cover_url and cover_url ~= "" then
                pcall(function() cover_data = self.client:get_binary(cover_url) end)
            end
            return Content.save_book_epub(
                self.settings, dl.book, dl.selected, dl.bodies,
                dl.suffix, dl.assets, dl.state.css, cover_data
            )
        end)
        self:_perf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        self:_releaseStandby(dl)
        local books = self.settings:get("books", {})
        local book_id = dl.book.book_id or dl.book.bookId
        if book_id then
            dl.book.cached_chapters = dl.book.cached_chapters or {}
            for ci, ch in ipairs(dl.selected) do
                dl.book.cached_chapters[tostring(ch.chapterUid or ci)] = ok and path or nil
            end
            if ok then
                dl.book.cached_file = path
            end
            dl.book.reader_url = dl.book.reader_url or WeRead.reader_url(book_id)
            books[book_id] = dl.book
            self.settings:set("books", books)
            self.settings:flush()
        end
        self.refresh_shelf()
        if not ok then
            logger.err(LOG_MODULE, "save downloaded book failed:", log_error(path))
            self.show_info(T(_("Download failed:\n%1"), display_error(path)))
            return
        end
        if #dl.failed > 0 then
            logger.warn(
                LOG_MODULE,
                "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed)
            )
        else
            logger.info(LOG_MODULE, "book download completed:", "chapters=", tostring(#dl.selected))
        end
        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path)
        end
        if dl.annotation_failed_batches > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                tostring(dl.annotation_failed_batches)
            )
        end
        self:_perf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "failed_thought_batches=", tostring(dl.annotation_failed_batches))
        UIManager:show(ConfirmBox:new{
            text = completion_text,
            ok_text = _("Read now"),
            ok_callback = self.safe_callback(_("Read now"), function()
                self.open_file(path)
            end),
            cancel_text = _("Close"),
        })
        return
    end

    local chapter = dl.chapters[dl.index]
    local chapter_uid = tostring(chapter.chapterUid or dl.index)

    -- Check for cached chapter before downloading.
    if chapter_cache_exists(self.settings, dl.book, chapter_uid) then
        local cached_xhtml, cached_assets = load_chapter_cache(self.settings, dl.book, chapter_uid)
        if cached_xhtml then
            dl.bodies[chapter_uid] = cached_xhtml
            table.insert(dl.selected, chapter)
            for _, asset in ipairs(cached_assets or {}) do
                table.insert(dl.assets, asset)
            end
            dl.index = dl.index + 1
            if dl.progress_dialog then
                dl.progress_dialog:reportProgress(dl.index - 1)
            end
            self:_scheduleGuarded(dl, function() self:_step(dl) end)
            return
        end
    end

    self:_setStage(dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1)

    -- Chapter download with exponential-backoff retry (matching original api.lua).
    dl._chapter_retry = dl._chapter_retry or 0
    local started = time.now()
    local ok, xhtml = pcall(function()
        return Content.fetch_single_chapter_source(
            self.client, self.settings, dl.book, chapter, dl.state
        )
    end)
    self:_perf(dl, "chapter_source", started, "ok=", tostring(ok),
        "retry=", tostring(dl._chapter_retry))

    if not ok then
        if dl._chapter_retry < CHAPTER_MAX_RETRIES then
            dl._chapter_retry = dl._chapter_retry + 1
            local delay = math.min(2 ^ (dl._chapter_retry - 1), CHAPTER_MAX_RETRY_INTERVAL)
            self:_setStage(dl,
                T(_("Retrying chapter %1/%2 · attempt %3"),
                    tostring(dl.index), tostring(dl.total), tostring(dl._chapter_retry)),
                dl.index - 1)
            -- Refresh reader state so psvts signatures don't expire between retries.
            pcall(function()
                Content.refresh_reader_state(self.client, dl.book, chapter)
            end)
            self:_scheduleGuarded(dl, function() self:_step(dl) end, delay)
            return
        end
        dl._chapter_retry = 0
        self:_failChapter(dl, xhtml)
        return
    end
    dl._chapter_retry = 0

    dl.current = { chapter = chapter, xhtml = xhtml }
    if Thoughts.is_download_enabled(self.settings) then
        self:_startAnnotations(dl)
    else
        self:_finishChapter(dl)
    end
end

return Downloader
