-- GitHub Release based self-updater.
--
-- Update checks are read-only. Installation is only performed after explicit
-- confirmation, verifies the release SHA-256, stages the archive, and keeps
-- the previous plugin directory as a rollback copy.
local Crypto = require("weread.lib.crypto")
local logger = require("weread.lib.logger")

local Updater = {}
Updater.__index = Updater

Updater.AUTO_CHECK_INTERVAL = 60 * 60
Updater.REMINDER_INTERVAL = 24 * 60 * 60
Updater.MAX_NOTES_BYTES = 64 * 1024
Updater.MAX_PACKAGE_BYTES = 10 * 1024 * 1024
Updater.API_URL = "https://api.github.com/repos/finlater/weread.koplugin/releases/latest"
Updater.RELEASE_PREFIX = "https://github.com/finlater/weread.koplugin/releases/download/"
Updater.GITHUB_MIRRORS = {
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
}

local function plugin_dir_from_source()
    local source = debug.getinfo(1, "S").source or ""
    return source:match("^@?(.+)/weread/lib/[^/]+$")
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function read_file(path, max_bytes)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    if max_bytes then
        local size, size_err = file:seek("end")
        if not size then
            file:close()
            return nil, size_err or "could not determine file size"
        end
        if size > max_bytes then
            file:close()
            return nil, "file is larger than expected"
        end
        local reset, reset_err = file:seek("set", 0)
        if not reset then
            file:close()
            return nil, reset_err or "could not rewind file"
        end
    end
    local data = file:read("*a")
    file:close()
    if not data then return nil, "could not read file" end
    return data
end

local function remove_file(path)
    if path then pcall(os.remove, path) end
end

local function remove_tree(path)
    if not path or path == "" then return nil, "invalid directory" end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil and ffiutil.purgeDir then
        local removed, err = pcall(ffiutil.purgeDir, path)
        if removed then return true end
        return nil, err
    end
    return nil, "directory cleanup unavailable"
end

local function make_path(path)
    local ok, util = pcall(require, "util")
    if ok and util and util.makePath then
        return util.makePath(path)
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path)
end

local function unpack_release(archive, stage)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(archive) then
        reader:close()
        return nil, reader.err or "could not open release archive"
    end
    local ok, err = true, nil
    for entry in reader:iterate() do
        local path = entry.path
        local safe = type(path) == "string"
            and path ~= ""
            and path:sub(1, 1) ~= "/"
            and path:find("\\", 1, true) == nil
            and path:match("^weread%.koplugin/") ~= nil
            and path:match("^%.%./") == nil
            and path:match("/%.%./") == nil
            and path:match("/%.%.$") == nil
        if not safe then
            ok, err = nil, "unsafe path in release archive"
            break
        end
        if not reader:extractToPath(path, stage .. "/" .. path) then
            ok, err = nil, reader.err or "archive extraction failed"
            break
        end
    end
    if reader.err then ok, err = nil, reader.err end
    reader:close()
    return ok, err
end

local function normalize_notes(notes)
    notes = trim(notes)
    if notes == "" then return nil end
    notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
    notes = notes:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
    notes = notes:gsub("%*%*(.-)%*%*", "%1")
    notes = notes:gsub("`(.-)`", "%1")
    if #notes > Updater.MAX_NOTES_BYTES then
        -- Keep cached metadata bounded without cutting a UTF-8 character.
        notes = notes:sub(1, Updater.MAX_NOTES_BYTES - 3)
            :gsub("[\194-\244][\128-\191]*$", "") .. "..."
    end
    return notes
end

function Updater.compare_versions(left, right)
    local function parts(version)
        local major, minor, patch = tostring(version or ""):match(
            "^v?(%d+)%.(%d+)%.(%d+)$")
        if not major then return nil end
        return { tonumber(major), tonumber(minor), tonumber(patch) }
    end
    local a, b = parts(left), parts(right)
    if not a or not b then return nil end
    for i = 1, 3 do
        if a[i] < b[i] then return -1 end
        if a[i] > b[i] then return 1 end
    end
    return 0
end

