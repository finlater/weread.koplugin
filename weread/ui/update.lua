-- UI flows for plugin self-update.
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")

local PluginUtil = require("weread.lib.plugin_util")
local Updater = require("weread.lib.updater")
local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}

function M:getUpdater()
    if self.updater then
        return self.updater
    end
    self.updater = Updater:new{
        settings = self.settings,
        plugin_path = self.path,
        get_plugin_path = function()
            if type(self.path) == "string" and self.path ~= "" then
                return self.path
            end
            return nil
        end,
    }
    return self.updater
end

function M:getUpdateMenuItems()
    local updater = self:getUpdater()
    return {
        {
            text = _("Check for updates"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Check for updates"), function()
                self:checkPluginUpdate()
            end),
        },
        {
            text_func = function()
                local current = updater:get_config()
                local label
                if current.channel == "stable" then
                    label = _("Stable releases")
                elseif current.channel == "branch" then
                    label = _("Development branch")
                else
                    label = _("Auto (release, else branch)")
                end
                return T(_("Update channel: %1"), label)
            end,
            keep_menu_open = true,
            callback = self:safeCallback(_("Update channel"), function(touchmenu_instance)
                self:showUpdateChannelPicker(touchmenu_instance)
            end),
        },
        {
            text_func = function()
                local current = updater:get_config()
                return T(_("GitHub proxy: %1"), Updater.proxy_label(current.proxy_id, current.custom_proxy))
            end,
            keep_menu_open = true,
            callback = self:safeCallback(_("GitHub proxy"), function(touchmenu_instance)
                self:showUpdateProxyPicker(touchmenu_instance)
            end),
        },
        {
            text = _("Check for updates on start"),
            checked_func = function()
                return updater:get_config().check_on_start == true
            end,
            keep_menu_open = true,
            check_callback_updates_menu = true,
            callback = self:safeCallback(_("Check for updates on start"), function(touchmenu_instance)
                local current = updater:get_config()
                updater:update_config({ check_on_start = not (current.check_on_start == true) })
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end),
        },
        {
            text_func = function()
                local current = updater:get_config()
                local local_version = updater:get_local_version()
                if tonumber(current.last_check or 0) > 0 and current.last_remote_version ~= "" then
                    return T(
                        _("Current v%1 · remote %2"),
                        local_version,
                        current.last_remote_version
                    )
                end
                return T(_("Current version: v%1"), local_version)
            end,
            enabled_func = function()
                return false
            end,
        },
    }
end

function M:showUpdateChannelPicker(touchmenu_instance)
    local updater = self:getUpdater()
    local current = updater:get_config().channel
    local choices = {
        { id = "auto", label = _("Auto (release, else branch)") },
        { id = "stable", label = _("Stable releases") },
        { id = "branch", label = _("Development branch (main)") },
    }
    local buttons = {}
    for _i, item in ipairs(choices) do
        local label = item.label
        if item.id == current then
            label = label .. "  ✓"
        end
        table.insert(buttons, {
            {
                text = label,
                callback = function()
                    UIManager:close(self._update_channel_dialog)
                    self._update_channel_dialog = nil
                    updater:update_config({ channel = item.id })
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self._update_channel_dialog)
                self._update_channel_dialog = nil
            end,
        },
    })
    self._update_channel_dialog = ButtonDialog:new{
        title = _("Update channel"),
        buttons = buttons,
    }
    UIManager:show(self._update_channel_dialog)
end

function M:showUpdateProxyPicker(touchmenu_instance)
    local updater = self:getUpdater()
    local current = updater:get_config()
    local buttons = {}
    for _i, item in ipairs(Updater.PROXY_PRESETS) do
        local label = item.label
        if item.id == current.proxy_id then
            label = label .. "  ✓"
        end
        table.insert(buttons, {
            {
                text = label,
                callback = function()
                    UIManager:close(self._update_proxy_dialog)
                    self._update_proxy_dialog = nil
                    updater:update_config({ proxy_id = item.id })
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self._update_proxy_dialog)
                self._update_proxy_dialog = nil
            end,
        },
    })
    self._update_proxy_dialog = ButtonDialog:new{
        title = _("GitHub proxy"),
        buttons = buttons,
    }
    UIManager:show(self._update_proxy_dialog)
