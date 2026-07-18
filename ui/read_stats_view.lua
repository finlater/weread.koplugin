-- ui/read_stats_view.lua — WeRead reading statistics visualization page.
--
-- Pure presentation layer: given a normalized stats table (see lib/read_stats.lua)
-- and callbacks, it builds a full-screen, card-based, e-ink-friendly page that
-- adapts to any screen width. It performs no network I/O.
--
-- Sizing model (the key to avoiding overflow): `content_width` is the single
-- authoritative inner width. FrameContainer:getSize() ignores its `width` field
-- (that only affects the painted border), so we never rely on it to clamp
-- content; instead every child is constrained to <= content_width, and each card
-- is pinned to exactly content_width with a zero-height spacer.
--
-- Layout:
--   [TitleBar: mode · period, close]
--   [Tab bar: 周 / 月 / 年 / 总]
--   [ScrollableContainer]
--     ├─ Overview card (total time / days / average / compare / rank / summary)
--     ├─ Trend card (bar chart with a value axis)
--     ├─ Ranking card (most-read books)
--     └─ Preference card (categories / time / authors / publishers)
--   [Nav row: ‹ previous | next ›]   (hidden for "overall")

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local I18n = require("lib.i18n")
local T = require("ffi/util").template

local function _(text)
    return I18n.tr(text)
end

-- Long titles shown in the title bar.
local MODE_TITLE = {
    weekly = "This week",
    monthly = "This month",
    annually = "This year",
    overall = "Overall",
}

-- Short labels + order for the tab bar.
local TABS = {
    { mode = "weekly", text = "Week" },
    { mode = "monthly", text = "Month" },
    { mode = "annually", text = "Year" },
    { mode = "overall", text = "Total" },
}

-- ---------------------------------------------------------------------------
-- Formatting helpers (localized, view-only)
-- ---------------------------------------------------------------------------

local function format_duration(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 60 then
        return _("< 1 min")
    end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 and m > 0 then
        return T(_("%1 h %2 min"), h, m)
    elseif h > 0 then
        return T(_("%1 h"), h)
    end
    return T(_("%1 min"), m)
end

-- Compact form for the chart value axis ("3.2h" / "45m" / "0").
local function format_duration_axis(seconds)
    seconds = tonumber(seconds) or 0
    if seconds >= 3600 then
        return string.format("%gh", math.floor(seconds / 360 + 0.5) / 10)
    elseif seconds >= 60 then
        return string.format("%dm", math.floor(seconds / 60 + 0.5))
    elseif seconds > 0 then
        return "<1m"
    end
    return "0"
end

local function format_compare(compare)
    if type(compare) ~= "number" or compare == 0 then
        return nil
    end
    local pct = math.floor(math.abs(compare) * 100 + 0.5)
    if pct == 0 then
        return nil
    end
    if compare > 0 then
        return T(_("↑ %1% vs previous"), pct)
    end
    return T(_("↓ %1% vs previous"), pct)
end

-- ---------------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------------

local ReadStatsView = InputContainer:extend{
    data = nil,
    on_prev = nil,
    on_next = nil,
    on_switch = nil,
}

function ReadStatsView:faces()
    return {
        number = Font:getFace("tfont", 28),
        label = Font:getFace("cfont", 15),
        card_title = Font:getFace("tfont", 18),
        body = Font:getFace("cfont", 16),
        small = Font:getFace("cfont", 13),
    }
end

-- Zero-height spacer that pins a VerticalGroup to the full content width.
function ReadStatsView:widthPin()
    return HorizontalSpan:new{ width = self.content_width }
end

function ReadStatsView:makeCard(inner)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = self.card_border,
        radius = Size.radius.window,
        padding = self.card_padding,
        margin = 0,
        inner,
    }
end

function ReadStatsView:cardTitle(text)
    local f = self.fonts
    return VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = text, face = f.card_title, max_width = self.content_width },
        VerticalSpan:new{ width = Size.padding.small },
        LineWidget:new{
            dimen = Geom:new{ w = self.content_width, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        },
        VerticalSpan:new{ width = Size.padding.default },
    }
end

-- A left label + right value line spanning the full content width.
function ReadStatsView:kvLine(left, right, face)
    face = face or self.fonts.body
    local right_w = TextWidget:new{ text = right, face = face }
    local rw = right_w:getSize().w
    local left_w = TextWidget:new{
        text = left, face = face,
        max_width = math.max(1, self.content_width - rw - Size.padding.default),
    }
    local gap = math.max(Size.padding.default, self.content_width - rw - left_w:getSize().w)
    return HorizontalGroup:new{
        left_w,
        HorizontalSpan:new{ width = gap },
        right_w,
    }
