-- Verify precise progress text and usable choice callbacks without a renderer.
package.path = "./?.lua;" .. package.path
local shown
for _, module in ipairs({ "ui/widget/confirmbox", "ui/widget/infomessage" }) do
    package.preload[module] = function()
        return { new = function(_self, options) return options end }
    end
end
package.preload["ui/uimanager"] = function()
    return { show = function(_self, widget) shown = widget end }
end
package.preload["ffi/util"] = function()
    return { template = function(text, ...)
        local args = { ... }
        return (text:gsub("%%(%d+)", function(index) return tostring(args[tonumber(index)]) end))
    end }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
local Dialog = require("weread.ui.progress_sync_dialog")
local selected = false
Dialog.show_choice{
    book_title = "Book",
    local_position = { percent = 1, fraction = 0.01675761, chapter_title = "Chapter six" },
    remote_position = { percent = 3.401893, chapter_title = "Chapter six" },
    use_remote = function() selected = true end,
}
assert(shown.text:find("1.7%", 1, true), "local progress lost its fractional precision")
assert(shown.text:find("3.4%", 1, true), "remote precision is displayed")
assert(shown.text:find("Chapter six", 1, true), "chapter title is displayed")
assert(not shown.text:find("%1", 1, true), "unexpanded placeholder")
shown.ok_callback()
assert(selected, "cloud choice callback is preserved")
Dialog.notify("upload_success", { position = { percent = 1, fraction = 0.01675761 } })
assert(shown.text == "Progress uploaded to WeRead: 1.7%", "uploaded percent formatting")
Dialog.notify("remote_applied", { position = { percent = 3.401893 } })
assert(shown.text == "Jumped to WeRead progress: 3.4%", "jumped percent formatting")
print("progress_sync_dialog_spec: 7 checks passed")
