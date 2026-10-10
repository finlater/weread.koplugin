local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
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

-- One decimal, with the percent sign added here. Putting "%" immediately
-- after %1 in a KOReader template is parsed as part of the placeholder, so
-- the dialog shows the raw "%1" and "%2".
local function place(position)
    local value = string.format("%.1f%%", tonumber(position and position.percent) or 0)
    local chapter = position and position.chapter_title or ""
    if chapter ~= "" then
        return value .. "\n" .. chapter
    end
    return value
end

function ProgressSyncDialog.show_choice(context)
    local title = tostring(context.book_title or "")
    local message
    if context.source_conflict then
        message = T(_("WeRead's two progress sources disagree for \"%1\"."), title)
            .. "\n\n" .. "KOReader\n" .. place(context.local_position)
            .. "\n\n" .. _("Selected cloud position") .. "\n" .. place(context.remote_position)
    else
        message = T(_("Reading progress differs for \"%1\"."), title)
            .. "\n\n" .. "KOReader\n" .. place(context.local_position)
            .. "\n\n" .. _("WeRead") .. "\n" .. place(context.remote_position)
    end
    message = message .. "\n\n" .. _("Choose which position to keep.")

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

return ProgressSyncDialog
