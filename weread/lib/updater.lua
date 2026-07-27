-- Online self-update for weread.koplugin.
-- Downloads GitHub release assets or branch zipballs through optional China-friendly proxies.

local DataStorage = require("datastorage")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")

local PluginUtil = require("weread.lib.plugin_util")
local LOG_MODULE = PluginUtil.LOG_MODULE

local ok_archiver, Archiver = pcall(require, "ffi/archiver")
if not ok_archiver then
    Archiver = nil
end

local Updater = {}
Updater.__index = Updater

Updater.DEFAULT_OWNER = "rollingshmily"
Updater.DEFAULT_REPO = "weread.koplugin"
Updater.DEFAULT_BRANCH = "main"
Updater.PLUGIN_DIRNAME = "weread.koplugin"
Updater.USER_AGENT = "KOReader-WeRead-Updater"

-- Built-in proxies.
-- style="prefix": proxy .. "/" .. absolute_https_url  (gh-proxy.com / ghfast.top)
-- style="path":   proxy .. github_or_raw_pathname     (ghspeedup.com worker = runn.i.ng)
Updater.PROXY_PRESETS = {
    {
        id = "ghspeedup.com",
        label = "ghspeedup.com",
        url = "https://runn.i.ng",
        style = "path",
    },
    {
        id = "gh-proxy.com",
        label = "gh-proxy.com",
        url = "https://gh-proxy.com",
        style = "prefix",
    },
    {
        id = "ghfast.top",
        label = "ghfast.top",
        url = "https://ghfast.top",
        style = "prefix",
    },
    {
        id = "direct",
        label = "Direct (no proxy)",
        url = "",
        style = "direct",
    },
}

local DEFAULT_UPDATE = {
    -- auto | stable | branch
    -- auto: prefer latest GitHub release; fall back to branch zipball when missing
    channel = "auto",
    branch = Updater.DEFAULT_BRANCH,
    -- default to ghspeedup.com (runn.i.ng worker); fallbacks still tried automatically
    proxy_id = "ghspeedup.com",
    custom_proxy = "",
    check_on_start = false,
    last_check = 0,
    last_remote_version = "",
    last_remote_source = "",
    installed_version = "",
    installed_source = "",
}

