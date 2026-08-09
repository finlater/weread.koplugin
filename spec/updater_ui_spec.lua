package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, value) return value end }
end
local shown_widget
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown_widget = widget end,
        close = function() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end
package.preload["weread.ui.download_dialog"] = function()
    return { new = function(_, value) return value end }
end
package.preload["weread.lib.logger"] = function()
    return { warn = function() end, err = function() end }
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

local UpdaterUI = require("weread.ui.updater")
local core = {
    current_version = "0.6.0",
    compare_versions = function(left, right)
        if left == right then return 0 end
        return left > right and 1 or -1
    end,
    has_update = function() return true end,
    available_version = function() return "0.7.0" end,
}
local ui = UpdaterUI:new{
    updater = core,
    settings = { data_dir = "/tmp" },
}

expect(ui:has_update(), "UI did not delegate update state")
expect(ui:available_version() == "0.7.0",
    "UI did not delegate available version")

local download_title = ui:_progress_title{
    stage = "downloading",
    current = 512 * 1024,
    total = 1024 * 1024,
}
expect(download_title:find("50%%") ~= nil,
    "download title did not show the real percentage")
expect(download_title:find("512 KB", 1, true) ~= nil
    and download_title:find("1.0 MB", 1, true) ~= nil,
    "download title did not show transferred bytes")
expect(ui:_progress_title{ stage = "verifying" }
    == "Verifying update package…", "verification stage title was wrong")
expect(ui:_progress_title{ stage = "extracting" }
    == "Extracting update package…", "extraction stage title was wrong")
expect(ui:_progress_title{ stage = "installing" }
    == "Installing update…", "installation stage title was wrong")

ui:_show_release{
    version = "0.7.0",
    notes = "First change\nSecond change",
}
expect(shown_widget.title == "v0.6.0 -> v0.7.0",
    "release notes viewer title was wrong")
expect(shown_widget.text == "First change\nSecond change"
    and shown_widget.buttons_table[1][2].text == "Download and install",
    "release notes viewer did not expose notes and install action")

print(("updater_ui_spec: %d checks"):format(checks))
