-- Presentation and background-task orchestration for the plugin updater.
-- Network, verification, extraction, and rollback logic live in lib/updater.
local ConfirmBox = require("ui/widget/confirmbox")
local DownloadDialog = require("weread.ui.download_dialog")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("weread.lib.logger")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T

local UpdaterUI = {}
UpdaterUI.__index = UpdaterUI

local function remove_file(path)
    if path then pcall(os.remove, path) end
end

local function write_progress(path, event)
    local temporary = path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then return end
    file:write(table.concat({
        tostring(event.stage or ""),
        tostring(math.floor(tonumber(event.percent) or 0)),
        tostring(math.floor(tonumber(event.current) or 0)),
        tostring(math.floor(tonumber(event.total) or 0)),
    }, "\t"))
    file:close()
    os.rename(temporary, path)
end

local function read_progress(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local line = file:read("*l")
    file:close()
    if not line then return nil end
    local stage, percent, current, total = line:match(
        "^([^\t]*)\t(%d+)\t(%d+)\t(%d+)$")
    if not stage then return nil end
    return {
        stage = stage,
        percent = tonumber(percent) or 0,
        current = tonumber(current) or 0,
        total = tonumber(total) or 0,
    }
end

local function format_bytes(value)
    value = tonumber(value) or 0
    if value >= 1024 * 1024 then
        return string.format("%.1f MB", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.0f KB", value / 1024)
    end
    return tostring(value) .. " B"
end

function UpdaterUI:new(options)
    options = options or {}
    return setmetatable({
        updater = assert(options.updater, "updater required"),
        settings = assert(options.settings, "settings required"),
        is_connected = options.is_connected or function() return true end,
        refresh_ui = options.refresh_ui or function() end,
    }, self)
end

function UpdaterUI:has_update()
    return self.updater:has_update()
end

function UpdaterUI:available_version()
    return self.updater:available_version()
end

function UpdaterUI:_run_subprocess(message, task, callback, trap_widget)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    if ok_trapper and Trapper and Trapper.wrap and not coroutine.running() then
        Trapper:wrap(function()
            self:_run_subprocess(message, task, callback, trap_widget)
        end)
        return
    end
    local message_widget
    if message then
        message_widget = InfoMessage:new{ text = message, timeout = 120 }
        UIManager:show(message_widget)
        trap_widget = message_widget
    end
    local function safe_task()
        local ok, result = xpcall(task, debug.traceback)
        if ok then return result end
        return { error = result }
    end
    local function finish(result)
        if message_widget then UIManager:close(message_widget) end
        callback(result)
    end
    if ok_trapper and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            safe_task, trap_widget)
        if completed then
            UIManager:scheduleIn(0.1, function() finish(result) end)
        else
            UIManager:scheduleIn(0.1, function()
                finish{ cancelled = true, error = "cancelled" }
            end)
        end
    else
        UIManager:scheduleIn(0.1, function() finish(safe_task()) end)
    end
end

function UpdaterUI:_show_release(release)
    if self.updater.compare_versions(
        release.version, self.updater.current_version) ~= 1 then
        UIManager:show(InfoMessage:new{
            text = T(_("WeRead Plugin is up to date (v%1)."),
                self.updater.current_version),
            timeout = 3,
        })
        return
    end
    local notes = release.notes or _("No release notes were provided.")
    local viewer
    viewer = TextViewer:new{
        title = T(_("v%1 -> v%2"),
            self.updater.current_version, release.version),
        text = notes,
        text_type = "general",
        auto_para_direction = true,
        buttons_table = {
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(viewer) end,
                },
                {
                    text = _("Download and install"),
                    callback = function()
                        UIManager:close(viewer)
                        UIManager:scheduleIn(0.1, function()
                            self:install(release)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

function UpdaterUI:check(manual)
    if manual and not self.is_connected() then
        UIManager:show(InfoMessage:new{
            text = _("No network connection. Please connect Wi-Fi and try again."),
        })
        return false
    end
    self:_run_subprocess(manual and _("Checking for updates…") or nil, function()
        local release, err = self.updater:fetch_release()
        return { release = release, error = err }
    end, function(result)
        if not result or not result.release then
            logger.warn("update check failed:", result and result.error or "cancelled")
            if manual and not (result and result.cancelled) then
                UIManager:show(InfoMessage:new{
                    text = T(_("Update check failed:\n%1"),
                        result and result.error or _("Unknown error")),
                })
            end
            return
        end
        self.updater:cache_release(result.release)
        self.refresh_ui()
        if manual then self:_show_release(result.release) end
    end)
    return true
end

function UpdaterUI:show_cached_update()
    local release = self.updater:cached_release()
    if not release then return self:check(true) end
    self:_show_release(release)
end

function UpdaterUI:_progress_title(event)
    if event.stage == "downloading" then
        local download_percent = event.total > 0
            and math.floor(math.min(1, event.current / event.total) * 100) or 0
        return T(_("Downloading update · %1%\n%2 / %3"),
            download_percent, format_bytes(event.current), format_bytes(event.total))
    elseif event.stage == "checksum" then
        return _("Downloading checksum…")
    elseif event.stage == "verifying" then
        return _("Verifying update package…")
    elseif event.stage == "extracting" then
        return _("Extracting update package…")
    elseif event.stage == "installing" then
        return _("Installing update…")
    elseif event.stage == "complete" then
        return _("Update installed.")
    end
    return _("Preparing update…")
end

function UpdaterUI:install(release)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    if ok_trapper and Trapper and Trapper.wrap and not coroutine.running() then
        Trapper:wrap(function() self:install(release) end)
        return
    end

    local progress_path = self.settings.data_dir .. "/update-progress"
    remove_file(progress_path)
    remove_file(progress_path .. ".tmp")
    local dialog = DownloadDialog:new{
        title = T(_("Preparing WeRead Plugin v%1…"), release.version),
        progress_max = 100,
        refresh_time_seconds = 1,
        dismissable = false,
    }
    dialog:show()

    local active = true
    local last_stage, last_title_percent
    local function poll()
        if not active then return end
        local event = read_progress(progress_path)
        if event then
            local title_percent = event.stage == "downloading" and event.total > 0
                and math.floor(event.current / event.total * 20) or -1
            if event.stage ~= last_stage or title_percent ~= last_title_percent then
                dialog:setTitle(self:_progress_title(event))
                last_stage, last_title_percent = event.stage, title_percent
            end
            dialog:reportProgress(math.max(0, math.min(100, event.percent)))
        end
        UIManager:scheduleIn(0.5, poll)
    end
    poll()

    self:_run_subprocess(nil, function()
        local ok, err = self.updater:install_release(release, function(event)
            write_progress(progress_path, event)
        end)
        return { success = ok == true, error = err }
    end, function(result)
        active = false
        UIManager:unschedule(poll)
        remove_file(progress_path)
        remove_file(progress_path .. ".tmp")
        dialog:close()
        if not result or not result.success then
            logger.err("update installation failed:",
                result and result.error or "cancelled")
            if not (result and result.cancelled) then
                UIManager:show(InfoMessage:new{
                    text = T(_("Update installation failed:\n%1"),
                        result and result.error or _("Unknown error")),
                })
            end
            return
        end
        self.updater:clear_available_update()
        self.refresh_ui()
        UIManager:show(ConfirmBox:new{
            text = T(
                _("WeRead Plugin v%1 was installed.\n\nRestart KOReader to apply the update?"),
                release.version),
            ok_text = _("Restart now"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end, dialog)
end

function UpdaterUI:schedule_auto_check()
    local state = self.settings:get("update")
    if state.auto_check ~= true then return end
    local last = tonumber(state.last_check) or 0
    if os.time() - last < self.updater.AUTO_CHECK_INTERVAL then return end
    UIManager:scheduleIn(5, function()
        if self.is_connected() then self:check(false) end
    end)
end

return UpdaterUI
