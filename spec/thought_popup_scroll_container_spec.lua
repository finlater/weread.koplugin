-- Unit tests for hardware-key bindings in the bottom thought popup.
-- Run from the repo root with:
--   luajit spec/thought_popup_scroll_container_spec.lua

package.path = "./?.lua;" .. package.path

local function class(proto)
    proto = proto or {}
    proto.__index = proto

    function proto:extend(child)
        child = child or {}
        child.__index = child
        setmetatable(child, { __index = self })
        return child
    end

    function proto:new(opts)
        opts = opts or {}
        setmetatable(opts, { __index = self })
        if opts.init then opts:init() end
        return opts
    end

    return proto
end

package.preload["device"] = function()
    return {
        input = {
            group = {
                PgBack = "hardware-page-back",
                PgFwd = "hardware-page-forward",
            },
        },
        screen = {
            getWidth = function() return 600 end,
            scaleBySize = function(_, value) return value end,
        },
        hasKeys = function() return true end,
        isTouchDevice = function() return false end,
    }
end

package.preload["ui/bidi"] = function()
    return { flipIfMirroredUILayout = function(value) return value end }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/gesturerange"] = function()
    return class()
end
package.preload["ui/widget/container/inputcontainer"] = function()
    return class()
end
package.preload["weread.ui.thought_popup.paginator"] = function()
    return { computePages = function() return { 0 } end }
end
package.preload["util"] = function()
    return {
        bsearch_left = function() return 1 end,
        bsearch_right = function() return 2 end,
    }
end
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["ui/widget/verticalscrollbar"] = function()
    local ScrollBar = class()
    function ScrollBar:set(low, high)
        self.low, self.high = low, high
    end
    return ScrollBar
end

local ScrollContainer = require("weread.ui.thought_popup.scroll_container")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

local scroll = ScrollContainer:new{
    content_h = 100,
    viewport_h = 50,
}

eq(scroll.key_events.ScrollUp[1][1], "hardware-page-back",
    "PgBack is bound to the previous-page event")
eq(scroll.key_events.ScrollDown[1][1], "hardware-page-forward",
    "PgFwd is bound to the next-page event")

print(string.format("thought_popup_scroll_container_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
