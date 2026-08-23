package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/reader/" .. tostring(book_id)
                .. "/" .. tostring(chapter_uid or "")
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end

local Content = require("weread.lib.content")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))

local downloads = {}
local client = {}
function client:get_binary()
    error("MP article images must not be buffered in Lua memory")
end
function client:download_to_file(url, path, opts)
    downloads[#downloads + 1] = { url = url, path = path, opts = opts }
    if url:match("qlogo") then error("injected download failure") end
    local file = assert(io.open(path, "wb"))
    file:write("\137PNG\r\n\026\n")
    local chunk = string.rep("x", 64 * 1024)
    for _index = 1, 64 do file:write(chunk) end
    file:close()
    return path
end

local progress = {}
local settings = { cache_dir = root }
local book = { book_id = "mp-book", cache_dir = root }
local article = { reviewId = "review/1", title = "Disk images" }
local body = [[
<p><img src="//mmbiz.qpic.cn/image?id=1&amp;format=png"></p>
<p><img src='https://mmbiz.qpic.cn/image?id=1&format=png'></p>
<p><img src="https://mmbiz.qlogo.cn/avatar/fail"></p>
<p><img src="https://example.test/untouched.png"></p>
]]

collectgarbage("collect")
local before_kb = collectgarbage("count")
local rewritten = Content.download_mp_images_to_files(
    client, settings, book, article, body, function(index, total)
        progress[#progress + 1] = { index, total }
    end)
collectgarbage("collect")
local after_kb = collectgarbage("count")

expect(#downloads == 2, "duplicate MP image URL was downloaded more than once")
expect(downloads[1].url
        == "https://mmbiz.qpic.cn/image?id=1&format=png",
    "protocol-relative or HTML-escaped MP image URL was not normalized")
expect(downloads[1].opts.max_bytes == 64 * 1024 * 1024,
    "MP image download size limit was not applied")
expect(#progress == 2 and progress[1][1] == 1 and progress[1][2] == 2
        and progress[2][1] == 2 and progress[2][2] == 2,
    "MP image progress did not count unique URLs")

local relative = ".weread-mp-review_1-assets/img-0001.png"
local _first, references = rewritten:gsub(relative, "")
expect(references == 2,
    "duplicate MP image references did not share a local file")
expect(not rewritten:match("data:image") and not rewritten:match(";base64,"),
    "MP image was still embedded as a base64 data URL")
expect(rewritten:match("https://mmbiz%.qlogo%.cn/avatar/fail"),
    "failed MP image download did not retain its remote source")
expect(rewritten:match("https://example%.test/untouched%.png"),
    "non-MP image source was unexpectedly rewritten")

local image = assert(io.open(root .. "/" .. relative, "rb"))
expect(image:read(8) == "\137PNG\r\n\026\n",
    "streamed MP image bytes were corrupted")
image:close()
expect(io.open(root .. "/.weread-mp-review_1-assets/img-0001.download", "rb")
        == nil,
    "successful MP image download left an incoming file")
expect(after_kb - before_kb < 1024,
    "MP image download retained resource-sized Lua memory")

assert(os.execute("rm -rf " .. string.format("%q", root)))
print(("mp_article_images_spec: %d checks"):format(checks))
