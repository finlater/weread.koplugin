package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload.device = function()
    return { unpackArchive = function() return true end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, scheduleIn = function() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, value) return value end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(value) return value end,
        T = function(template, ...)
            local values = { ... }
            return (template:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end

local Updater = require("weread.lib.updater")

expect(Updater.MAX_PACKAGE_BYTES == 10 * 1024 * 1024,
    "update package limit must be 10 MiB")

expect(Updater.compare_versions("1.2.3", "1.2.2") == 1,
    "newer version was not detected")
expect(Updater.compare_versions("v1.2.3", "1.2.3") == 0,
    "v-prefixed version should compare equally")
expect(Updater.compare_versions("1.2.2", "1.2.3") == -1,
    "older version was not detected")
expect(Updater.compare_versions("invalid", "1.2.3") == nil,
    "invalid version should be rejected")
expect(Updater.compare_versions("1.2.3-beta", "1.2.3") == nil,
    "non-release version should be rejected")

local direct_first = Updater.candidate_urls(Updater.API_URL, false)
expect(#direct_first == 4 and direct_first[1] == Updater.API_URL
    and direct_first[2]:find("gh%-proxy.com"),
    "direct-first source order was wrong")
local proxy_first = Updater.candidate_urls(Updater.API_URL, true)
expect(#proxy_first == 4 and proxy_first[1]:find("gh%-proxy.com")
    and proxy_first[4] == Updater.API_URL,
    "proxy-first source order was wrong")
expect(#Updater.candidate_urls("https://example.com/update.zip", true) == 0,
    "untrusted update URL should not receive proxy candidates")

local release, release_err = Updater.parse_release({
    tag_name = "v0.7.0",
    draft = false,
    prerelease = false,
    body = "## What's Changed\n\n**Added** `updates`",
    html_url = "https://github.com/finlater/weread.koplugin/releases/tag/v0.7.0",
    assets = {
        {
            name = "weread.koplugin-v0.7.0.zip",
            browser_download_url = "https://github.com/finlater/weread.koplugin/releases/download/v0.7.0/weread.koplugin-v0.7.0.zip",
            size = 1234,
        },
        {
            name = "weread.koplugin-v0.7.0.zip.sha256",
            browser_download_url = "https://github.com/finlater/weread.koplugin/releases/download/v0.7.0/weread.koplugin-v0.7.0.zip.sha256",
        },
    },
})
expect(release ~= nil and release_err == nil, "valid release was rejected")
expect(release.version == "0.7.0" and release.archive_size == 1234,
    "release metadata was parsed incorrectly")
expect(release.notes:find("Added updates", 1, true) ~= nil,
    "release notes were not normalized")

local function parse_notes(notes)
    return assert(Updater.parse_release{
        tag_name = "v0.7.0", body = notes,
        assets = {
            { name = "weread.koplugin-v0.7.0.zip", browser_download_url = release.archive_url },
            { name = "weread.koplugin-v0.7.0.zip.sha256", browser_download_url = release.checksum_url },
        },
    }).notes
end
local long_notes = string.rep("中文更新内容，支持完整滚动阅读。\n", 120) .. "最后一条更新"
expect(parse_notes(long_notes) == long_notes, "long release notes were truncated")
local bounded_notes = parse_notes(string.rep("中", Updater.MAX_NOTES_BYTES))
expect(#bounded_notes <= Updater.MAX_NOTES_BYTES
    and bounded_notes:gsub("中", "") == "...", "notes limit split a UTF-8 character")

local missing, missing_err = Updater.parse_release({
    tag_name = "v0.7.0",
    assets = {},
})
expect(missing == nil and missing_err:find("checksum", 1, true),
    "release without checksum should be rejected")

local foreign = Updater.parse_release({
    tag_name = "v0.7.0",
    assets = {
        { name = "weread.koplugin-v0.7.0.zip", browser_download_url = "https://example.com/plugin.zip" },
        { name = "weread.koplugin-v0.7.0.zip.sha256", browser_download_url = "https://example.com/plugin.sha256" },
    },
})
expect(foreign == nil, "foreign download URL should be rejected")

package.loaded["ltn12"] = {
    sink = {
        file = function(file)
            return function(chunk)
                if chunk then file:write(chunk) else file:close() end
                return 1
            end
        end,
        table = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    },
}
package.loaded["socket"] = {
    skip = function(count, ...)
        return select(count + 1, ...)
    end,
}
package.loaded["socketutil"] = {
    FILE_BLOCK_TIMEOUT = 1,
    FILE_TOTAL_TIMEOUT = 1,
    LARGE_BLOCK_TIMEOUT = 1,
    LARGE_TOTAL_TIMEOUT = 1,
    set_timeout = function() end,
    reset_timeout = function() end,
}
local request_count = 0
package.loaded["socket/http"] = {
    request = function(options)
        request_count = request_count + 1
        local ok, err = options.sink("abc")
        if not ok then return nil, err end
        ok, err = options.sink("def")
        if not ok then return nil, err end
        options.sink(nil)
        return 1, 200, {}, "OK"
    end,
}

local update_state = { prefer_proxy = false }
local updater = Updater:new{
    settings = {
        get = function() return update_state end,
        set = function() end,
        flush = function() end,
    },
    current_version = "0.6.0",
    plugin_dir = "/tmp/weread.koplugin",
}
updater:cache_release(release)
expect(updater:should_notify("0.7.0"), "new release should notify by default")
expect(not updater:should_notify("0.6.0") and not updater:should_notify("0.5.0"),
    "current or older release should not notify")
local before_snooze = os.time()
updater:snooze_update("0.7.0")
expect(update_state.snooze_until >= before_snooze + 86400
    and not updater:should_notify("0.7.0"), "snooze must suppress the version for 24 hours")
expect(updater:should_notify("0.8.0"), "snooze must not hide a newer version")
local reloaded = Updater:new{
    settings = updater.settings, current_version = "0.6.0", plugin_dir = updater.plugin_dir,
}
expect(not reloaded:should_notify("0.7.0"), "snooze must survive instance recreation")
update_state.snooze_until = os.time()
expect(reloaded:should_notify("0.7.0"), "snooze should expire after 24 hours")
updater:skip_update("0.7.0")
updater:cache_release(release)
expect(not reloaded:should_notify("0.7.0") and reloaded:should_notify("0.8.0"),
    "skipped version must survive checks and leave newer releases visible")
expect(reloaded:cached_release().version == "0.7.0", "skipping must preserve manual update")
local backup_exists, purged_path = true, nil
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path)
        if path == updater.plugin_dir .. ".backup" and backup_exists then
            return "directory"
        end
    end,
}
package.loaded["ffi/util"] = {
    purgeDir = function(path) purged_path = path end,
}
local cleanup_ok, cleanup_err = updater:cleanup_backup()
expect(cleanup_ok == true and cleanup_err == nil
        and purged_path == updater.plugin_dir .. ".backup",
    "successful startup should remove the previous update backup")
