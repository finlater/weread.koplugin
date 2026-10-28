-- Regression coverage for chapter resource packages refused by the resource
-- CDN (HTTP 499). Run with: luajit spec/download_resource_package_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local warnings = {}
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function(...) warnings[#warnings + 1] = { ... } end,
        err = function() end,
    }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end }
end
package.preload["weread.lib.thoughts"] = function() return {} end

-- Replace the CDN backoff with an instant one so the spec stays fast.
local sleeps = {}
package.preload["socket"] = function()
    return { sleep = function(seconds) sleeps[#sleeps + 1] = seconds end }
end

local Content = require("weread.lib.content")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local workspace = {
    incoming_dir = root .. "/incoming",
    asset_dir = root .. "/images",
}
assert(os.execute("mkdir -p " .. string.format("%q", workspace.incoming_dir)))
assert(os.execute("mkdir -p " .. string.format("%q", workspace.asset_dir)))

local chapter = { chapterUid = 36, tar = "https://res.example.test/tar_1_36" }
local book = { book_id = "1" }

-- A burst refusal must be retried and then succeed without failing the chapter.
local attempts = 0
local recovering_client = {}
function recovering_client:get_binary()
    attempts = attempts + 1
    if attempts < 3 then
        error("HTTP 499, content_type=application/json;charset=utf-8, body_bytes=0")
    end
    return "tar-body"
end
local assets, src_map = Content.download_chapter_assets(
    recovering_client, book, chapter, {})
expect(attempts == 3, "a 499 burst was not retried until it cleared")
expect(#sleeps == 2 and sleeps[1] == 0.8 and sleeps[2] == 1.6,
    "resource package retries did not back off")
expect(type(assets) == "table" and type(src_map) == "table",
    "a recovered package did not return asset tables")

-- Persistent refusals must not raise: the chapter keeps its remote images.
sleeps = {}
local refusing_attempts = 0
local refusing_client = {}
function refusing_client:download_to_file()
    refusing_attempts = refusing_attempts + 1
    error("HTTP 499, content_type=application/json;charset=utf-8, body_bytes=0")
end
local ok, disk_assets, disk_map = pcall(Content.download_chapter_assets_to_files,
    refusing_client, book, chapter, {}, workspace)
expect(ok, "a refused resource package failed the chapter: " .. tostring(disk_assets))
expect(#disk_assets == 0 and next(disk_map) == nil,
    "a refused resource package must yield no assets")
expect(refusing_attempts == 4,
    "resource package refusal attempts: " .. tostring(refusing_attempts))
expect(io.open(workspace.incoming_dir .. "/chapter-36.tar", "rb") == nil,
    "a refused resource package left a partial file behind")
local saw_refusal_warning = false
for _, entry in ipairs(warnings) do
    if tostring(entry[2]):find("chapter resource package unavailable", 1, true) then
        saw_refusal_warning = true
    end
end
expect(saw_refusal_warning, "a refused package was not logged")

-- Entitlement failures are permanent and must not be retried.
local forbidden_attempts = 0
local forbidden_client = {}
function forbidden_client:get_binary()
    forbidden_attempts = forbidden_attempts + 1
    error("HTTP 403, content_type=application/json, body_bytes=12")
end
local forbidden_assets = Content.download_chapter_assets(
    forbidden_client, book, chapter, {})
expect(forbidden_attempts == 1, "a 403 was retried")
expect(#forbidden_assets == 0, "a 403 produced assets")

os.execute("rm -rf " .. string.format("%q", root))
print(("resource package spec: %d checks passed"):format(checks))
