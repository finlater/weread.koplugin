--[[--
Native WeRead thought dialog.

Uses KOReader's TextViewer/TextBoxWidget stack instead of ScrollHtmlWidget, so
opening a thought never initializes MuPDF, parses CSS, or loads document fonts.
Short pageReviews share a dialog page until the native text layout is full;
long items use fewer pages and an oversized single item remains scrollable.
Explicit previous/next buttons navigate between these measured groups.

@module weread.ui.thought_popup
--]]--

local Device = require("device")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")

local Annotations = require("weread.lib.annotations")
local I18n = require("weread.lib.i18n")

local Screen = Device.screen
local THOUGHT_SEPARATOR = "\n\n"
local EMOJI_FONT_ALIAS = "weread_emoji_fallback"

local function _(text)
    return I18n.tr(text)
end

local function removeUnsafeEmojiFallback()
    local removed = false
    for index = #Font.fallbacks, 1, -1 do
        if Font.fallbacks[index] == EMOJI_FONT_ALIAS then
            table.remove(Font.fallbacks, index)
            removed = true
        end
    end
    if Font.fontmap[EMOJI_FONT_ALIAS] ~= nil then
        Font.fontmap[EMOJI_FONT_ALIAS] = nil
        removed = true
    end
    if removed then
        -- Also recover safely when the plugin is reloaded without restarting
        -- KOReader after a build that had injected this global fallback.
        for _, face in pairs(Font.faces) do
            face.fallbacks = nil
        end
    end
end

removeUnsafeEmojiFallback()

local NativeThoughtPopup = TextViewer:extend{
    items = nil,
    display_pages = nil,
    page_index = 1,
    completion_callback = nil,
    height_ratio = 0.62,
}

