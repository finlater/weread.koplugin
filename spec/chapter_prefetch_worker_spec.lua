package.path = "./?.lua;" .. package.path

local calls = {}
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function(_client, book)
            calls[#calls + 1] = "reader"
            book.reader_url = "https://reader/book"
        end,
        create_download_workspace = function()
            calls[#calls + 1] = "workspace"
            return { path = "/tmp/work", incoming_dir = "/tmp/work/in",
                asset_dir = "/tmp/work/images" }
        end,
        fetch_single_chapter_source = function(_client, settings)
            calls[#calls + 1] = "source"
            settings:update_auth({ wr_ticket = "renewed" })
            return "<p>body</p>"
        end,
        finalize_single_chapter_content = function()
            calls[#calls + 1] = "images"
            return "<p>final</p>", {}
        end,
        save_chapter_epub = function(_settings, book)
            calls[#calls + 1] = "epub"
            local path = "/tmp/book-chapter.epub"
            book.cache_dir = "/tmp/cache/book"
            book.annotation_documents = {
                [path] = { clean = true, chapters = { { chapterUid = "2" } } },
            }
            return path
        end,
        cleanup_download_workspace = function()
            calls[#calls + 1] = "cleanup"
        end,
    }
end
package.preload["weread.lib.footnotes"] = function()
    return {
        scan_chapter = function() return {} end,
        build_book_index = function() return {} end,
        transform_chapter = function(body) return body, { converted = 0 } end,
        validate = function() return true end,
        has_converted = function() return false end,
        get_css = function() return "" end,
    }
end

local flushes = 0
local values = {
    cache = { download_book_images = true }, cookies = {}, wr_ticket = "old",
    wr_wrpa = "",
}
local settings = {
    get = function(_self, key, default)
        return values[key] == nil and default or values[key]
    end,
    set = function(_self, key, value) values[key] = value end,
    flush = function() flushes = flushes + 1 end,
}
settings.update_auth = function(self, credentials, options)
    if credentials.wr_ticket then self:set("wr_ticket", credentials.wr_ticket) end
    if not options or options.flush ~= false then self:flush() end
end

local progress = {}
local context = {
    emit = function(state) progress[#progress + 1] = state.stage end,
    checkCancelled = function() end,
    sleep = function() end,
}
local Worker = require("weread.lib.chapter_prefetch_worker")
local result = Worker.run(settings, {}, { book_id = "book" },
    { chapterUid = "2", title = "Two" }, context)

assert(result.path == "/tmp/book-chapter.epub")
assert(result.chapter_uid == "2" and result.cache_dir == "/tmp/cache/book")
assert(result.annotation_document and result.annotation_document.clean)
assert(result.auth and result.auth.wr_ticket == "renewed")
assert(flushes == 0, "child worker must not flush parent LuaSettings")
assert(table.concat(calls, ",")
    == "reader,workspace,source,images,epub,cleanup")
assert(table.concat(progress, ",")
    == "reader,source,images,footnotes,epub")

print("chapter_prefetch_worker_spec: isolated settings and complete pipeline passed")