local function normalize_proxy_id(proxy_id)
    proxy_id = tostring(proxy_id or "")
    -- migrate old preset id from v0.5.1
    if proxy_id == "runn.i.ng" then
        return "ghspeedup.com"
    end
    return proxy_id
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function trim(text)
    return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function ensure_dir(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    if util and util.makePath then
        util.makePath(path)
    else
        lfs.mkdir(path)
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function remove_path(path)
    if type(path) ~= "string" or path == "" then
        return
    end
    local mode = lfs.attributes(path, "mode")
    if mode == "file" then
        os.remove(path)
        return
    end
    if mode ~= "directory" then
        return
    end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            remove_path(path .. "/" .. name)
        end
    end
    lfs.rmdir(path)
end

local function copy_file(src, dest)
    local input, err_in = io.open(src, "rb")
    if not input then
        return false, err_in or "open source failed"
    end
    local parent = dest:match("^(.*)/")
    if parent and parent ~= "" then
        ensure_dir(parent)
    end
    local output, err_out = io.open(dest, "wb")
    if not output then
        input:close()
        return false, err_out or "open dest failed"
    end
    while true do
        local chunk = input:read(1024 * 64)
        if not chunk then
            break
        end
        output:write(chunk)
    end
    input:close()
    output:close()
    return true
end

local function parse_version(version)
    local text = trim(version):gsub("^[vV]", "")
    local major, minor, patch = text:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then
        major, minor = text:match("^(%d+)%.(%d+)")
        patch = "0"
    end
    if not major then
        major = text:match("^(%d+)")
        minor, patch = "0", "0"
    end
    return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0, text
end

function Updater.compare_versions(left, right)
    local l1, l2, l3 = parse_version(left)
    local r1, r2, r3 = parse_version(right)
    if l1 ~= r1 then
        return l1 < r1 and -1 or 1
    end
    if l2 ~= r2 then
        return l2 < r2 and -1 or 1
    end
    if l3 ~= r3 then
        return l3 < r3 and -1 or 1
    end
    return 0
end

function Updater.is_newer(remote_version, local_version)
    return Updater.compare_versions(local_version, remote_version) < 0
end

function Updater.extract_version_from_meta(text)
    if type(text) ~= "string" then
        return nil
    end
    return text:match('[Vv]ersion%s*=%s*"([^"]+)"')
        or text:match("[Vv]ersion%s*=%s*'([^']+)'")
end

function Updater:new(opts)
    opts = opts or {}
    local obj = {
        settings = opts.settings,
        owner = opts.owner or Updater.DEFAULT_OWNER,
        repo = opts.repo or Updater.DEFAULT_REPO,
        plugin_dirname = opts.plugin_dirname or Updater.PLUGIN_DIRNAME,
        plugin_path = opts.plugin_path,
        get_plugin_path = opts.get_plugin_path,
    }
    return setmetatable(obj, self)
end

function Updater:get_config()
    local stored = {}
    if self.settings and self.settings.get then
        stored = self.settings:get("update", {}) or {}
    end
    local cfg = deepcopy(DEFAULT_UPDATE)
    if type(stored) == "table" then
        for key, value in pairs(stored) do
            cfg[key] = value
        end
    end
    if cfg.channel ~= "stable" and cfg.channel ~= "branch" and cfg.channel ~= "auto" then
        cfg.channel = "auto"
    end
    if type(cfg.branch) ~= "string" or cfg.branch == "" then
        cfg.branch = Updater.DEFAULT_BRANCH
    end
    if type(cfg.proxy_id) ~= "string" or cfg.proxy_id == "" then
        cfg.proxy_id = "ghspeedup.com"
    else
        cfg.proxy_id = normalize_proxy_id(cfg.proxy_id)
    end
    if type(cfg.custom_proxy) ~= "string" then
        cfg.custom_proxy = ""
    end
    cfg.check_on_start = cfg.check_on_start == true
    return cfg
end

function Updater:save_config(cfg)
    if not self.settings or not self.settings.set then
        return
    end
    self.settings:set("update", cfg)
    if self.settings.flush then
        self.settings:flush()
    end
end

function Updater:update_config(patch)
    local cfg = self:get_config()
    for key, value in pairs(patch or {}) do
        cfg[key] = value
    end
    self:save_config(cfg)
    return cfg
end

function Updater.proxy_label(proxy_id, custom_proxy)
    proxy_id = normalize_proxy_id(proxy_id)
    if proxy_id == "custom" then
        local url = trim(custom_proxy)
        if url == "" then
            return "Custom"
        end
        return "Custom · " .. url
    end
    for _i, item in ipairs(Updater.PROXY_PRESETS) do
        if item.id == proxy_id then
            return item.label
        end
    end
    return proxy_id or "ghspeedup.com"
end

function Updater.lookup_proxy_preset(proxy_id_or_url)
    local key = normalize_proxy_id(proxy_id_or_url)
    for _i, item in ipairs(Updater.PROXY_PRESETS) do
        if item.id == key or item.url == key then
            return item
        end
    end
    return nil
end

function Updater:resolve_proxy_entry(cfg)
    cfg = cfg or self:get_config()
    if cfg.proxy_id == "custom" then
        return {
            id = "custom",
            label = Updater.proxy_label("custom", cfg.custom_proxy),
            url = trim(cfg.custom_proxy),
            -- custom defaults to classic full-URL prefix style
            style = "prefix",
        }
    end
    local preset = Updater.lookup_proxy_preset(cfg.proxy_id)
    if preset then
        return preset
    end
    return Updater.lookup_proxy_preset("ghspeedup.com")
end

function Updater:resolve_proxy_base(cfg)
    local entry = self:resolve_proxy_entry(cfg)
    return entry and entry.url or "https://runn.i.ng"
end

function Updater:proxy_candidates(cfg)
    cfg = cfg or self:get_config()
    local preferred = self:resolve_proxy_entry(cfg)
    local seen = {}
    local list = {}
    local function push(entry)
        if type(entry) ~= "table" then
            return
        end
        local base = trim(entry.url or ""):gsub("/+$", "")
        local style = entry.style or (base == "" and "direct" or "prefix")
        local key = style .. "|" .. base
        if seen[key] then
            return
        end
        seen[key] = true
        list[#list + 1] = {
            id = entry.id or base,
            label = entry.label or base,
            url = base,
            style = style,
        }
    end
    push(preferred)
    -- Fallbacks when the selected proxy cannot serve a given URL type.
    for _i, item in ipairs(Updater.PROXY_PRESETS) do
        push(item)
    end
    return list
end

-- Convert GitHub / raw.githubusercontent URLs into ghspeedup path-style targets.
-- Frontend site: https://ghspeedup.com  Worker: https://runn.i.ng
-- Examples:
--   https://github.com/o/r/releases/download/v1/a.zip
--     -> https://runn.i.ng/o/r/releases/download/v1/a.zip
--   https://raw.githubusercontent.com/o/r/main/_meta.lua
--     -> https://runn.i.ng/o/r/main/_meta.lua
--   https://github.com/o/r/archive/refs/heads/main.zip
--     -> https://runn.i.ng/o/r/archive/refs/heads/main.zip
function Updater.to_path_style_url(proxy_base, raw_url)
    proxy_base = trim(proxy_base):gsub("/+$", "")
    raw_url = tostring(raw_url or "")
    if proxy_base == "" then
        return raw_url
    end

    local host, rest = raw_url:match("^https?://([^/]+)(/.*)$")
    if not host then
        return nil, "unsupported url for path-style proxy"
    end
    host = host:lower()
    local path, query = rest, ""
    local qpos = rest:find("?", 1, true)
    if qpos then
        path = rest:sub(1, qpos - 1)
        query = rest:sub(qpos)
    end
    if path == "" then
        path = "/"
    end

    local allowed = {
        ["github.com"] = true,
        ["www.github.com"] = true,
        ["raw.githubusercontent.com"] = true,
        ["media.githubusercontent.com"] = true,
        ["codeload.github.com"] = true,
    }
    if not allowed[host] then
        -- api.github.com and other hosts are not served by ghspeedup path worker
        return nil, "host not supported by path-style proxy: " .. host
    end

    -- codeload.github.com/<owner>/<repo>/zip/refs/heads/<branch>
    -- map to /<owner>/<repo>/archive/refs/heads/<branch>.zip
    if host == "codeload.github.com" then
        local owner, repo, kind, rest = path:match([[^/([^/]+)/([^/]+)/(zip|tar%.gz)/(.*)$]])
        if owner and repo and rest then
            local ext = (kind == "zip") and ".zip" or ".tar.gz"
            path = string.format("/%s/%s/archive/%s%s", owner, repo, rest, ext)
        end
    end

    return proxy_base .. path .. query
end

function Updater.wrap_proxy(proxy_or_entry, raw_url)
    raw_url = tostring(raw_url or "")
    local entry
    if type(proxy_or_entry) == "table" then
        entry = proxy_or_entry
    else
        local base = trim(proxy_or_entry)
        entry = Updater.lookup_proxy_preset(base) or {
            url = base,
            style = (base == "" and "direct" or "prefix"),
        }
    end

    local proxy_base = trim(entry.url or ""):gsub("/+$", "")
    local style = entry.style or (proxy_base == "" and "direct" or "prefix")

    if style == "direct" or proxy_base == "" then
        return raw_url
    end

    if style == "path" then
        local path_url, err = Updater.to_path_style_url(proxy_base, raw_url)
        if not path_url then
            return nil, err
        end
        return path_url
    end

    -- prefix style
    if raw_url:sub(1, #proxy_base + 1) == proxy_base .. "/" then
        return raw_url
    end
    return proxy_base .. "/" .. raw_url
end

function Updater:get_local_version()
    local plugin_dir = self:get_plugin_dir()
    if plugin_dir then
        local meta_path = plugin_dir .. "/_meta.lua"
        local file = io.open(meta_path, "rb")
        if file then
            local body = file:read("*a")
            file:close()
            local version = Updater.extract_version_from_meta(body)
            if version and version ~= "" then
                return version
            end
        end
    end
    local cfg = self:get_config()
    if cfg.installed_version and cfg.installed_version ~= "" then
        return cfg.installed_version
    end
    return "0.0.0"
end

function Updater:get_plugin_dir()
    if type(self.get_plugin_path) == "function" then
        local ok, path = pcall(self.get_plugin_path)
        if ok and type(path) == "string" and path ~= "" then
            return path:gsub("/+$", "")
        end
    end
    if type(self.plugin_path) == "string" and self.plugin_path ~= "" then
        return self.plugin_path:gsub("/+$", "")
    end
    local data_dir = DataStorage:getDataDir()
    return data_dir .. "/plugins/" .. self.plugin_dirname
end

function Updater:http_get(url, opts)
    opts = opts or {}
    local chunks = {}
    local headers = {
        ["User-Agent"] = Updater.USER_AGENT,
        ["Accept"] = opts.accept or "*/*",
    }
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local block_timeout = opts.block_timeout or 20
    local total_timeout = opts.total_timeout or 120
    socketutil:set_timeout(block_timeout, total_timeout)
    local ok, code, resp_headers, status = pcall(function()
        local _, resp_code, resp_hdrs, resp_status = http.request{
            url = url,
            method = "GET",
            headers = headers,
            redirect = true,
            sink = ltn12.sink.table(chunks),
        }
        return resp_code, resp_hdrs, resp_status
    end)
    socketutil:reset_timeout()

    if not ok then
        return nil, tostring(code)
    end

    local body = table.concat(chunks)
    local numeric = tonumber(code)
    if numeric == nil then
        return nil, tostring(status or code or "network error"), body
    end
    if numeric < 200 or numeric >= 300 then
        return nil, "HTTP " .. tostring(numeric), body
    end
    return body, nil, resp_headers
end

function Updater:http_get_with_proxies(raw_url, opts)
    local errors = {}
    for _i, entry in ipairs(self:proxy_candidates()) do
        local url, wrap_err = Updater.wrap_proxy(entry, raw_url)
        local label = entry.label or entry.id or entry.url or "proxy"
        if not url then
            errors[#errors + 1] = string.format("%s => skip (%s)", label, tostring(wrap_err))
            logger.warn(LOG_MODULE, "updater GET skip:", label, wrap_err)
        else
            logger.info(LOG_MODULE, "updater GET", url)
            local body, err = self:http_get(url, opts)
            if body then
                return body, nil, {
                    proxy = entry.url or "",
                    proxy_id = entry.id,
                    style = entry.style,
                    url = url,
                }
            end
            errors[#errors + 1] = string.format("%s => %s", label, tostring(err))
            logger.warn(LOG_MODULE, "updater GET failed:", url, err)
        end
    end
    return nil, table.concat(errors, "; ")
end

function Updater:download_to_file(raw_url, local_path, opts)
    opts = opts or {}
    local parent = local_path:match("^(.*)/")
    if parent and parent ~= "" then
        ensure_dir(parent)
    end

    local errors = {}
    for _i, entry in ipairs(self:proxy_candidates()) do
        local url, wrap_err = Updater.wrap_proxy(entry, raw_url)
        local label = entry.label or entry.id or entry.url or "proxy"
        if not url then
            errors[#errors + 1] = string.format("%s => skip (%s)", label, tostring(wrap_err))
            logger.warn(LOG_MODULE, "updater download skip:", label, wrap_err)
        else
            logger.info(LOG_MODULE, "updater download", url)

            local file, open_err = io.open(local_path, "wb")
            if not file then
                return false, open_err or "failed to open file for writing"
            end

            socketutil:set_timeout(
                opts.block_timeout or socketutil.FILE_BLOCK_TIMEOUT or 30,
                opts.total_timeout or socketutil.FILE_TOTAL_TIMEOUT or 300
            )
            local ok, code, headers, status = pcall(function()
                local _, resp_code, resp_headers, resp_status = http.request{
                    url = url,
                    method = "GET",
                    redirect = true,
                    sink = socketutil.file_sink(file),
                    headers = {
                        ["User-Agent"] = Updater.USER_AGENT,
                        ["Accept"] = "application/zip, application/octet-stream, */*",
                    },
                }
                return resp_code, resp_headers, resp_status
            end)
            socketutil:reset_timeout()
            pcall(function() file:close() end)

            if not ok then
                os.remove(local_path)
                errors[#errors + 1] = string.format("%s => %s", label, tostring(code))
            else
                local numeric = tonumber(code)
                local size = lfs.attributes(local_path, "size") or 0
                if numeric == 200 and size > 64 then
                    return true, nil, {
                        proxy = entry.url or "",
                        proxy_id = entry.id,
                        style = entry.style,
                        url = url,
                        bytes = size,
                    }
                end
                os.remove(local_path)
                errors[#errors + 1] = string.format(
                    "%s => %s",
                    label,
                    tostring(status or code or "bad response")
                )
            end
        end
    end
    return false, table.concat(errors, "; ")
end

function Updater:fetch_latest_release()
    local api = string.format(
        "https://api.github.com/repos/%s/%s/releases/latest",
        self.owner, self.repo
    )
    local body, err, meta = self:http_get_with_proxies(api, {
        accept = "application/vnd.github+json",
        block_timeout = 15,
        total_timeout = 45,
    })
    if not body then
        return nil, err
    end

    local ok_json, json = pcall(require, "json")
    if not ok_json then
        ok_json, json = pcall(require, "rapidjson")
    end
    if not ok_json or not json or not json.decode then
        return nil, "json module unavailable"
    end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, "invalid release json"
    end
    if data.message and not data.tag_name then
        -- GitHub error payload (404 / rate limit)
        return nil, tostring(data.message)
    end
    if type(data.tag_name) ~= "string" or data.tag_name == "" then
        return nil, "release has no tag"
    end
    data._proxy = meta and meta.proxy or nil
    return data, nil
end

function Updater:fetch_remote_meta(ref)
    ref = trim(ref)
    if ref == "" then
        ref = self:get_config().branch or Updater.DEFAULT_BRANCH
    end
    local raw_url = string.format(
        "https://raw.githubusercontent.com/%s/%s/%s/_meta.lua",
        self.owner, self.repo, ref
    )
    local body, err, meta = self:http_get_with_proxies(raw_url, {
        accept = "text/plain",
        block_timeout = 15,
        total_timeout = 45,
    })
    if not body then
        return nil, err
    end
    local version = Updater.extract_version_from_meta(body)
    if not version then
        return nil, "remote _meta.lua has no version"
    end
    return {
        version = version,
        body = body,
        ref = ref,
        proxy = meta and meta.proxy or nil,
        source = "branch:" .. ref,
    }, nil
end

function Updater:pick_release_download_url(release)
    if type(release) ~= "table" then
        return nil
    end
    if type(release.assets) == "table" then
        for _i, asset in ipairs(release.assets) do
            local name = tostring(asset.name or "")
            local url = asset.browser_download_url
            if type(url) == "string" and url ~= "" then
                if name:match("%.zip$") or name:match("%.tar%.gz$") or name:match("%.tgz$") then
                    return url, "release-asset:" .. name
                end
            end
        end
    end
    if type(release.zipball_url) == "string" and release.zipball_url ~= "" then
        return release.zipball_url, "release-zipball"
    end
    local tag = tostring(release.tag_name or "")
    if tag ~= "" then
        return string.format(
            "https://github.com/%s/%s/archive/refs/tags/%s.zip",
            self.owner, self.repo, tag
        ), "tag-archive:" .. tag
    end
    return nil
end

function Updater:check_for_update()
    local cfg = self:get_config()
    local local_version = self:get_local_version()
    local result = {
        local_version = local_version,
        remote_version = nil,
        has_update = false,
        source = nil,
        download_url = nil,
        release = nil,
        notes = nil,
        channel = cfg.channel,
        checked_at = os.time(),
    }

    local function finish(extra_err)
        result.error = extra_err
        self:update_config({
            last_check = result.checked_at,
            last_remote_version = result.remote_version or "",
            last_remote_source = result.source or "",
        })
        return result
    end

    local release_err
    if cfg.channel == "auto" or cfg.channel == "stable" then
        local release, err = self:fetch_latest_release()
        if release then
            local remote_version = tostring(release.tag_name or ""):gsub("^[vV]", "")
            local download_url, source = self:pick_release_download_url(release)
            result.remote_version = remote_version
            result.release = release
            result.notes = release.body
            result.download_url = download_url
            result.source = source or ("release:" .. tostring(release.tag_name))
            result.has_update = Updater.is_newer(remote_version, local_version)
            if result.download_url then
                return finish(nil)
            end
            release_err = "release has no downloadable asset"
        else
            release_err = err
            if cfg.channel == "stable" then
                return finish(err or "no stable release")
            end
        end
    end

    -- Branch / development channel, or auto fallback when releases are absent.
    local meta, meta_err = self:fetch_remote_meta(cfg.branch)
    if not meta then
        local message = meta_err or "failed to fetch branch metadata"
        if release_err then
            message = message .. " | release: " .. tostring(release_err)
        end
        return finish(message)
    end

    result.remote_version = meta.version
    result.source = meta.source
    result.notes = nil
    result.download_url = string.format(
        "https://github.com/%s/%s/archive/refs/heads/%s.zip",
        self.owner, self.repo, cfg.branch
    )
    if cfg.channel == "branch" then
        -- Dev channel: any version difference or equal version still offers refresh
        -- only when remote is newer; equal => up to date, but force still available.
        result.has_update = Updater.is_newer(meta.version, local_version)
            or Updater.compare_versions(meta.version, local_version) ~= 0
        -- If versions equal on branch channel, treat as up-to-date by default.
        if Updater.compare_versions(meta.version, local_version) == 0 then
            result.has_update = false
            result.can_force = true
        end
    else
        result.has_update = Updater.is_newer(meta.version, local_version)
        result.can_force = not result.has_update
        if release_err then
            result.release_fallback_reason = release_err
        end
    end
    return finish(nil)
end

local function open_archive(zip_path)
    if not Archiver or not Archiver.Reader then
        return nil, "Archiver module unavailable"
    end
    local reader = Archiver.Reader:new()
    if not reader then
        return nil, "failed to create archive reader"
    end
    local ok = reader:open(zip_path)
    if not ok then
        return nil, "failed to open archive"
    end
    return reader
end

local function archive_entries(reader)
    local entries = {}
    if reader.iterate then
        for entry in reader:iterate() do
            local path = entry.path or entry.name or entry
            local mode = entry.mode
            if type(path) == "string" then
                if not mode then
                    mode = path:sub(-1) == "/" and "directory" or "file"
                end
                entries[#entries + 1] = {
                    path = path:gsub("^/+", ""),
                    mode = mode,
                }
            end
        end
        return entries
    end
    if reader.listFiles then
        local list = reader:listFiles() or {}
        for _i, path in ipairs(list) do
            if type(path) == "string" then
                local mode = path:sub(-1) == "/" and "directory" or "file"
                entries[#entries + 1] = {
                    path = path:gsub("^/+", ""),
                    mode = mode,
                }
            end
        end
    end
    return entries
end

local function detect_root_prefix(entries)
    -- GitHub zipballs nest files under "<repo>-<ref>/..."
    for _i, entry in ipairs(entries) do
        local path = entry.path
        if path:match("^[^/]+/_meta%.lua$") or path:match("^[^/]+/main%.lua$") then
            return path:match("^([^/]+)/")
        end
        if path == "_meta.lua" or path == "main.lua" then
            return ""
        end
    end
    -- Fallback: common single top-level directory
    local top
    for _i, entry in ipairs(entries) do
        local first = entry.path:match("^([^/]+)")
        if first and first ~= "" then
            if not top then
                top = first
            elseif top ~= first then
                return ""
            end
        end
    end
    return top or ""
end

local function extract_entry(reader, entry_path, dest_path)
    if reader.extractToPath then
        return reader:extractToPath(entry_path, dest_path)
    end
    if reader.extractFile then
        return reader:extractFile(entry_path, dest_path)
    end
    return false, "archive extract API unavailable"
end

function Updater:install_archive(zip_path)
    local reader, open_err = open_archive(zip_path)
    if not reader then
        return false, open_err
    end

    local entries = archive_entries(reader)
    if #entries == 0 then
        pcall(function() reader:close() end)
        return false, "archive is empty or unreadable"
    end

    local root = detect_root_prefix(entries)
    local target_dir = self:get_plugin_dir()
    local parent = target_dir:match("^(.*)/")
    if parent then
        ensure_dir(parent)
    end

    local staging_dir = target_dir .. ".update-staging"
    local backup_dir = target_dir .. ".bak"
    remove_path(staging_dir)
    ensure_dir(staging_dir)

    local extracted = 0
    local has_meta = false
    local has_main = false
    local extract_err

    for _i, entry in ipairs(entries) do
        if entry.mode ~= "directory" and not entry.path:match("/$") then
            local relative = entry.path
            if root ~= "" then
                local prefix = root .. "/"
                if relative:sub(1, #prefix) == prefix then
                    relative = relative:sub(#prefix + 1)
                else
                    relative = nil
                end
            end
            if relative and relative ~= "" and not relative:match("%.%.") then
                -- Skip VCS / editor junk if present.
                if not relative:match("^%.git/")
                    and not relative:match("/%.git/")
                    and relative ~= ".git"
                then
                    local dest = staging_dir .. "/" .. relative
                    local dest_parent = dest:match("^(.*)/")
                    if dest_parent then
                        ensure_dir(dest_parent)
                    end
                    local ok = extract_entry(reader, entry.path, dest)
                    if not ok then
                        -- Some Archiver builds want the path without re-open state
                        -- after iterate(); reopen once and retry single file.
                        pcall(function() reader:close() end)
                        reader = open_archive(zip_path)
                        if not reader then
                            extract_err = "failed to reopen archive during extract"
                            break
                        end
                        ok = extract_entry(reader, entry.path, dest)
                    end
                    if not ok then
                        extract_err = "failed to extract: " .. entry.path
                        break
                    end
                    extracted = extracted + 1
                    if relative == "_meta.lua" then
                        has_meta = true
                    elseif relative == "main.lua" then
                        has_main = true
                    end
                end
            end
        end
    end
    pcall(function() reader:close() end)

    if extract_err then
        remove_path(staging_dir)
        return false, extract_err
    end
    if extracted == 0 or not has_meta or not has_main then
        remove_path(staging_dir)
        return false, "archive does not look like weread.koplugin"
    end

    -- Swap staging into place with backup rollback.
    remove_path(backup_dir)
    local target_mode = lfs.attributes(target_dir, "mode")
    if target_mode == "directory" then
        local renamed, rename_err = os.rename(target_dir, backup_dir)
        if not renamed then
            -- Fallback: copy file-by-file backup then wipe target.
            logger.warn(LOG_MODULE, "updater rename backup failed:", rename_err)
            remove_path(backup_dir)
            ensure_dir(backup_dir)
            local function mirror(src, dest)
                for name in lfs.dir(src) do
                    if name ~= "." and name ~= ".." then
                        local from = src .. "/" .. name
                        local to = dest .. "/" .. name
                        local mode = lfs.attributes(from, "mode")
                        if mode == "directory" then
                            ensure_dir(to)
                            mirror(from, to)
                        elseif mode == "file" then
                            local ok_copy, copy_err = copy_file(from, to)
                            if not ok_copy then
                                error(copy_err or "copy failed")
                            end
                        end
                    end
                end
            end
            local ok_backup, backup_err = pcall(mirror, target_dir, backup_dir)
            if not ok_backup then
                remove_path(staging_dir)
                remove_path(backup_dir)
                return false, "failed to backup current plugin: " .. tostring(backup_err)
            end
            remove_path(target_dir)
        end
    end

    local swapped = os.rename(staging_dir, target_dir)
    if not swapped then
        -- Manual move
        ensure_dir(target_dir)
        local function move_tree(src, dest)
            for name in lfs.dir(src) do
                if name ~= "." and name ~= ".." then
                    local from = src .. "/" .. name
                    local to = dest .. "/" .. name
                    local mode = lfs.attributes(from, "mode")
                    if mode == "directory" then
                        ensure_dir(to)
                        move_tree(from, to)
                    elseif mode == "file" then
                        local ok_copy, copy_err = copy_file(from, to)
                        if not ok_copy then
                            error(copy_err or "copy failed")
                        end
                    end
                end
            end
        end
        local ok_move, move_err = pcall(move_tree, staging_dir, target_dir)
        remove_path(staging_dir)
        if not ok_move then
            -- Rollback
            remove_path(target_dir)
            if lfs.attributes(backup_dir, "mode") == "directory" then
                os.rename(backup_dir, target_dir)
            end
            return false, "failed to install update: " .. tostring(move_err)
        end
    end

    remove_path(backup_dir)
    return true, {
        extracted = extracted,
        target_dir = target_dir,
    }
end

function Updater:download_and_install(download_url, meta)
    meta = meta or {}
    if type(download_url) ~= "string" or download_url == "" then
        return false, "missing download url"
    end

    local cache_root = DataStorage:getDataDir() .. "/cache/weread/updates"
    ensure_dir(cache_root)
    local zip_path = string.format("%s/weread-update-%d.zip", cache_root, os.time())

    local ok_dl, dl_err, dl_meta = self:download_to_file(download_url, zip_path)
    if not ok_dl then
        return false, "download failed: " .. tostring(dl_err)
    end

    local ok_install, info_or_err = self:install_archive(zip_path)
    os.remove(zip_path)
    if not ok_install then
        return false, info_or_err
    end

    local installed_version = meta.remote_version or self:get_local_version()
    self:update_config({
        installed_version = installed_version,
        installed_source = meta.source or "",
        last_remote_version = installed_version,
        last_remote_source = meta.source or "",
        last_check = os.time(),
    })

    info_or_err.version = installed_version
    info_or_err.proxy = dl_meta and dl_meta.proxy or nil
    info_or_err.source = meta.source
    return true, info_or_err
end

function Updater:perform_update(check_result, opts)
    opts = opts or {}
    check_result = check_result or self:check_for_update()
    if check_result.error and not check_result.download_url then
        return false, check_result.error, check_result
    end
    if not check_result.download_url then
        return false, "no download url", check_result
    end
    if not check_result.has_update and not opts.force then
        return false, "already up to date", check_result
    end

    local ok, info = self:download_and_install(check_result.download_url, {
        remote_version = check_result.remote_version,
        source = check_result.source,
    })
    return ok, info, check_result
end

return Updater