local function buildDisplayPages(items, fits)
    local pages = {}
    local first_index = 1
    local texts = {}

    local function flush(last_index)
        pages[#pages + 1] = {
            first_index = first_index,
            last_index = last_index,
            text = table.concat(texts, THOUGHT_SEPARATOR),
        }
    end

    for item_index, item in ipairs(items) do
        local item_text = Annotations.formatThoughtPopupItem(item)
        if #texts > 0 then
            local candidate_texts = {}
            for i, text in ipairs(texts) do
                candidate_texts[i] = text
            end
            candidate_texts[#candidate_texts + 1] = item_text
            local candidate = table.concat(candidate_texts, THOUGHT_SEPARATOR)
            if not fits(candidate) then
                flush(item_index - 1)
                first_index = item_index
                texts = {}
            end
        end
        texts[#texts + 1] = item_text
    end
    if #texts > 0 then
        flush(#items)
    end
    return pages
end

-- KOReader exposes the text area as self.scroll_widget/self.box_widget only
-- since upstream #15588 (2026-06). Released versions name it self.scroll_text_w
-- and keep the TextBoxWidget in its .text_widget.
function NativeThoughtPopup:_textWidgets()
    local scroll_widget = self.scroll_widget or self.scroll_text_w
    local box_widget = self.box_widget or (scroll_widget and scroll_widget.text_widget)
    return scroll_widget, box_widget
end

function NativeThoughtPopup:_measureDisplayPages()
    local _, box_widget = self:_textWidgets()
    if not box_widget then
        logger.warn("thought popup text widget unavailable, keeping one item per page")
        return
    end

    local visible_lines = box_widget:getVisLineCount()
    local function fits(text)
        local measurement = TextBoxWidget:new{
            text = text,
            dialog = self,
            face = box_widget.face,
            fgcolor = box_widget.fgcolor,
            width = box_widget.width,
            alignment = self.alignment,
            justified = self.justified,
            lang = self.lang,
            para_direction_rtl = self.para_direction_rtl,
            auto_para_direction = self.auto_para_direction,
            alignment_strict = self.alignment_strict,
            for_measurement_only = true,
        }
        local line_count = measurement:getAllLineCount()
        measurement:free()
        return line_count <= visible_lines
    end

    local ok, pages = pcall(buildDisplayPages, self.items, fits)
    if ok and type(pages) == "table" and #pages > 0 then
        self.display_pages = pages
    else
        logger.warn("thought popup measurement failed:", tostring(pages))
    end
end

function NativeThoughtPopup:_updatePage()
    local count = #self.display_pages
    if self.page_index < 1 then
        self.page_index = 1
    elseif self.page_index > count then
        self.page_index = count
    end
    local page = self.display_pages[self.page_index]
    local abstract = self.items[1] and self.items[1].abstract
    if type(abstract) == "string" and abstract ~= "" then
        -- Let TitleBar use its exact available width (including the close icon)
        -- and wrap long abstracts onto multiple lines (title_multilines).
        self.title = abstract:gsub("%s+", " ")
    else
        self.title = _("Thoughts")
    end
    self.text = page.text
    self.charlist = nil
end

function NativeThoughtPopup:_pageProgressText()
    local page = self.display_pages[self.page_index]
    return tostring(page.last_index) .. "/" .. tostring(#self.items)
end

function NativeThoughtPopup:_buildButtons()
    local popup = self
    return {
        {
            {
                text = "‹ " .. _("Previous"),
                id = "previous_thought",
                enabled_func = function()
                    return popup.page_index > 1
                end,
                callback = function()
                    popup:changePage(-1)
                end,
            },
            {
                text = popup:_pageProgressText(),
                id = "thought_position",
                callback = function() end,
            },
            {
                text = _("Next") .. " ›",
                id = "next_thought",
                enabled_func = function()
                    return popup.page_index < #popup.display_pages
                end,
                callback = function()
                    popup:changePage(1)
                end,
            },
        },
    }
end

function NativeThoughtPopup:_replaceVisibleText()
    local scroll_widget, box_widget = self:_textWidgets()
    if not (box_widget and box_widget.setText) then
        return false
    end
    box_widget.virtual_line_num = 1
    if box_widget.text ~= self.text then
        box_widget.charlist = nil
        box_widget:setText(self.text)
    end
    if scroll_widget then
        scroll_widget.text = self.text
        if scroll_widget.resetScroll then
            scroll_widget:resetScroll()
        end
    end
    return true
end

function NativeThoughtPopup:_syncPageButtons()
    if not (self.button_table and self.button_table.getButtonById) then
        return
    end
    local previous_button = self.button_table:getButtonById("previous_thought")
    local position_button = self.button_table:getButtonById("thought_position")
    local next_button = self.button_table:getButtonById("next_thought")
    if previous_button and previous_button.enableDisable then
        previous_button:enableDisable(self.page_index > 1)
    end
    if next_button and next_button.enableDisable then
        next_button:enableDisable(self.page_index < #self.display_pages)
    end
    if position_button and position_button.setText then
        position_button:setText(
            self:_pageProgressText(), position_button.width
        )
    end
end

function NativeThoughtPopup:init(reinit)
    self.items = self.items or {}
    -- A one-item fallback lets TextViewer create the real text area first.
    -- Once its exact width, font and visible line count are known, the items are
    -- repaginated below with KOReader's own TextBoxWidget measurement.
    self.display_pages = self.display_pages or buildDisplayPages(
        self.items, function() return false end
    )
    self.page_index = self.page_index or 1
    self.height_ratio = math.max(0.55, math.min(0.85, self.height_ratio or 0.62))
    self.width = Screen:getWidth() - Screen:scaleBySize(24)
    self.height = math.floor(Screen:getHeight() * self.height_ratio)
    self.show_menu = false
    self.add_default_buttons = false
    self.text_type = "general"
    self.alignment = "left"
    -- wrap long abstract titles instead of truncating
    self.title_multilines = true
    self.title_face = Font:getFace("x_smalltfont", 18)
    self.auto_para_direction = true
    self.buttons_table = self:_buildButtons()
    self:_updatePage()
    TextViewer.init(self, reinit)
    if not reinit and not self._display_pages_measured then
        self._display_pages_measured = true
        self:_measureDisplayPages()
        self:_updatePage()
        if self.titlebar and self.titlebar.setTitle then
            self.titlebar:setTitle(self.title, true)
        end
        self:_replaceVisibleText()
        self:_syncPageButtons()
    end
end

function NativeThoughtPopup:changePage(delta)
    local next_index = self.page_index + delta
    if next_index < 1 or next_index > #self.display_pages then
        return
    end
    self.page_index = next_index
    self:_updatePage()

    -- Keep the existing TextViewer tree and replace only its title/text. Using
    -- TextViewer:init(true) here rebuilds the whole dialog, while marking
    -- "all" dirty also repaints the reader beneath it on e-ink screens.
    if self.titlebar and self.titlebar.setTitle then
        self.titlebar:setTitle(self.title, true)
    end
    if not self:_replaceVisibleText() then
        -- Defensive fallback for an unusually old TextBoxWidget API.
        self:init(true)
        local scroll_widget = self:_textWidgets()
        if scroll_widget and scroll_widget.scrollToTop then
            scroll_widget:scrollToTop()
        end
    end

    self:_syncPageButtons()
    UIManager:setDirty(self, "partial", self.frame.dimen)
end

function NativeThoughtPopup:onClose()
    UIManager:close(self)
    return true
end

function NativeThoughtPopup:onCloseWidget()
    TextViewer.onCloseWidget(self)
    if self.completion_callback then
        local callback = self.completion_callback
        self.completion_callback = nil
        callback(self.height)
    end
end

local M = {}
local active_popup = nil

function M.show(opts)
    opts = opts or {}
    if type(opts.pages) ~= "table" or #opts.pages == 0 then
        error("thought popup: invalid pages")
    end

    if active_popup and M.isShowing() then
        UIManager:close(active_popup)
    end

    local popup
    popup = NativeThoughtPopup:new{
        items = opts.pages,
        page_index = opts.page_index or 1,
        height_ratio = opts.height_ratio,
        completion_callback = function(height)
            if active_popup == popup then
                active_popup = nil
            end
            if opts.close_callback then
                opts.close_callback(height)
            end
        end,
    }
    active_popup = popup
    UIManager:show(popup)
    return popup
end

function M.closeVisible()
    if active_popup then
        UIManager:close(active_popup)
    end
end

function M.isShowing()
    if not active_popup then
        return false
    end
    local ok, shown = pcall(function()
        return UIManager:isWidgetShown(active_popup)
    end)
    return ok and shown == true
end

function M.getPoolStats()
    return {
        pool_size = active_popup and 1 or 0,
        max_size = 1,
        has_active = active_popup ~= nil,
    }
end

function M.cleanup()
    M.closeVisible()
    active_popup = nil
end

return M