function Updater.candidate_urls(url, prefer_proxy)
    local is_allowed = url == Updater.API_URL
        or (type(url) == "string"
            and url:sub(1, #Updater.RELEASE_PREFIX) == Updater.RELEASE_PREFIX)
    if not is_allowed then return {} end
    local direct, proxies = { url }, {}
    for _, prefix in ipairs(Updater.GITHUB_MIRRORS) do
        proxies[#proxies + 1] = prefix .. url
    end
    local out = {}
    local first, second = prefer_proxy and proxies or direct,
        prefer_proxy and direct or proxies
    for _, candidate in ipairs(first) do out[#out + 1] = candidate end
    for _, candidate in ipairs(second) do out[#out + 1] = candidate end
    return out
end

function Updater.parse_release(data)
    if type(data) ~= "table" or data.draft == true or data.prerelease == true then
        return nil, "invalid release metadata"
    end
    local version = type(data.tag_name) == "string"
        and data.tag_name:match("^v(%d+%.%d+%.%d+)$") or nil
    if not version then return nil, "invalid release tag" end

    local archive_name = "weread.koplugin-v" .. version .. ".zip"
    local checksum_name = archive_name .. ".sha256"
    local archive_url, checksum_url, archive_size
    for _, asset in ipairs(data.assets or {}) do
        if asset.name == archive_name then
            archive_url = asset.browser_download_url
            archive_size = tonumber(asset.size)
        elseif asset.name == checksum_name then
            checksum_url = asset.browser_download_url
        end
    end
    local function valid_url(url)
        return type(url) == "string"
            and url:sub(1, #Updater.RELEASE_PREFIX) == Updater.RELEASE_PREFIX
    end
    if not valid_url(archive_url) or not valid_url(checksum_url) then
        return nil, "release package or checksum is missing"
    end
    if archive_size and archive_size > Updater.MAX_PACKAGE_BYTES then
        return nil, "release package is too large"
    end
    return {
        version = version,
        archive_url = archive_url,
        checksum_url = checksum_url,
        archive_size = archive_size,
        notes = normalize_notes(data.body),
        release_url = data.html_url,
    }
end

function Updater:new(options)
    options = options or {}
    local obj = {
        settings = assert(options.settings, "settings required"),
        current_version = assert(options.current_version, "current_version required"),
        plugin_dir = options.plugin_dir or plugin_dir_from_source(),
    }
    assert(obj.plugin_dir and obj.plugin_dir ~= "", "plugin directory unavailable")
    return setmetatable(obj, self)
end

function Updater:_state()
    return self.settings:get("update")
end

function Updater:_save_state(values)
    local state = self:_state()
    for key, value in pairs(values) do state[key] = value end
    self.settings:set("update", state)
    self.settings:flush()
end

function Updater:has_update()
    local latest = self:_state().available_version
    return Updater.compare_versions(latest, self.current_version) == 1
end

function Updater:available_version()
    return self:has_update() and self:_state().available_version or nil
end

function Updater:should_notify(version)
    if Updater.compare_versions(version, self.current_version) ~= 1 then return false end
    local state = self:_state()
    if state.skipped_version == version then return false end
    return state.snoozed_version ~= version
        or os.time() >= (tonumber(state.snooze_until) or 0)
end

function Updater:snooze_update(version)
    self:_save_state{
        snoozed_version = version,
        snooze_until = os.time() + Updater.REMINDER_INTERVAL,
    }
end

function Updater:skip_update(version)
    self:_save_state{ skipped_version = version }
end

function Updater:_http_get(url, destination, on_download, total_hint, max_bytes)
    local http = require("socket/http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink, chunks, file, limit_error
    if destination then
        file = io.open(destination, "wb")
        if not file then return nil, "cannot create download file" end
        local file_sink = ltn12.sink.file(file)
        local received = 0
        sink = function(chunk, err)
            if chunk then
                if max_bytes and received + #chunk > max_bytes then
                    limit_error = "download exceeds size limit"
                    file_sink(nil, limit_error)
                    return nil, limit_error
                end
                received = received + #chunk
                if on_download then on_download(received, total_hint) end
            end
            return file_sink(chunk, err)
        end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        chunks = {}
        sink = ltn12.sink.table(chunks)
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader-WeRead-Updater/1.0",
            ["Accept"] = "application/vnd.github+json",
        },
        sink = sink,
        redirect = true,
    })
    socketutil:reset_timeout()
    if limit_error then
        remove_file(destination)
        return nil, limit_error
    end
    if headers == nil or code ~= 200 then
        if destination then remove_file(destination) end
        return nil, "HTTP " .. tostring(code or status or "error")
    end
    return destination and true or table.concat(chunks)
end

function Updater:_http_get_with_mirrors(url, destination, on_download, total_hint, max_bytes)
    local candidates = Updater.candidate_urls(url, self:_state().prefer_proxy == true)
    if #candidates == 0 then return nil, "update URL is not allowed" end
    local last_error
    for index, candidate in ipairs(candidates) do
        if on_download then on_download(0, total_hint) end
        local ok, err = self:_http_get(
            candidate, destination, on_download, total_hint, max_bytes)
        if ok then
            logger.info("update resource fetched:", "source=", tostring(index),
                "proxy=", tostring(candidate ~= url))
            return ok
        end
        if err == "download exceeds size limit" then return nil, err end
        last_error = err
        logger.warn("update resource source failed:", "source=", tostring(index),
            "proxy=", tostring(candidate ~= url), "error=", tostring(err))
    end
    return nil, last_error or "all update sources failed"
end

function Updater:fetch_release()
    local body, err = self:_http_get_with_mirrors(Updater.API_URL)
    if not body then return nil, err end
    local ok_json, json = pcall(require, "json")
    if not ok_json then return nil, "JSON support unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "invalid GitHub response" end
    return Updater.parse_release(data)
end

function Updater:cache_release(release)
    self:_save_state{
        last_check = os.time(),
        available_version = release.version,
        archive_url = release.archive_url,
        checksum_url = release.checksum_url,
        archive_size = release.archive_size or 0,
        release_notes = release.notes or "",
        release_url = release.release_url or "",
    }
end

function Updater:clear_available_update()
    self:_save_state{
        available_version = "",
        archive_url = "",
        checksum_url = "",
    }
end

function Updater:cached_release()
    local state = self:_state()
    if not self:has_update() then return nil end
    return {
        version = state.available_version,
        archive_url = state.archive_url,
        checksum_url = state.checksum_url,
        archive_size = state.archive_size,
        notes = state.release_notes ~= "" and state.release_notes or nil,
        release_url = state.release_url,
    }
end

-- The backup must survive installation so a failed activation can be rolled
-- back. Reaching the end of the next plugin initialization confirms that the
-- new copy can load, at which point the previous copy is no longer needed.
function Updater:cleanup_backup()
    local backup = self.plugin_dir .. ".backup"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and not lfs.attributes(backup, "mode") then
        return true
    end
    local removed, err = remove_tree(backup)
    if removed then
        logger.info("previous update backup removed")
        return true
    end
    logger.warn("could not remove previous update backup:", tostring(err))
    return nil, err
end

function Updater:install_release(release, on_progress)
    local function report(stage, percent, current, total)
        if on_progress then
            on_progress{
                stage = stage,
                percent = percent,
                current = current or 0,
                total = total or 0,
            }
        end
    end
    report("preparing", 0)
    local data_dir = self.settings.data_dir
    local archive = data_dir .. "/weread-update.zip"
    local checksum = archive .. ".sha256"
    local stage = data_dir .. "/update-stage"
    remove_file(archive)
    remove_file(checksum)
    remove_tree(stage)
    local made, make_err = make_path(stage)
    if not made then return nil, "cannot create staging directory: " .. tostring(make_err) end

    local archive_size = tonumber(release.archive_size) or 0
    local ok, err = self:_http_get_with_mirrors(
        release.archive_url, archive, function(received, total)
            local ratio = total and total > 0 and math.min(1, received / total) or 0
            report("downloading", math.floor(5 + ratio * 70), received, total or 0)
        end, archive_size, Updater.MAX_PACKAGE_BYTES)
    if not ok then remove_tree(stage); return nil, err end
    report("checksum", 76)
    local checksum_ok, checksum_err = self:_http_get_with_mirrors(release.checksum_url, checksum)
    if not checksum_ok then
        remove_file(archive); remove_tree(stage)
        return nil, checksum_err
    end
    local package, package_err = read_file(archive, Updater.MAX_PACKAGE_BYTES)
    local checksum_body = read_file(checksum, 4096)
    if not package or not checksum_body then
        remove_file(archive); remove_file(checksum); remove_tree(stage)
        return nil, package_err or "invalid checksum file"
    end
    report("verifying", 82)
    local expected = checksum_body:match("^%s*([0-9a-fA-F]+)")
    if not expected or #expected ~= 64 or Crypto.sha256_hex(package) ~= expected:lower() then
        remove_file(archive); remove_file(checksum); remove_tree(stage)
        return nil, "SHA-256 verification failed"
    end

    report("extracting", 90)
    local unpacked, unpack_err = unpack_release(archive, stage)
    remove_file(archive)
    remove_file(checksum)
    if not unpacked then remove_tree(stage); return nil, unpack_err or "archive extraction failed" end
    local staged_plugin = stage .. "/weread.koplugin"
    local meta = read_file(staged_plugin .. "/_meta.lua", 65536)
    local main = read_file(staged_plugin .. "/main.lua", 1024 * 1024)
    local staged_version = meta and meta:match('version%s*=%s*"([^"]+)"') or nil
    if not main or staged_version ~= release.version then
        remove_tree(stage)
        return nil, "release package structure or version is invalid"
    end

    report("installing", 97)
    local backup = self.plugin_dir .. ".backup"
    remove_tree(backup)
    local moved_old, move_old_err = os.rename(self.plugin_dir, backup)
    if not moved_old then remove_tree(stage); return nil, move_old_err or "could not back up plugin" end
    local moved_new, move_new_err = os.rename(staged_plugin, self.plugin_dir)
    if not moved_new then
        os.rename(backup, self.plugin_dir)
        remove_tree(stage)
        return nil, move_new_err or "could not activate update"
    end
    remove_tree(stage)
    report("complete", 100)
    return true
end

return Updater
