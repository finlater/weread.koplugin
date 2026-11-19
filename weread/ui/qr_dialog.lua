--[[--
Modal QR code popup with an explicit size.

KOReader's QRMessage sizes itself to the screen minus its title bar, and its
sizing differs between versions, so the login QR is drawn with QRWidget at a
size this plugin controls. Tapping anywhere or pressing Back closes it.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local PluginUtil = require("weread.lib.plugin_util")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")

local Screen = Device.screen
local _ = PluginUtil.tr

local QRDialog = InputContainer:extend{
    modal = true,
    stop_events_propagation = true,
    text = nil,
    size_ratio = 0.9, -- QR side as a fraction of the shorter screen side
    dismiss_callback = nil,
}

function QRDialog:init()
    local screen_size = Screen:getSize()
    local side = math.floor(math.min(screen_size.w, screen_size.h) * self.size_ratio)
    local qr = QRWidget:new{
        text = self.text,
        width = side,
        height = side,
        scale_factor = 1, -- QRWidget already fits whole modules into side x side
    }
    local content = qr
    if not qr.image then
        content = TextWidget:new{
            text = _("Could not generate a QR code"),
            face = Font:getFace("infofont"),
            max_width = side,
        }
    end
    self.qr = qr
    self[1] = CenterContainer:new{
        dimen = screen_size,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            content,
        },
    }
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = screen_size.w, h = screen_size.h },
            },
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

function QRDialog:onTapClose()
    UIManager:close(self)
    return true
end

function QRDialog:onClose()
    UIManager:close(self)
    return true
end

function QRDialog:onCloseWidget()
    UIManager:setDirty(nil, "ui")
    if self.qr and self.qr.free then
        self.qr:free()
    end
    if self.dismiss_callback then
        self.dismiss_callback()
        self.dismiss_callback = nil
    end
end

return QRDialog
