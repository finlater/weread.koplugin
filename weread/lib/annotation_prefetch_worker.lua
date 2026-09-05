local Chapters = require("weread.lib.annotation_chapters")
local Content = require("weread.lib.content")
local Sync = require("weread.lib.annotation_sync")
local WorkerSettings = require("weread.lib.worker_settings")

local M = {}

function M.run(settings, client, context, chapters, worker_context)
    local auth_result = WorkerSettings.capture(settings)
    local source_book = context.book or {
        bookId = context.book_id,
        book_id = context.book_id,
        title = context.binding and context.binding.title,
        format = context.binding and context.binding.format,
    }
    local job = Sync:new {
        store = context.store,
        client = client,
        book_id = context.book_id,
        chapters = chapters or context.chapters,
        ranges = context.ranges,
        document = nil,
        document_key = nil,
        refresh = false,
        offline = false,
        fetch_source = function(chapter)
            local html = Content.fetch_chapter_xhtml(client, settings,
                source_book, chapter)
            if source_book._content_format == "txt" then
                return context.store:get(context.book_id, "original",
                    Chapters.uid(chapter)) or {}
            end
            return html
        end,
    }
    while true do
        worker_context.checkCancelled()
        local done, state = job:step()
        if done == nil then error(state, 0) end
        if done then return { auth = auth_result() } end
        worker_context.emit(state)
        if state and tonumber(state.delay) and tonumber(state.delay) > 0 then
            worker_context.sleep(state.delay)
        end
    end
end

return M
