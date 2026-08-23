-- Full-book EPUB OPF must embed the weread keyword for CoverBrowser/ZenOS.
-- Run from the repo root with:
--   luajit spec/content_weread_keyword_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id)
            return "https://weread.qq.com/reader/" .. tostring(book_id)
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end

local archive_files = {}
package.preload["ffi/archiver"] = function()
    local Writer = {}
    function Writer:new() return setmetatable({}, { __index = self }) end
    function Writer:open(path)
        local file = assert(io.open(path, "wb"))
        file:write("partial")
        file:close()
        return true
    end
    function Writer:setZipCompression() return true end
    function Writer:addFileFromMemory(name, data)
        archive_files[name] = data
        return true
    end
    function Writer:addPath() return true end
    function Writer:close() end
    return { Writer = Writer }
end

local real_os_execute = os.execute
rawset(os, "execute", function() return 0 end)

local Content = require("weread.lib.content")
local settings = {
    cache_dir = ".",
    get = function(_self, _key, default) return default end,
}
local path = Content.save_book_epub(settings, {
    book_id = "book",
    title = "Tagged",
    cache_dir = ".",
}, { { chapterUid = 1, title = "One" } }, { ["1"] = "<p>body</p>" }, "book")

local opf = archive_files["OEBPS/content.opf"] or ""
expect(opf:find("<dc:subject>weread</dc:subject>", 1, true) ~= nil,
    "full-book OPF missing dc:subject weread")
expect(opf:find('name="keywords" content="weread"', 1, true) ~= nil,
    "full-book OPF missing keywords meta")

archive_files = {}
local chapter_path = Content.save_chapter_epub(settings, {
    book_id = "book",
    title = "Tagged",
    cache_dir = ".",
}, { chapterUid = 1, title = "One" }, "<p>body</p>")
local chapter_opf = archive_files["OEBPS/content.opf"] or ""
expect(chapter_opf:find("<dc:subject>weread</dc:subject>", 1, true) == nil,
    "chapter EPUB should not embed the weread shelf tag")

rawset(os, "execute", real_os_execute)
if type(path) == "string" then pcall(os.remove, path) end
if type(chapter_path) == "string" then pcall(os.remove, chapter_path) end

print(("content_weread_keyword_spec: %d checks"):format(checks))
