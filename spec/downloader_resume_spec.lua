-- Regression coverage for resumable full-book downloads. Run with:
--   luajit spec/downloader_resume_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local scheduled = {}
local fetched = {}
local checkpointed = {}
local streamed_bodies
local saved_chapters
local checkpoint_checks = 0
local cleanup_count = 0
local fail_next_save = false
local rendered_chapters_complete = true
local save_book_calls = 0

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        show = function() end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, _options)
            return {
                show = function() end,
                close = function() end,
                setTitle = function() end,
                reportProgress = function() end,
            }
        end,
    }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.footnotes"] = function()
    return {
        scan_chapter = function() return {} end,
        transform_chapter = function(body) return body, {} end,
        validate = function() return true end,
        has_converted = function() return false end,
        build_book_index = function() return {} end,
        get_css = function() return "" end,
    }
end
package.preload["weread.lib.content"] = function()
    local persisted = { [1] = true }
    local workspace = {
        path = "/cache/book/.weread-download-resume-full",
        text_dir = "/cache/book/.weread-download-resume-full/text",
        rendered_text_dir = "/cache/book/.weread-download-resume-full/rendered-text",
        asset_dir = "/cache/book/.weread-download-resume-full/images",
    }
    return {
        ensure_reader_state = function() end,
        open_full_download_workspace = function() return workspace end,
        load_full_download_css = function() return "body{}" end,
        full_download_workspace_used_asset_names = function() return {} end,
        full_download_completed_chapters = function()
            checkpoint_checks = checkpoint_checks + 1
            local completed = {}
            for chapter_index, value in pairs(persisted) do
                completed[chapter_index] = value
            end
            return completed
        end,
        fetch_single_chapter_source = function(_client, _settings, _book, chapter)
            fetched[#fetched + 1] = chapter.chapterUid
            return "<p>chapter " .. tostring(chapter.chapterUid) .. "</p>"
        end,
        finalize_single_chapter_content = function(_client, _settings, _book, _chapter, xhtml)
            return xhtml, {}
        end,
        save_full_download_css = function() end,
        save_full_download_chapter = function(_workspace, chapter, chapter_index, xhtml)
            persisted[chapter_index] = true
            checkpointed[#checkpointed + 1] = {
                uid = chapter.chapterUid, index = chapter_index, body = xhtml,
            }
        end,
        reset_full_download_rendered_text = function() end,
        save_full_download_rendered_chapter = function() end,
        full_download_rendered_chapter_exists = function()
            return rendered_chapters_complete
        end,
        load_full_download_chapter = function(_workspace, chapter)
            return "<p>checkpoint " .. tostring(chapter.chapterUid) .. "</p>"
        end,
        full_download_workspace_assets = function() return {} end,
        save_book_epub = function(_settings, _book, chapters, bodies)
            save_book_calls = save_book_calls + 1
            if fail_next_save then error("injected package failure") end
            saved_chapters = chapters
            streamed_bodies = bodies
            return "/cache/book/full.epub"
        end,
        cleanup_download_workspace = function() cleanup_count = cleanup_count + 1 end,
    }
end

local Downloader = require("weread.lib.downloader")
local books = {}
local settings = {
    get = function(_self, key, default)
        if key == "books" then return books end
        if key == "cache" then return { download_book_images = false } end
        return default
    end,
    set = function(_self, key, value) if key == "books" then books = value end end,
    flush = function() end,
}
local downloader = Downloader:new{
    settings = settings,
    client = {},
    require_login = function() return true end,
    run_online_task = function(_label, callback) callback(); return true end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
    show_info = function() end,
    show_transient = function() end,
    safe_callback = function(_label, callback) return callback end,
}
local chapters = {
    { chapterUid = 1, title = "One" },
    { chapterUid = 2, title = "Two" },
}
expect(downloader:start({ book_id = "book", title = "Book" }, chapters, "full", {
    silent_completion = true,
}), "resumable download did not start")

while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end

expect(#fetched == 1 and fetched[1] == 2,
    "resume should fetch only the unfinished chapter")
expect(#checkpointed >= 1 and checkpointed[1].uid == 2
    and checkpointed[1].index == 2,
    "newly downloaded chapter was not checkpointed at its catalog index")
expect(saved_chapters == chapters, "final EPUB did not retain the full catalog order")
expect(type(streamed_bodies) == "table"
    and streamed_bodies.__workspace_text_dir:match("/rendered%-text$"),
    "final EPUB did not stream rendered chapter files")
expect(checkpoint_checks >= 2,
    "full-book checkpoints were not verified again before packaging")

local cleanup_before_failure = cleanup_count
fail_next_save = true
downloader:_step{
    book = { book_id = "book", title = "Book" },
    chapters = chapters,
    selected = chapters,
    bodies = {},
    assets = {},
    state = { css = "body{}" },
    suffix = "full",
    index = 3,
    total = 2,
    failed = {},
    resumable = true,
    workspace = {
        path = "/cache/book/.weread-download-resume-full",
        text_dir = "/cache/book/.weread-download-resume-full/text",
        rendered_text_dir = "/cache/book/.weread-download-resume-full/rendered-text",
        asset_dir = "/cache/book/.weread-download-resume-full/images",
    },
    workspace_verified = true,
    footnotes_done = true,
    annotation_failed_batches = 0,
    started_at = 1000,
}
expect(cleanup_count == cleanup_before_failure,
    "failed EPUB packaging removed resumable chapter checkpoints")

local saves_before_missing_rendered = save_book_calls
rendered_chapters_complete = false
downloader:_step{
    book = { book_id = "book", title = "Book" },
    chapters = chapters,
    selected = chapters,
    bodies = {},
    assets = {},
    state = { css = "body{}" },
    suffix = "full",
    index = 3,
    total = 2,
    failed = {},
    resumable = true,
    workspace = {
        path = "/cache/book/.weread-download-resume-full",
        text_dir = "/cache/book/.weread-download-resume-full/text",
        rendered_text_dir = "/cache/book/.weread-download-resume-full/rendered-text",
        asset_dir = "/cache/book/.weread-download-resume-full/images",
    },
    workspace_verified = true,
    footnotes_done = true,
    annotation_failed_batches = 0,
    started_at = 1000,
}
rendered_chapters_complete = true
expect(save_book_calls == saves_before_missing_rendered,
    "packaging started without every rendered chapter")
expect(cleanup_count == cleanup_before_failure,
    "missing rendered chapter removed resumable checkpoints")

local batch_dl = { index = 1, total = 1000, completed = {} }
for chapter_index = 1, batch_dl.total do
    batch_dl.completed[chapter_index] = true
end
expect(downloader:_skipCompletedChapterBatch(batch_dl),
    "completed chapter batch was not scheduled")
expect(batch_dl.index == 26,
    "resume batch should yield after 25 completed chapters")
expect(#scheduled == 1,
    "resume batch should schedule one continuation instead of one per chapter")

print(("downloader_resume_spec: %d checks"):format(checks))
