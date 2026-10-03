local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local I18n = require("weread.lib.i18n")

local ProgressSyncDialog = {}

local function _(text)
    return I18n.tr(text)
end

local function percent(position)
    return string.format("%.0f", tonumber(position and position.percent) or 0)
end

function ProgressSyncDialog.show_choice(context)
    local message
    if context.source_conflict then
        message = T(_(
            "WeRead's two progress sources disagree for \"%1\".\n\n"
            .. "KOReader: %2%\nSelected cloud position: %3%\n\n"
            .. "Choose which position to keep."
        ), context.book_title, percent(context.local_position),
            percent(context.remote_position))
    else
        message = T(_(
            "Reading progress differs for \"%1\".\n\n"
            .. "KOReader: %2%\nWeRead: %3%\n\n"
            .. "Choose which position to keep."
        ), context.book_title, percent(context.local_position),
            percent(context.remote_position))
    end

    UIManager:show(ConfirmBox:new{
        title = _("Reading progress sync"),
        text = message,
        ok_text = _("Use WeRead progress"),
        cancel_text = _("Keep KOReader progress"),
        ok_callback = context.use_remote,
        cancel_callback = context.keep_local,
    })
end

function ProgressSyncDialog.notify(code, data)
    data = data or {}
    local text
    if code == "upload_success" then
        text = T(_("Progress uploaded to WeRead: %1%"),
            percent(data.position))
    elseif code == "upload_failed" then
        text = T(_("Progress upload failed:\n%1"), tostring(data.error or ""))
    elseif code == "already_synced" then
        text = _("KOReader and WeRead are already at the same position.")
    elseif code == "remote_applied" then
        text = T(_("Jumped to WeRead progress: %1%"),
            percent(data.position))
    elseif code == "local_kept" then
        text = _("Kept the current KOReader position.")
    elseif code == "pull_failed" then
        text = T(_("Could not fetch WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "jump_failed" then
        text = T(_("Could not jump to WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "local_unavailable" then
        text = T(_("Could not determine the current reading position:\n%1"),
            tostring(data.error or ""))
    elseif code == "authentication_required" then
        text = _("Please scan the QR code to log in first.")
    elseif code == "offline" then
        text = _("No network connection. Please connect Wi-Fi and try again.")
    else
        return
    end
    UIManager:show(InfoMessage:new{ text = text })
end

function ProgressSyncDialog.show_status(code)
    local text
    local timeout
    if code == "checking_progress" then
        text = _("Checking WeRead progress…")
        timeout = 1.5
    elseif code == "uploading_on_close" then
        text = _("Syncing reading progress…")
        timeout = 2
    else
        return false
    end
    UIManager:show(Notification:new{ text = text, timeout = timeout })
    return true
end

return ProgressSyncDialog
