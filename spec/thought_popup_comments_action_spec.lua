-- "View comments" action: button gating, callback plumbing through the
-- pooled thought-popup entry, and the controller-side fetch flow contract.
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

local shown_widgets, closed_widgets = {}, {}
local dialog_args
package.preload["ui/bidi"] = function()
    return {
        flipIfMirroredUILayout = function(value) return value end,
        flipDirectionIfMirroredUILayout = function(value) return value end,
    }
end
package.preload["ui/widget/buttondialog"] = function()
    return {
        new = function(_, args)
            dialog_args = args
            return { is_action_dialog = true }
        end,
    }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 255 } end
package.preload["ui/widget/buttontable"] = function() return class() end
package.preload["ui/widget/container/centercontainer"] = function() return class() end
package.preload["ui/widget/container/bottomcontainer"] = function() return class() end
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
        hasClipboard = false,
    }
end
package.preload["ui/widget/container/framecontainer"] = function() return class() end
package.preload["ui/widget/linewidget"] = function() return class() end
package.preload["ui/font"] = function()
    return { getFace = function(name, size) return { name = name, size = size } end }
end
package.preload["ui/geometry"] = function() return class() end
package.preload["ui/gesturerange"] = function() return class() end
package.preload["ui/widget/container/inputcontainer"] = function() return class() end
package.preload["weread.ui.thought_popup.pages"] = function() return class() end
package.preload["weread.ui.thought_popup.page_viewport"] = function() return class() end
package.preload["weread.ui.thought_popup.paginator"] = function() return class() end
package.preload["ui/widget/verticalscrollbar"] = function() return class() end
package.preload["util"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...) return text:format(...) end,
    }
end
package.preload["ui/size"] = function()
    return {
        padding = { large = 8, default = 4 },
        line = { thick = 2 },
        radius = { window = 6 },
    }
