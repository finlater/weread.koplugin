--[[--
Centered thought popup widget (TextViewer style).

Renders the same paginated review content as the bottom popup (shared
PageRenderer) inside a centered, rounded white window with a title bar and an
explicit Previous/Next page button row, mirroring KOReader's TextViewer look
(the style of the original thought dialog on this branch).

Long content — including a single long thought — flows across multiple pages;
there is no scrolling: navigation is page-index based (buttons, horizontal
swipes inside the window, or PgBack/PgFwd). Font sizes, margins and the
height ratio are the same settings the bottom popup uses.
--]]

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local PageRenderer = require("weread.ui.thought_popup.pages")
local PageViewport = require("weread.ui.thought_popup.page_viewport")
local PluginUtil = require("weread.lib.plugin_util")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Screen = Device.screen
local _ = PluginUtil.tr

local PADDING_TOP = Size.padding.large
local PADDING_BOTTOM = Size.padding.large
local BUTTON_PADDING = Size.padding.default

local CenterThoughtPopupWidget = InputContainer:extend{
    items = nil,
    doc_font_name = nil,
    doc_font_size = Screen:scaleBySize(18),
    doc_margins = {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = 0.70,
    width_ratio = 0.8,
    contrast = 9,
    tap_to_page = true,
    close_callback = nil,
    dialog = nil,
    page_index = 1,

    _pages = nil,
    _page_starts = nil,
    _titlebar = nil,
    _button_table = nil,
    _viewport = nil,
    container = nil,
}

function CenterThoughtPopupWidget:init()
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.70))
    self.width_ratio = math.max(0.4, math.min(1.0, self.width_ratio or 0.8))
    self.width = math.floor(Screen:getWidth() * self.width_ratio)
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                }
            },
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                }
            },
            HoldThought = {
                GestureRange:new{
                    ges = "hold",
                    range = range,
                }
            },
        }
    end

    if Device:hasKeys() then
        local group = Device.input.group
        self.key_events = {}
        if group.Back then self.key_events.Close = { { group.Back } } end
        local previous = group.PgBack or group.PageBack or group.PageBackward or group.Left
        local following = group.PgFwd or group.PageForward or group.PageNext or group.Right
        if previous then self.key_events.PageBack = { { previous } } end
        if following then self.key_events.PageFwd = { { following } } end
    end

    self._pages = PageRenderer:new{
        items = self.items,
        doc_font_name = self.doc_font_name,
        doc_font_size = self.doc_font_size,
        doc_margins = self.doc_margins,
        height_ratio = self.height_ratio,
        content_width = self.width,
        contrast = self.contrast,
        skip_quote = true,
    }
    self:_buildLayout()
end

function CenterThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
end

function CenterThoughtPopupWidget:_reopen(opts)
    self.items = opts.items or {}
    if opts.doc_font_name then self.doc_font_name = opts.doc_font_name end
    if opts.doc_font_size then self.doc_font_size = opts.doc_font_size end
    if opts.doc_margins then self.doc_margins = opts.doc_margins end
    if opts.height_ratio then self.height_ratio = opts.height_ratio end
    if opts.width_ratio then self.width_ratio = opts.width_ratio end
    if opts.contrast ~= nil then self.contrast = opts.contrast end
    if opts.tap_to_page ~= nil then self.tap_to_page = opts.tap_to_page end
    if opts.dialog then self.dialog = opts.dialog end
    self.close_callback = opts.close_callback
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.70))
    self.width_ratio = math.max(0.4, math.min(1.0, self.width_ratio or 0.8))
    self.width = math.floor(Screen:getWidth() * self.width_ratio)
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.width, self.contrast)
    self:_buildLayout()
end

--- Window title: the quoted abstract of the first review item (whitespace
--- collapsed, overflow truncated by TitleBar), or "Thoughts" when absent.
function CenterThoughtPopupWidget:_title()
    local abstract = self.items and self.items[1] and self.items[1].abstract
    if type(abstract) == "string" and abstract ~= "" then
        return abstract:gsub("%s+", " ")
    end
    return _("Thoughts")
end

--- Previous / page indicator / Next button row.
function CenterThoughtPopupWidget:_buildButtons()
    local popup = self
    return {
        {
            text = "‹ " .. _("Previous"),
            id = "prev_page",
            vsync = true,
            callback = function()
                popup:changePage(-1)
            end,
        },
        {
            text = "1 / 1",
            id = "page_position",
            callback = function() end,
        },
        {
            text = _("Next") .. " ›",
            id = "next_page",
            vsync = true,
            callback = function()
                popup:changePage(1)
            end,
        },
    }
end

function CenterThoughtPopupWidget:_buildLayout()
    self:clear()
    self.page_index = 1

    local renderer = self._pages
    renderer:ensureLayout()

    self._titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = self:_title(),
        title_multilines = true,
        title_face = Font:getFace("x_smalltfont", 18),
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    local text_w = renderer.text_w

    self._button_table = ButtonTable:new{
        width = self.width - 2 * BUTTON_PADDING,
        buttons = { self:_buildButtons() },
        zero_sep = true,
        show_parent = self,
    }

    local chrome = self._titlebar:getHeight()
        + self._button_table:getSize().h
        + PADDING_TOP + PADDING_BOTTOM
    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(18)) * 1.2)

    local viewport_h
    if renderer.content_h + chrome <= ratio_h - blank_tolerance then
        viewport_h = renderer.content_h
        self.height = renderer.content_h + chrome
    else
        viewport_h = ratio_h - chrome
        self.height = ratio_h
    end
    if viewport_h < 1 then viewport_h = 1 end

    self._page_starts = renderer:computePages(viewport_h)
    local page_count = #self._page_starts
    self.page_index = math.min(self.page_index, page_count)

    self._viewport = PageViewport:new{
        dimen = Geom:new{ w = self.width, h = viewport_h },
        page_index_getter = function()
            return self.page_index
        end,
        margin_left = self.doc_margins.left,
        text_w = text_w,
        page_bb_getter = function(page_idx)
            return renderer:renderPage(page_idx, self._page_starts)
        end,
    }

    local frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self._titlebar,
            VerticalSpan:new{ width = PADDING_TOP },
            self._viewport,
            VerticalSpan:new{ width = PADDING_BOTTOM },
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = self._button_table:getSize().h,
                },
                self._button_table,
            },
        },
    }
    self.container = frame
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        frame,
    }
    self:_syncButtons()
