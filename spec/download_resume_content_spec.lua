-- Filesystem-level regression coverage for full-book checkpointing.
-- Run with: luajit spec/download_resume_content_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local archive_calls = {}
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.crypto"] = function()
    return {
        sha256_hex = function(data)
            return ("%08x%08x"):format(#data, #data * 31)
        end,
    }
end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["ffi/util"] = function()
    return {
        purgeDir = function(path)
            return os.execute("rm -rf " .. string.format("%q", path))
        end,
    }
end
package.preload["lfs"] = function()
    local function quoted(path) return string.format("%q", path) end
    return {
        attributes = function(path, attribute)
            local probe = io.popen("test -d " .. quoted(path)
                .. " && echo directory || (test -f " .. quoted(path) .. " && echo file)")
            local mode = probe:read("*l")
            probe:close()
            return attribute == "mode" and mode or (mode and { mode = mode } or nil)
        end,
        dir = function(path)
            local listing = io.popen("ls -a " .. quoted(path))
            return function()
                local name = listing:read("*l")
                if not name then listing:close() end
                return name
            end
        end,
    }
end
package.preload["ffi/archiver"] = function()
    local Writer = {}
    function Writer:new() return setmetatable({}, { __index = self }) end
    function Writer:open(path)
        self.path = path
        local file = assert(io.open(path, "wb"))
        file:write("archive")
        file:close()
        return true
    end
    function Writer:setZipCompression() return true end
    function Writer:addFileFromMemory(name, data)
        archive_calls[#archive_calls + 1] = { kind = "memory", name = name, data = data }
        return true
    end
    function Writer:addPath(name, path, recursive)
        archive_calls[#archive_calls + 1] = {
            kind = "path", name = name, path = path, recursive = recursive,
        }
        return false -- KOReader's successful EOF convention.
    end
    function Writer:close() end
    return { Writer = Writer }
end

local Content = require("weread.lib.content")
local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local settings = {
    cache_dir = root,
    get = function(_self, _key, default) return default end,
}
local book = { book_id = "resume-book", title = "Resume Book", cache_dir = root }
local chapters = {
    { chapterUid = 11, title = "One" },
    { chapterUid = 22, title = "Two" },
}
local workspace = Content.open_full_download_workspace(settings, book)
Content.save_full_download_css(workspace, "body{color:black}")
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first</p>")
Content.save_full_download_chapter(workspace, chapters[2], 2, "<p>second</p>")

local completed = Content.full_download_completed_chapters(workspace, chapters)
expect(completed[1] and completed[2], "checkpointed chapters were not found")
local changed_catalog = {
    chapters[1], { chapterUid = 33, title = "Changed chapter" },
}
local changed_completed = Content.full_download_completed_chapters(
    workspace, changed_catalog)
expect(changed_completed[1] and not changed_completed[2],
    "checkpoint marker did not reject a different chapter at the same index")
local restored = assert(Content.load_full_download_chapter(workspace, chapters[2], 2))
expect(restored:find("second", 1, true) ~= nil,
    "checkpointed chapter body could not be restored")
expect(Content.load_full_download_css(workspace) == "body{color:black}",
    "checkpointed stylesheet could not be restored")

Content.save_full_download_rendered_chapter(workspace, chapters[1], 1, "<p>rendered</p>")
local rendered = assert(Content.load_full_download_chapter(workspace, chapters[1], 1))
expect(rendered:find("first", 1, true) ~= nil and not rendered:find("rendered", 1, true),
    "footnote rendering overwrote the pristine resumable checkpoint")

local stale_rendered = assert(io.open(workspace.rendered_text_dir .. "/stale.xhtml", "wb"))
stale_rendered:write("stale")
stale_rendered:close()
Content.reset_full_download_rendered_text(workspace)
expect(not io.open(workspace.rendered_text_dir .. "/stale.xhtml", "rb"),
    "rendered chapter workspace was not reset")
expect(Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "resetting rendered chapters removed the pristine checkpoint")
Content.save_full_download_rendered_chapter(workspace, chapters[1], 1, "<p>rendered first</p>")
Content.save_full_download_rendered_chapter(workspace, chapters[2], 2, "<p>rendered second</p>")
expect(Content.full_download_rendered_chapter_exists(workspace, chapters[1], 1)
    and Content.full_download_rendered_chapter_exists(workspace, chapters[2], 2),
    "rendered chapters were not available for EPUB packaging")

local first_path = Content.full_download_chapter_path(workspace, chapters[1], 1)
local truncated = assert(io.open(first_path, "wb"))
truncated:write("<!-- weread-chapter-uid: 11 -->")
truncated:close()
expect(not Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "truncated checkpoint with a valid marker was accepted")
Content.save_full_download_chapter(workspace, chapters[1], 1, "<p>first</p>")

local original_open = io.open
-- luacheck: push ignore 122
io.open = function(path, mode)
    local file, err = original_open(path, mode)
    if not file or path:sub(-5) ~= ".part" or mode ~= "wb" then
        return file, err
    end
    return {
        write = function(_self, data) return file:write(data) end,
        close = function()
            file:close()
            return nil, "No space left on device"
        end,
    }
end
local close_ok = pcall(Content.save_full_download_chapter,
    workspace, chapters[1], 1, "<p>must not commit</p>")
io.open = original_open
-- luacheck: pop
expect(not close_ok, "checkpoint committed after close reported a disk error")
expect(Content.full_download_chapter_exists(workspace, chapters[1], 1),
    "previous complete checkpoint was invalidated after close failure")

local output = Content.save_book_epub(settings, book, chapters,
    { __workspace_text_dir = workspace.rendered_text_dir }, "full", {}, "body{color:black}")
expect(io.open(output, "rb") ~= nil, "streamed EPUB was not committed")
local streamed_text = false
for _, call in ipairs(archive_calls) do
    if call.kind == "path" and call.name == "OEBPS/text" then
        streamed_text = call.path == workspace.rendered_text_dir and call.recursive == true
    end
end
expect(streamed_text, "EPUB writer did not stream the checkpoint text directory")

Content.cleanup_download_workspace(workspace)
expect(not io.open(workspace.text_dir .. "/chapter-001.xhtml", "rb"),
    "successful cleanup did not remove the resumable workspace")

print(("download_resume_content_spec: %d checks"):format(checks))