backup_exists, purged_path = false, nil
cleanup_ok, cleanup_err = updater:cleanup_backup()
expect(cleanup_ok == true and cleanup_err == nil and purged_path == nil,
    "backup cleanup should be a no-op when no backup exists")
local progress = {}
local download_path = "/tmp/weread-updater-progress-spec.bin"
local downloaded, download_err = updater:_http_get(
    Updater.RELEASE_PREFIX .. "v0.7.0/test.zip",
    download_path,
    function(received, total)
        progress[#progress + 1] = { received, total }
    end,
    6,
    Updater.MAX_PACKAGE_BYTES)
expect(downloaded == true and download_err == nil,
    "streaming download failed")
expect(#progress == 2 and progress[1][1] == 3 and progress[2][1] == 6
    and progress[2][2] == 6,
    "streaming download did not report real byte progress")
local downloaded_file = assert(io.open(download_path, "rb"))
expect(downloaded_file:read("*a") == "abcdef",
    "streaming download wrote unexpected content")
downloaded_file:close()
os.remove(download_path)

request_count = 0
local oversized, oversized_err = updater:_http_get_with_mirrors(
    Updater.RELEASE_PREFIX .. "v0.7.0/test.zip",
    download_path, nil, 0, 5)
expect(oversized == nil and oversized_err == "download exceeds size limit",
    "streaming download should stop as soon as it exceeds the size limit")
expect(request_count == 1,
    "size-limit failures should not retry the download through mirrors")
expect(io.open(download_path, "rb") == nil,
    "oversized partial download should be removed")

local updater_source = assert(io.open("weread/lib/updater.lua", "r")):read("*a")
expect(updater_source:find('require("ui/', 1, true) == nil,
    "core updater must not import UI modules")

local meta = assert(io.open("_meta.lua", "r")):read("*a")
local main = assert(io.open("main.lua", "r")):read("*a")
local meta_version = meta:match('version%s*=%s*"([^"]+)"')
local main_version = main:match('version%s*=%s*"([^"]+)"')
expect(meta_version == main_version, "main.lua and _meta.lua versions must match")

print(("updater_spec: %d checks"):format(checks))
