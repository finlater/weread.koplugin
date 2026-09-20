-- Automatic reader status prompts must not consume the reader's first input:
-- they are shown as non-modal Notifications, never as modal InfoMessages.

package.path = "./?.lua;" .. package.path

local shown, infomessages = {}, 0
package.preload["ui/uimanager"] = function()
    return { show = function() end }
end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_self, args)
        infomessages = infomessages + 1
        return args
    end }
end
package.preload["ui/widget/notification"] = function()
    return { new = function(_self, args)
        shown[#shown + 1] = args
        return args
    end }
end
package.preload["ffi/util"] = function()
    return { template = function(text, ...)
        local values = { ... }
        return (text:gsub("%%(%d+)", function(index)
            return tostring(values[tonumber(index)])
        end))
    end }
end

local Dialog = require("weread.ui.progress_sync_dialog")

assert(Dialog.show_status("checking_progress") == true,
    "the automatic open check did not report success")
assert(Dialog.show_status("uploading_on_close") == true,
    "the automatic close upload did not report success")
assert(Dialog.show_status("unknown") == false,
    "an unknown status code must not show anything")
assert(#shown == 2 and infomessages == 0,
    "automatic status prompts must use the non-modal Notification widget")
assert(shown[1].timeout == 1.5 and shown[2].timeout == 2,
    "automatic status prompts lost their timeouts")

local tr = require("weread.lib.i18n").tr
assert(shown[1].text == tr("Checking WeRead progress…")
        and shown[2].text == tr("Syncing reading progress…"),
    "automatic status prompts lost their translated text")

print("progress_sync_dialog_spec: non-modal status prompts passed")