end
package.preload["ui/widget/titlebar"] = function() return class() end
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function() end,
        show = function(_, widget) shown_widgets[#shown_widgets + 1] = widget end,
        close = function(_, widget) closed_widgets[#closed_widgets + 1] = widget end,
        isWidgetShown = function() return false end,
        scheduleIn = function() end,
    }
end
package.preload["ui/widget/verticalgroup"] = function() return class() end
package.preload["ui/widget/verticalspan"] = function() return class() end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { free = function() end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.ui.thought_popup.face_factory"] = function()
    return { init = function() end }
end

-- Fake bottom widget so ThoughtPopup.show can be exercised without UI.
local widget_new_args, widget_reopen_args
package.preload["weread.ui.thought_popup.widget"] = function()
    local Widget = {}
    Widget.__index = Widget
    function Widget:new(args)
        widget_new_args = args
        return setmetatable({}, Widget)
    end
    function Widget:_reopen(opts)
        widget_reopen_args = opts
    end
    function Widget:clear() end
    function Widget:_freeContentCaches() end
    return Widget
end

local CenterWidget = require("weread.ui.thought_popup.center_widget")
local ScrollContainer = require("weread.ui.thought_popup.scroll_container")
local ThoughtPopup = require("weread.ui.thought_popup")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

-- A thought with a reviewId gets a "View comments" row; the callback receives
-- the item and closes the dialog.
do
    local comments_item
    local popup = setmetatable({
        on_view_comments = function(item) comments_item = item end,
    }, { __index = CenterWidget })
    local item = { content = "thought", review_id = "rv-7" }
    popup:_showThoughtActionMenu(item)
    local rows = dialog_args.buttons
    eq(#rows, 2, "thought with review id shows a second action row")
    eq(rows[2][1].text, "View comments", "second row is the comment action")
    rows[2][1].callback()
    eq(comments_item, item, "comment action forwards the tapped item")
    eq(closed_widgets[#closed_widgets] and closed_widgets[#closed_widgets].is_action_dialog,
        true, "comment action closes the dialog first")
end

-- A thought without a reviewId (legacy rows) gets no comment action.
do
    local popup = setmetatable({}, { __index = CenterWidget })
    popup:_showThoughtActionMenu({ content = "thought" })
    eq(#dialog_args.buttons, 1, "legacy thought keeps copy/qr actions only")
end

-- The popup entry forwards on_view_comments to both the widget constructor
-- and the pooled reopen path.
do
    local first_callback = function() end
    ThoughtPopup.show{
        pages = { { content = "thought" } },
        position = "bottom",
        on_view_comments = first_callback,
    }
    eq(widget_new_args and widget_new_args.on_view_comments, first_callback,
        "constructor receives the comment callback")

    local second_callback = function() end
    ThoughtPopup.show{
        pages = { { content = "thought" } },
        position = "bottom",
        on_view_comments = second_callback,
    }
    eq(widget_reopen_args and widget_reopen_args.on_view_comments, second_callback,
        "pooled reopen receives the fresh comment callback")
end

-- Center popup thirds: with comment_tap_open the middle zone opens the
-- comments of the thought under the tap; left/right thirds still flip pages.
do
    local comments_item
    local function build_center(comment_tap_open)
        return setmetatable({
            page_index = 1,
            tap_to_page = true,
            comment_tap_open = comment_tap_open,
            container = { dimen = { x = 0, y = 0, w = 600, h = 500 } },
            _viewport = { dimen = { x = 0, y = 50, w = 600, h = 380 } },
            _page_starts = { 0, 300 },
            _pages = { layout = { pieces = {
                { variant = "meta", y = 10, piece_h = 20 },
                { variant = "meta", y = 320, piece_h = 20 },
            } } },
            items = { { review_id = "rv-1" }, { review_id = "rv-2" } },
            on_view_comments = function(item) comments_item = item end,
            _syncButtons = function() end,
        }, { __index = CenterWidget })
    end
    local function tap_at(x, y)
        return { pos = setmetatable({ x = x, y = y }, {
            __index = {
                intersectWith = function() return true end,
                notIntersectWith = function() return false end,
            },
        }) }
    end

    local popup = build_center(true)
    popup:onTapClose(nil, tap_at(300, 70))
    eq(comments_item, popup.items[1], "middle tap opens the comments of the tapped thought")
    eq(popup.page_index, 1, "middle tap does not flip pages")

    popup:onTapClose(nil, tap_at(500, 70))
    eq(popup.page_index, 2, "right third flips forward")
    popup:onTapClose(nil, tap_at(100, 70))
    eq(popup.page_index, 1, "left third flips back")

    comments_item = nil
    popup:onTapClose(nil, tap_at(300, 100))
    eq(comments_item, nil, "middle tap over blank space does nothing")

    popup.items[2].review_id = nil
    popup:onTapClose(nil, tap_at(500, 70))
    comments_item = nil
    popup:onTapClose(nil, tap_at(300, 80))
    eq(comments_item, nil, "thought without review id does not open comments")

    popup = build_center(false)
    popup:onTapClose(nil, tap_at(300, 70))
    eq(comments_item, nil, "disabled middle zone never opens comments")
    eq(popup.page_index, 2, "without the setting the middle keeps the half-page behavior")
end

-- Bottom popup scroll container: thirds with a center handler, halves without.
do
    local flips, center_ges = {}, nil
    local function tap(x) return { pos = { x = x, y = 10 } } end

    local scroll = setmetatable({
        dimen = { x = 0, y = 0, w = 600, h = 380 },
        on_tap_center = function(ges) center_ges = ges end,
        scrollToPage = function(_, delta) flips[#flips + 1] = delta end,
    }, { __index = ScrollContainer })
    scroll:onTapScrollText(nil, tap(100))
    scroll:onTapScrollText(nil, tap(300))
    scroll:onTapScrollText(nil, tap(500))
    eq(flips[1], -1, "scroll container left third pages back")
    eq(#flips, 2, "scroll container middle zone defers to the handler")
    eq(flips[2], 1, "scroll container right third pages forward")
    eq(center_ges and center_ges.pos.x, 300, "middle tap reaches the center handler")

    flips = {}
    local plain = setmetatable({
        dimen = { x = 0, y = 0, w = 600, h = 380 },
        scrollToPage = function(_, delta) flips[#flips + 1] = delta end,
    }, { __index = ScrollContainer })
    plain:onTapScrollText(nil, tap(100))
    plain:onTapScrollText(nil, tap(300))
    eq(flips[1], -1, "plain halves: left half pages back")
    eq(flips[2], 1, "plain halves: right half pages forward")
end

print(string.format("thought_popup_comments_action_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
