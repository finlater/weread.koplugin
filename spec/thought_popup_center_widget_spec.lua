-- Thought-popup navigation and long-press lookup in both popup positions.
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
    return proto
end

local dirty_target, dirty_mode, dirty_region
package.preload["ui/bidi"] = function()
    return {
        flipIfMirroredUILayout = function(value) return value end,
        flipDirectionIfMirroredUILayout = function(value) return value end,
    }
end
package.preload["ui/widget/buttondialog"] = function() return class() end
package.preload["ui/widget/container/bottomcontainer"] = function() return class() end
package.preload["ui/widget/linewidget"] = function() return class() end
package.preload["weread.ui.thought_popup.scroll_container"] = function() return class() end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 255 } end
package.preload["ui/widget/buttontable"] = function() return class() end
package.preload["ui/widget/container/centercontainer"] = function() return class() end
package.preload["device"] = function()
    return {
        input = { group = {} },
        screen = {
            scaleBySize = function(_, value) return value end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getSize = function() return { w = 600, h = 800 } end,
        },
        isTouchDevice = function() return false end,
        hasKeys = function() return false end,
    }
end
package.preload["ui/widget/container/framecontainer"] = function() return class() end
package.preload["ui/font"] = function()
    return { getFace = function(name, size) return { name = name, size = size } end }
end
package.preload["ui/geometry"] = function() return class() end
package.preload["ui/gesturerange"] = function() return class() end
package.preload["ui/widget/container/inputcontainer"] = function() return class() end
package.preload["weread.ui.thought_popup.pages"] = function() return {} end
package.preload["weread.ui.thought_popup.page_viewport"] = function() return class() end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end
package.preload["ui/size"] = function()
    return {
        padding = { large = 8, default = 4 },
        radius = { window = 6 },
        line = { thick = 2 },
    }
end
package.preload["ui/widget/titlebar"] = function() return class() end
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_self, target, mode, region)
            dirty_target, dirty_mode, dirty_region = target, mode, region
        end,
    }
end
package.preload["ui/widget/verticalgroup"] = function() return class() end
package.preload["ui/widget/verticalspan"] = function() return class() end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { free = function() end }
end

local CenterWidget = require("weread.ui.thought_popup.center_widget")
local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

local popup = setmetatable({
    page_index = 1,
    _page_starts = { 0, 300 },
    container = { dimen = { x = 10, y = 20, w = 400, h = 500 } },
    _syncButtons = function() end,
}, { __index = CenterWidget })

local buttons = popup:_buildButtons()
eq(buttons[1].vsync, true, "previous button uses synchronized feedback")
eq(buttons[3].vsync, true, "next button uses synchronized feedback")

popup:changePage(1)
eq(popup.page_index, 2, "next page updates the page index")
eq(dirty_target, popup, "page navigation redraws the popup itself")
eq(dirty_mode, "partial", "page navigation requests a partial refresh")
eq(dirty_region, popup.container.dimen, "page navigation refreshes the popup region")

for _, widget in ipairs({ CenterWidget, require("weread.ui.thought_popup.widget") }) do
    local first, second = { content = "first thought" }, { content = "second thought" }
    local view = setmetatable({
        items = { first, second },
        _pages = { layout = { pieces = {
            { kind = "text", variant = "meta", y = 0, piece_h = 20 },
            { kind = "text", variant = "likes", y = 2, piece_h = 20 },
            { kind = "text", variant = "content", y = 28, piece_h = 40 },
            { kind = "separator", y = 80, piece_h = 1 },
            { kind = "text", variant = "meta", y = 93, piece_h = 20 },
            { kind = "text", variant = "likes", y = 95, piece_h = 20 },
            { kind = "text", variant = "content", y = 121, piece_h = 40 },
        } } },
    }, { __index = widget })
    eq(view:_findItemAtContentY(21), first, "likes retain the first thought")
    eq(view:_findItemAtContentY(40), first, "first body keeps its action target")
    eq(view:_findItemAtContentY(80), nil, "separator does not copy the previous thought")
    eq(view:_findItemAtContentY(114), second, "likes retain the second thought")
    eq(view:_findItemAtContentY(130), second, "second body keeps its action target")
    if widget == CenterWidget then
        view.page_index = 2
        view._page_starts = { 0, 68, 161 }
        view._viewport = { dimen = { y = 200 } }
        view._pages.getPageContentStart = function() return 93 end
        local selected
        view._showThoughtActionMenu = function(_, item) selected = item end
        local function hold(y)
            selected = nil
            view:onHoldThought(nil, { pos = {
                y = 200 + y, intersectWith = function() return true end,
            } })
            return selected
        end
        eq(hold(1), second, "long press follows the author after removing page-top spacing")
        eq(hold(30), second, "long press follows the shifted body")
        view._findItemAtContentY = function() return first end
        eq(hold(70), nil, "blank area below a short page cannot select another page's thought")
    end
end

print(string.format("thought_popup_center_widget_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