end

-- Horizontal proportional bar: "name ....... value" then a scaled bar below.
function ReadStatsView:proportionBar(name, value_text, ratio)
    local bar_w = math.max(1, math.floor(math.min(1, ratio) * self.content_width + 0.5))
    return VerticalGroup:new{
        align = "left",
        self:kvLine(name, value_text, self.fonts.body),
        VerticalSpan:new{ width = Size.padding.tiny },
        LineWidget:new{
            dimen = Geom:new{ w = bar_w, h = Screen:scaleBySize(6) },
            background = Blitbuffer.COLOR_BLACK,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Cards
-- ---------------------------------------------------------------------------

function ReadStatsView:buildOverviewCard()
    local d, f = self.data, self.fonts
    local content = VerticalGroup:new{ align = "left", self:widthPin() }

    -- Headline: total reading time, with a small caption to its right.
    local caption = TextWidget:new{ text = _("Total reading time"), face = f.label }
    local number = TextWidget:new{
        text = format_duration(d.total_read_time),
        face = f.number,
        max_width = math.max(1, self.content_width - caption:getSize().w - Size.padding.default),
    }
    table.insert(content, HorizontalGroup:new{
        align = "bottom",
        number,
        HorizontalSpan:new{ width = Size.padding.default },
        caption,
    })

    -- Sub-metrics on one wrapping line.
    local parts = { T(_("%1 days read"), d.read_days or 0) }
    if (d.day_average or 0) > 0 then
        parts[#parts + 1] = T(_("Daily average %1"), format_duration(d.day_average))
    end
    local cmp = format_compare(d.compare)
    if cmp then parts[#parts + 1] = cmp end
    if type(d.read_rate) == "number" and d.read_rate > 0 then
        parts[#parts + 1] = T(_("Text reading %1%"), math.floor(d.read_rate + 0.5))
    end
    if d.rank_text and d.rank_text ~= "" then
        parts[#parts + 1] = d.rank_text
    end
    table.insert(content, VerticalSpan:new{ width = Size.padding.default })
    table.insert(content, TextBoxWidget:new{
        text = table.concat(parts, "  ·  "),
        face = f.label,
        width = self.content_width,
    })

    -- Merged summary (读过/读完/阅读/笔记).
    local summary = d.summary or {}
    if #summary > 0 then
        local chips = {}
        for _i, s in ipairs(summary) do
            chips[#chips + 1] = T("%1 %2", s.name, s.counts)
        end
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        table.insert(content, LineWidget:new{
            dimen = Geom:new{ w = self.content_width, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        })
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        table.insert(content, TextBoxWidget:new{
            text = table.concat(chips, "    "),
            face = f.body,
            width = self.content_width,
        })
    end

    return self:makeCard(content)
end

-- Vertical bar chart with a value axis on the left.
function ReadStatsView:buildChartCard()
    local d, f = self.data, self.fonts
    local buckets = d.buckets or {}
    if #buckets == 0 then
        return nil
    end

    local n = #buckets
    local max_value = 1
    for _i, b in ipairs(buckets) do
        if b.value > max_value then max_value = b.value end
    end

    local chart_h = Screen:scaleBySize(104)
    -- Left value axis: peak at top, 0 at bottom.
    local top_lbl = format_duration_axis(max_value)
    local axis_top = TextWidget:new{ text = top_lbl, face = f.small }
    local axis_bot = TextWidget:new{ text = "0", face = f.small }
    local lh = axis_top:getSize().h
    local axis_w = math.max(axis_top:getSize().w, axis_bot:getSize().w)
    local axis_col = VerticalGroup:new{
        align = "right",
        RightContainer:new{ dimen = Geom:new{ w = axis_w, h = lh }, axis_top },
        VerticalSpan:new{ width = math.max(0, chart_h - 2 * lh) },
        RightContainer:new{ dimen = Geom:new{ w = axis_w, h = lh }, axis_bot },
    }

    local axis_gap = Size.padding.small
    local chart_w = self.content_width - axis_w - axis_gap
    local gap = Screen:scaleBySize(n > 16 and 2 or 4)
    local bar_w = math.floor((chart_w - (n - 1) * gap) / n)
    if bar_w < 1 then bar_w = 1 end
    local label_step = math.ceil(n / 8)

    local bars_row = HorizontalGroup:new{ align = "bottom" }
    local labels_row = HorizontalGroup:new{ align = "top" }
    for i, b in ipairs(buckets) do
        local bar_h = math.floor((b.value / max_value) * chart_h + 0.5)
        if bar_h == 0 and b.value > 0 then bar_h = 1 end
        local col = bar_h > 0
            and LineWidget:new{ dimen = Geom:new{ w = bar_w, h = bar_h }, background = Blitbuffer.COLOR_BLACK }
            or VerticalSpan:new{ width = 0 }
        table.insert(bars_row, BottomContainer:new{ dimen = Geom:new{ w = bar_w, h = chart_h }, col })

        local label_text = ((i - 1) % label_step == 0) and b.label or ""
        table.insert(labels_row, CenterContainer:new{
            dimen = Geom:new{ w = bar_w, h = lh + Screen:scaleBySize(2) },
            TextWidget:new{ text = label_text, face = f.small },
        })
        if i < n then
            table.insert(bars_row, HorizontalSpan:new{ width = gap })
            table.insert(labels_row, HorizontalSpan:new{ width = gap })
        end
    end

    local chart_col = VerticalGroup:new{
        align = "left",
        bars_row,
        LineWidget:new{ dimen = Geom:new{ w = chart_w, h = Size.line.medium }, background = Blitbuffer.COLOR_BLACK },
        VerticalSpan:new{ width = Size.padding.tiny },
        labels_row,
    }

    local content = VerticalGroup:new{
        align = "left",
        self:widthPin(),
        self:cardTitle(_("Reading time trend")),
        HorizontalGroup:new{
            align = "top",
            axis_col,
            HorizontalSpan:new{ width = axis_gap },
            chart_col,
        },
    }
    return self:makeCard(content)
end

function ReadStatsView:buildRankCard()
    local list = self.data.top_books or {}
    if #list == 0 then
        return nil
    end
    local max_seconds = 1
    for _i, item in ipairs(list) do
        if item.seconds > max_seconds then max_seconds = item.seconds end
    end
    local content = VerticalGroup:new{ align = "left", self:widthPin(), self:cardTitle(_("Most-read books")) }
    for i, item in ipairs(list) do
        if i > 1 then
            table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        end
        table.insert(content, self:proportionBar(T("%1. %2", i, item.title),
            format_duration(item.seconds), item.seconds / max_seconds))
    end
    return self:makeCard(content)
end

function ReadStatsView:buildPreferenceCard()
    local d, f = self.data, self.fonts
    local categories = d.prefer_category or {}
    local authors = d.prefer_author or {}
    local publishers = d.prefer_publisher or {}
    if #categories == 0 and #authors == 0 and #publishers == 0
        and not d.prefer_time_word and not d.prefer_category_word then
        return nil
    end

    local content = VerticalGroup:new{ align = "left", self:widthPin(), self:cardTitle(_("Reading preferences")) }
    local first = true
    local function section(widget)
        if not first then
            table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        end
        first = false
        table.insert(content, widget)
    end

    if #categories > 0 then
        local max_seconds = 1
        for _i, c in ipairs(categories) do
            if c.seconds > max_seconds then max_seconds = c.seconds end
        end
        local group = VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = d.prefer_category_word or _("Categories"), face = f.label, max_width = self.content_width },
        }
        for i = 1, math.min(#categories, 5) do
            local c = categories[i]
            table.insert(group, VerticalSpan:new{ width = Size.padding.small })
            table.insert(group, self:proportionBar(c.title, format_duration(c.seconds), c.seconds / max_seconds))
        end
        section(group)
    end

    if d.prefer_time_word and d.prefer_time_word ~= "" then
        section(self:kvLine(_("Preferred time"), d.prefer_time_word, f.body))
    end

    local function name_count_line(label, items)
        local parts = {}
        for i = 1, math.min(#items, 6) do
            local it = items[i]
            parts[#parts + 1] = it.count > 0 and T("%1·%2", it.name, it.count) or it.name
        end
        section(VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = label, face = f.label, max_width = self.content_width },
            VerticalSpan:new{ width = Size.padding.tiny },
            TextBoxWidget:new{ text = table.concat(parts, "   "), face = f.body, width = self.content_width },
        })
    end
    if #authors > 0 then name_count_line(_("Favorite authors"), authors) end
    if #publishers > 0 then name_count_line(_("Favorite publishers"), publishers) end

    return self:makeCard(content)
end

function ReadStatsView:buildEmptyCard()
    return self:makeCard(VerticalGroup:new{
        align = "left",
        self:widthPin(),
        TextWidget:new{ text = _("No reading records for this period."), face = self.fonts.body, max_width = self.content_width },
    })
end

-- ---------------------------------------------------------------------------
-- Assembly
-- ---------------------------------------------------------------------------

function ReadStatsView:buildContent()
    local page = VerticalGroup:new{ align = "left" }
    local function add(card)
        if not card then return end
        if #page > 0 then
            table.insert(page, VerticalSpan:new{ width = Size.padding.large })
        end
        table.insert(page, card)
    end
    add(self:buildOverviewCard())
    add(self:buildChartCard())
    add(self:buildRankCard())
    add(self:buildPreferenceCard())
    if #page == 0 then
        add(self:buildEmptyCard())
    end
    return page
end

function ReadStatsView:buildTabBar()
    local n = #TABS
    local cell_w = math.floor(self.screen_w / n)
    local row = HorizontalGroup:new{}
    for _i, tab in ipairs(TABS) do
        local active = (tab.mode == self.data.mode)
        table.insert(row, Button:new{
            text = _(tab.text),
            width = cell_w,
            radius = 0,
            margin = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            preselect = active,
            text_font_bold = active,
            show_parent = self,
            callback = function() self:onSwitchMode(tab.mode) end,
        })
    end
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, row }
end

function ReadStatsView:buildNavRow()
    local d = self.data
    if not d.allow_prev and not d.allow_next then
        return nil
    end
    local gap = Size.padding.default
    local btn_w = math.floor((self.screen_w - 3 * gap) / 2)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = gap,
        HorizontalGroup:new{
            Button:new{
                text = _("‹ Previous"), width = btn_w, show_parent = self,
                enabled = d.allow_prev == true,
                callback = function() self:onPrevPeriod() end,
            },
            HorizontalSpan:new{ width = gap },
            Button:new{
                text = _("Next ›"), width = btn_w, show_parent = self,
                enabled = d.allow_next == true,
                callback = function() self:onNextPeriod() end,
            },
        },
    }
end

function ReadStatsView:init()
    self.fonts = self:faces()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true

    -- Authoritative widths. Reserve space for the scrollbar so cards never get
    -- cropped, and derive the inner content width from card border + padding.
    self.outer_margin = Size.padding.large
    self.card_border = Size.border.window
    self.card_padding = Size.padding.large
    local scrollbar_reserve = 3 * Screen:scaleBySize(6)
    local usable_w = self.screen_w - scrollbar_reserve - 2 * self.outer_margin
    self.card_width = usable_w
    self.content_width = usable_w - 2 * self.card_border - 2 * self.card_padding

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            PrevPeriod = { { "Left" } },
            NextPeriod = { { "Right" } },
        }
    end

    local d = self.data
    local mode_title = _(MODE_TITLE[d.mode] or "Reading statistics")
    local title = (d.period_label and d.period_label ~= "")
        and T("%1 · %2", mode_title, d.period_label) or mode_title
    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = title,
        title_multilines = true,
        align = "center",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local tab_bar = self:buildTabBar()
    local nav_row = self:buildNavRow()

    local top_h = self.title_bar:getHeight() + tab_bar:getSize().h
    local nav_h = nav_row and nav_row:getSize().h or 0
    local scroll_h = self.screen_h - top_h - nav_h

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = scroll_h },
        show_parent = self,
        HorizontalGroup:new{
            HorizontalSpan:new{ width = self.outer_margin },
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = self.outer_margin },
                self:buildContent(),
                VerticalSpan:new{ width = self.outer_margin },
            },
        },
    }
    self.scroll = scroll

    local body = VerticalGroup:new{ align = "left", self.title_bar, tab_bar, scroll }
    if nav_row then
        table.insert(body, nav_row)
    end

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = self.dimen:copy(),
        body,
    }
end

function ReadStatsView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function ReadStatsView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function ReadStatsView:onClose()
    UIManager:close(self)
    return true
end

function ReadStatsView:onSwitchMode(mode)
    if mode ~= self.data.mode and self.on_switch then
        self.on_switch(mode)
    end
    return true
end

function ReadStatsView:onPrevPeriod()
    if self.data.allow_prev and self.on_prev then
        self.on_prev()
    end
    return true
end

function ReadStatsView:onNextPeriod()
    if self.data.allow_next and self.on_next then
        self.on_next()
    end
    return true
end

local M = {}

-- Show the statistics page.
--   data      : normalized stats table from lib/read_stats.lua
--   callbacks : { on_prev = fn, on_next = fn, on_switch = fn(mode) }
-- Returns the widget instance.
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = ReadStatsView:new{
        data = data,
        on_prev = callbacks.on_prev,
        on_next = callbacks.on_next,
        on_switch = callbacks.on_switch,
    }
    UIManager:show(view)
    return view
end

return M