end

--- Flip to an adjacent page; clamps at the first/last page.
function CenterThoughtPopupWidget:changePage(delta)
    local total = self._page_starts and #self._page_starts or 0
    if total < 1 then return end
    local next_index = math.min(total, math.max(1, self.page_index + delta))
    if next_index == self.page_index then return end
    self.page_index = next_index
    self:_syncButtons()
    UIManager:setDirty(self, "partial", self.container.dimen)
end

--- Keep the Previous/Next enabled states and the N / M indicator current.
function CenterThoughtPopupWidget:_syncButtons()
    local bt = self._button_table
    if not bt or not bt.getButtonById then return end
    local total = self._page_starts and #self._page_starts or 0
    local prev_btn = bt:getButtonById("prev_page")
    local next_btn = bt:getButtonById("next_page")
    local position_btn = bt:getButtonById("page_position")
    if prev_btn and prev_btn.enableDisable then
        prev_btn:enableDisable(self.page_index > 1)
    end
    if next_btn and next_btn.enableDisable then
        next_btn:enableDisable(self.page_index < total)
    end
    if position_btn and position_btn.setText then
        position_btn:setText(
            tostring(self.page_index) .. " / " .. tostring(total),
            position_btn.width)
    end
end

function CenterThoughtPopupWidget:onCloseWidget()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback(self.height)
    end
end

function CenterThoughtPopupWidget:onClose()
    UIManager:close(self)
    return true
end

function CenterThoughtPopupWidget:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.container.dimen) then
        UIManager:close(self)
        return true
    end
    -- Optional tap-to-page: left/right half of the window flips pages.
    if self.tap_to_page then
        local dimen = self.container.dimen
        if BD.flipIfMirroredUILayout(ges.pos.x < dimen.x + dimen.w / 2) then
            self:changePage(-1)
        else
            self:changePage(1)
        end
    end
    return true
end

function CenterThoughtPopupWidget:onSwipe(_, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if ges.pos:intersectWith(self.container.dimen) then
        -- Swipe inside the window flips pages (west = next, east = previous).
        if direction == "west" then
            self:changePage(1)
        elseif direction == "east" then
            self:changePage(-1)
        end
        return true
    end
    -- Swipe outside the window: west/east close it (like the bottom popup).
    if direction == "west" or direction == "east" then
        UIManager:close(self)
        return true
    end
    return false
end

function CenterThoughtPopupWidget:onPageBack()
    self:changePage(-1)
    return true
end

function CenterThoughtPopupWidget:onPageFwd()
    self:changePage(1)
    return true
end

function CenterThoughtPopupWidget:onHoldThought(_, ges)
    local viewport = self._viewport
    if viewport and viewport.dimen and ges.pos:intersectWith(viewport.dimen) then
        local content_y = (ges.pos.y - viewport.dimen.y) + (self._page_starts[self.page_index] or 0)
        local item = self:_findItemAtContentY(content_y)
        if item then
            self:_showThoughtActionMenu(item)
        end
    end
    return true
end

function CenterThoughtPopupWidget:_findItemAtContentY(y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    local item_idx = 0
    for _, piece in ipairs(pieces) do
        if piece.variant == "meta" then
            item_idx = item_idx + 1
        end
        if piece.y and piece.piece_h and piece.y <= y and y < piece.y + piece.piece_h then
            if piece.variant == "quote" then
                return self.items and self.items[1]
            end
            if item_idx >= 1 and self.items and item_idx <= #self.items then
                return self.items[item_idx]
            end
            return nil
        end
    end
    return nil
end

function CenterThoughtPopupWidget:_showThoughtActionMenu(item)
    local popup = self
    local action_dialog
    action_dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("Copy"),
                    callback = function()
                        UIManager:close(action_dialog)
                        popup:_copyThoughtContent(item)
                    end,
                },
                {
                    text = _("Generate QR code"),
                    callback = function()
                        UIManager:close(action_dialog)
                        popup:_generateQRCode(item)
                    end,
                },
            },
        },
    }
    UIManager:show(action_dialog)
end

function CenterThoughtPopupWidget:_copyThoughtContent(item)
    local text = tostring(item and item.content or "")
    if text == "" then return end
    if Device.hasClipboard and Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
end

function CenterThoughtPopupWidget:_generateQRCode(item)
    local text = tostring(item and item.content or "")
    if text == "" then return end
    if Device.hasClipboard and Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
    local QRMessage = require("ui/widget/qrmessage")
    UIManager:show(QRMessage:new{
        text = text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    })
end

function CenterThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function CenterThoughtPopupWidget:_freeContentCaches()
    self._pages:freeContentCaches()
end

return CenterThoughtPopupWidget
