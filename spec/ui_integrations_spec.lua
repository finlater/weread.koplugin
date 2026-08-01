-- Focused tests for optional SimpleUI/ZenUI launch integration.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

_G.__ZEN_UI_REGISTER_HOME_ITEM = nil
local ZenUI = require("integrations.zenui")
ZenUI.registered = false

local opened = 0
local plugin = {
    openBookshelf = function() opened = opened + 1 end,
}
expect(ZenUI:register(plugin) == false,
    "ZenUI integration should remain optional when ZenUI is absent")

local registered_id, registered_builder, registered_options
_G.__ZEN_UI_REGISTER_HOME_ITEM = function(id, builder, options)
    registered_id = id
    registered_builder = builder
    registered_options = options
    return true
end

expect(ZenUI:onZenUIReady(plugin) == true,
    "ZenUIReady did not register the WeRead Home widget")
expect(registered_id == "weread.bookshelf"
    and type(registered_builder) == "function",
    "ZenUI registration used the wrong item descriptor")
expect(registered_options.label == "WeRead",
    "ZenUI registration used the wrong label")
expect(ZenUI:_openBookshelf() == true and opened == 1,
    "ZenUI entry did not call the stable bookshelf method")

_G.__ZEN_UI_REGISTER_HOME_ITEM = nil
print(("ui_integrations_spec: %d checks"):format(checks))
