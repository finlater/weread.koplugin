local Content = require("weread.lib.content")
local Footnotes = require("weread.lib.footnotes")
local WorkerSettings = require("weread.lib.worker_settings")

local M = {}

local function empty_footnote_stats()
    return { candidates = 0, converted = 0, image_notes = 0,
        backlinks = 0, removed_note_blocks = 0, unresolved = 0, fallback = 0 }
end

function M.run(settings, client, book, chapter, context)
    local auth_result = WorkerSettings.capture(settings)
    local workspace
    local ok, result = xpcall(function()
        context.emit { stage = "reader" }
        Content.ensure_reader_state(client, book)
        context.checkCancelled()

        local cache = settings:get("cache", {})
        local state = {}
        if cache.download_book_images and Content.create_download_workspace then
            workspace = Content.create_download_workspace(settings, book)
            state.workspace = workspace
        end

        local xhtml
        for attempt = 1, 3 do
            context.emit { stage = "source", attempt = attempt }
            local fetched, value = pcall(Content.fetch_single_chapter_source,
                client, settings, book, chapter, state)
            if fetched then xhtml = value; break end
            if attempt == 3 then error(value, 0) end
            context.sleep(0.8 * attempt)
        end
        context.checkCancelled()

        local uid = tostring(chapter.chapterUid or chapter.chapterId or "1")
        local scan_ok, scan = pcall(Footnotes.scan_chapter, xhtml, chapter)
        context.emit { stage = cache.download_book_images and "images" or "process" }
        state.image_progress = function(current, total)
            context.checkCancelled()
            context.emit { stage = "images", current = current, count = total }
        end
        local finalized, assets = Content.finalize_single_chapter_content(
            client, settings, book, chapter, xhtml, state)
        context.checkCancelled()

        local stats = empty_footnote_stats()
        if scan_ok then
            context.emit { stage = "footnotes" }
            local index = Footnotes.build_book_index({ [uid] = scan }, { chapter })
            local transformed, current = Footnotes.transform_chapter(
                finalized, scan, index)
            local valid = Footnotes.validate(transformed)
            if valid then
                finalized = transformed
                stats = current or stats
                if Footnotes.has_converted(current) then
                    state.css = (state.css or "") .. "\n"
                        .. Footnotes.get_css(cache.book_footnotes_in_popup == true)
                end
            else
                stats.fallback = 1
            end
        else
            stats.fallback = 1
        end
        context.checkCancelled()

        context.emit { stage = "epub" }
        local path = Content.save_chapter_epub(settings, book, chapter,
            finalized, assets, state.css)
        local descriptor = book.annotation_documents
            and book.annotation_documents[path] or nil
        return {
            path = path,
            chapter_uid = uid,
            cache_dir = book.cache_dir,
            reader_url = book.reader_url,
            annotation_document = descriptor,
            footnote_stats = stats,
            auth = auth_result(),
        }
    end, debug.traceback)
    if workspace then Content.cleanup_download_workspace(workspace) end
    if not ok then error(result, 0) end
    return result
end

return M