end

function M:maybeCheckPluginUpdateOnStart()
    local updater = self:getUpdater()
    local cfg = updater:get_config()
    if not cfg.check_on_start then
        return
    end
    -- Avoid hammering proxies: at most once every 12 hours.
    local last = tonumber(cfg.last_check or 0) or 0
    if last > 0 and (os.time() - last) < (12 * 60 * 60) then
        return
    end
    UIManager:scheduleIn(3, function()
        if not self:isNetworkConnected() then
            return
        end
        self:checkPluginUpdate({ silent_up_to_date = true })
    end)
end

function M:checkPluginUpdate(opts)
    opts = opts or {}
    local updater = self:getUpdater()
    local label = _("Check for updates")

    self:showBusy(_("Checking for plugin updates…"))
    self:runOnlineTask(label, function()
        local result = updater:check_for_update()
        self:closeBusy()

        if result.error and not result.download_url then
            logger.warn("update check failed:", result.error)
            self:showInfo(T(_("Update check failed:\n%1"), result.error))
            return
        end

        if not result.has_update then
            if opts.silent_up_to_date then
                logger.info("plugin up to date:", result.local_version)
                return
            end
            local text = T(
                _("WeRead plugin is up to date.\n\nCurrent: v%1\nRemote: v%2\nSource: %3"),
                result.local_version or "?",
                result.remote_version or "?",
                result.source or "?"
            )
            if result.can_force and result.download_url then
                UIManager:show(ConfirmBox:new{
                    text = text .. "\n\n" .. _("Reinstall the latest package from GitHub anyway?"),
                    ok_text = _("Reinstall"),
                    cancel_text = _("Close"),
                    ok_callback = self:safeCallback(_("Reinstall"), function()
                        self:performPluginUpdate(result, { force = true })
                    end),
                })
                return
            end
            self:showInfo(text)
            return
        end

        local notes = trim_notes(result.notes)
        local message = T(
            _("WeRead plugin update available!\n\nCurrent: v%1\nLatest: v%2\nSource: %3"),
            result.local_version or "?",
            result.remote_version or "?",
            result.source or "?"
        )
        if notes ~= "" then
            message = message .. "\n\n" .. T(_("Release notes:\n%1"), notes)
        end
        if result.release_fallback_reason then
            message = message .. "\n\n" .. T(
                _("Note: stable release lookup failed (%1); using branch package."),
                tostring(result.release_fallback_reason)
            )
        end

        UIManager:show(ConfirmBox:new{
            text = message,
            ok_text = _("Update now"),
            cancel_text = _("Later"),
            ok_callback = self:safeCallback(_("Update now"), function()
                self:performPluginUpdate(result)
            end),
        })
    end)
end

function trim_notes(text)
    if type(text) ~= "string" then
        return ""
    end
    text = text:gsub("\r\n", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > 600 then
        text = text:sub(1, 600) .. "..."
    end
    return text
end

function M:performPluginUpdate(check_result, opts)
    opts = opts or {}
    local updater = self:getUpdater()
    local label = _("Update plugin")

    self:showBusy(_("Downloading plugin update…"))
    self:runOnlineTask(label, function()
        local ok, info_or_err = updater:perform_update(check_result, opts)
        self:closeBusy()
        if not ok then
            logger.err("plugin update failed:", info_or_err)
            self:showInfo(T(_("Plugin update failed:\n%1"), tostring(info_or_err)))
            return
        end

        local version = info_or_err.version or check_result.remote_version or "?"
        local extracted = tonumber(info_or_err.extracted) or 0
        self:showInfo(T(
            _("WeRead plugin updated to v%1.\n%2 files installed.\n\nPlease restart KOReader to load the new version."),
            version,
            extracted
        ))
    end)
end

return M
