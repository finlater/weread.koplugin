-- Optional ZenUI Home widget. ZenUI navbar discovery uses WeReadPlugin:launch().

local logger = require("weread.lib.logger")
local _ = require("weread.lib.plugin_util").tr

local source = debug.getinfo(1, "S").source or ""
local integration_dir = source:sub(1, 1) == "@"
    and source:sub(2):match("^(.*)/[^/]+$") or nil
local icon_path = integration_dir
    and integration_dir:gsub("/integrations$", "") .. "/icons/weread-w-book.svg"
    or nil

local Integration = {
    name = "zenui",
    item_id = "weread.bookshelf",
    registered = false,
    plugin = nil,
}

function Integration:_livePlugin()
    local file_manager = package.loaded["apps/filemanager/filemanager"]
    local fm = file_manager and file_manager.instance
    if fm and type(fm.weread) == "table" then return fm.weread end
    return self.plugin
end

function Integration:_openBookshelf()
    local plugin = self:_livePlugin()
    if not plugin or type(plugin.openBookshelf) ~= "function" then return false end
    plugin:openBookshelf()
    return true
end

function Integration:_installIcon()
    if not icon_path then return false end
    local ok, result = pcall(function()
        local DataStorage = require("datastorage")
        local ffiutil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local icons_dir = DataStorage:getDataDir() .. "/icons"
        if lfs.attributes(icons_dir, "mode") ~= "directory"
            and not lfs.mkdir(icons_dir) then
            return false
        end
        return ffiutil.copyFile(icon_path,
            icons_dir .. "/weread-w-book.svg") == true
    end)
    return ok and result == true
end

function Integration:_buildWidget(ctx)
    local Blitbuffer = require("ffi/blitbuffer")
    local Device = require("device")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local IconWidget = require("ui/widget/iconwidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = Device.screen

    local width = math.max(1, tonumber(ctx and ctx.width) or Screen:getWidth())
    local height = math.max(1, tonumber(ctx and ctx.height)
        or Screen:scaleBySize(96))
    local label = TextWidget:new{
        text = _("WeRead"),
        face = Font:getFace("cfont", Screen:scaleBySize(18)),
        bold = true,
    }
    local gap = Screen:scaleBySize(5)
    local available_h = math.max(Screen:scaleBySize(20),
        height - label:getSize().h - gap)
    local icon_size = math.max(Screen:scaleBySize(20),
        math.min(math.floor(width * 0.18), math.floor(available_h * 0.72)))
    local content = VerticalGroup:new{
        align = "center",
        IconWidget:new{
            file = icon_path,
            width = icon_size,
            height = icon_size,
        },
        VerticalSpan:new{ width = gap },
        label,
    }
    local body = FrameContainer:new{
        width = width,
        height = height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            content,
        },
    }
    local tap = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        ges_events = {
            TapWeRead = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(), h = Screen:getHeight(),
                    },
                },
            },
            HoldWeRead = {
                GestureRange:new{
                    ges = "hold",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(), h = Screen:getHeight(),
                    },
                },
            },
        },
        body,
    }
    tap.onTapWeRead = function(tap_self, _arg, ges)
        if not (tap_self.dimen and ges and ges.pos
                and tap_self.dimen:contains(ges.pos)) then
            return false
        end
        if ctx and ctx.openTopMenu and ctx.openTopMenu(ges) then return true end
        return self:_openBookshelf()
    end
    tap.onHoldWeRead = function(tap_self, _arg, ges)
        if not (tap_self.dimen and ges and ges.pos
                and tap_self.dimen:contains(ges.pos)) then
            return false
        end
        if ctx and ctx.editMode and ctx.openWidgetSettings then
            return ctx.openWidgetSettings()
        end
        return false
    end
    return tap
end

function Integration:_tryRegister()
    if self.registered then return true end
    local register = rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")
    if type(register) ~= "function" then return false end
    self:_installIcon()
    local result = register(self.item_id, function(ctx)
        return self:_buildWidget(ctx)
    end, {
        label = _("WeRead"),
        size = {
            preferred_pct = 0.14,
            min_pct = 0.10,
            max_pct = 0.22,
        },
    })
    self.registered = result ~= false
    if self.registered then
        logger.info("weread: registered ZenUI bookshelf widget")
    end
    return self.registered
end

function Integration:register(plugin)
    self.plugin = plugin
    return self:_tryRegister()
end

function Integration:onZenUIReady(plugin)
    if plugin then self.plugin = plugin end
    return self:_tryRegister()
end

return Integration
