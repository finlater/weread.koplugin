-- EPUB-safe external annotations for arbitrary local reflowable books.
local UIManager = require("ui/uimanager")

local External = require("weread.lib.external_annotations")
local Overlay = require("weread.ui.xpointer_overlay")
local PluginUtil = require("weread.lib.plugin_util")
local ThoughtPopupConfig = require("weread.ui.thought_popup.popup_config")

local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}
local VIEW_MODULE = "weread_xpointer_overlay"
local TOUCH_ZONE = "weread_xpointer_overlay_tap"

local function current_file(plugin)
    return plugin.ui and plugin.ui.document and plugin.ui.document.file
end

local function current_records(plugin)
    local file = current_file(plugin)
    if not file then return {} end
    local value = plugin.external_annotations_db:getDocument(file)
    return value and type(value.records) == "table" and value.records or {}
end

local function is_supported(plugin)
    local document = plugin.ui and plugin.ui.document
    return document and document.info and not document.info.has_pages
        and type(document.getXPointer) == "function"
        and type(document.getScreenBoxesFromPositions) == "function"
end

local function is_page_turn_edge(plugin, pos)
    if not pos then return false end
    local cache = plugin.settings:get("cache", {})
    if cache.ignore_edge_thought_taps == false then return false end
    local ratio = tonumber(cache.edge_tap_ratio) or 0.20
    ratio = math.max(0.05, math.min(0.45, ratio))
    local width = require("device").screen:getWidth()
    return pos.x < width * ratio or pos.x > width * (1 - ratio)
end

function M:_xpointerOverlayPrototypeAvailable()
    return is_supported(self)
end

function M:_setupXPointerOverlayPrototype()
    if self._xpointer_overlay or not is_supported(self)
        or not self.ui.view or type(self.ui.view.registerViewModule) ~= "function" then
        return false
    end
    local cache = self.settings:get("cache", {})
    local overlay = Overlay:new{
        records = current_records(self),
        enabled = cache.show_annotations ~= false,
    }
    self.ui.view:registerViewModule(VIEW_MODULE, overlay)
    self._xpointer_overlay = overlay

    local Device = require("device")
    if Device:isTouchDevice() then
        self.ui:registerTouchZones({
            {
                id = TOUCH_ZONE,
                ges = "tap",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
                },
                overrides = {
                    "readerhighlight_tap",
                    "tap_top_left_corner", "tap_top_right_corner",
                    "tap_left_bottom_corner", "tap_right_bottom_corner",
                    "readerfooter_tap", "readermenu_ext_tap", "readermenu_tap",
                    "tap_forward", "tap_backward",
                },
                handler = function(ges)
                    return self:_onXPointerOverlayTap(ges)
                end,
            },
        })
        self._xpointer_overlay_touch_registered = true
    end
    return true
end

function M:_teardownXPointerOverlayPrototype()
    if self._xpointer_overlay_touch_registered and self.ui then
        self.ui:unRegisterTouchZones({
            {
                id = TOUCH_ZONE,
                overrides = {
                    "readerhighlight_tap",
                    "tap_top_left_corner", "tap_top_right_corner",
                    "tap_left_bottom_corner", "tap_right_bottom_corner",
                    "readerfooter_tap", "readermenu_ext_tap", "readermenu_tap",
                    "tap_forward", "tap_backward",
                },
            },
        })
    end
    self._xpointer_overlay_touch_registered = nil
    if self.ui and self.ui.view and self.ui.view.view_modules then
        self.ui.view.view_modules[VIEW_MODULE] = nil
    end
    self._xpointer_overlay = nil
end

function M:_onXPointerOverlayTap(ges)
    local overlay = self._xpointer_overlay
    if not overlay or not overlay.enabled or not ges or not ges.pos then
        return false
    end
    if is_page_turn_edge(self, ges.pos) then return false end
    local record = overlay:hitTest(ges.pos)
    if not record then return false end
    local items = record.items
    local context = self._annotation_context
    if context and not items then
        items = context.store:get(context.book_id, "thought",
            record.chapter_uid .. ":" .. record.range)
    end
    if type(items) ~= "table" or #items == 0 then
        items = {
            {
                abstract = record.text,
                author = _("WeRead"),
                content = _("No thoughts were returned for this underline."),
                likes_count = 0,
            },
        }
    end
    require("weread.ui.thought_popup").show(ThoughtPopupConfig.build(self, items))
    return true
end

local function current_entry(plugin)
    return plugin.external_annotations_db:getDocument(current_file(plugin))
end

function M:bindExternalAnnotationsBook(touchmenu_instance)
    if not self:requireLogin(true, true) then return end
    local path = current_file(self)
    if not path then return end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Match local book with WeRead"),
        input = (path:match("([^/]+)%.[^%.]+$") or ""),
        input_type = "text",
        buttons = { { {
            text = _("Cancel"), id = "close",
            callback = function() UIManager:close(dialog) end,
        }, {
            text = _("Search"), is_enter_default = true,
            callback = function()
                local keyword = dialog:getInputText()
                UIManager:close(dialog)
                self:runOnlineTask(_("Search"), function()
                    local result = self.client:gateway("/store/search", { keyword = keyword, count = 20 })
                    local items = {}
                    for _index, book in ipairs(External.normalize_search(result)) do
                        items[#items + 1] = {
                            text = book.title ~= "" and book.title or book.book_id,
                            post_text = book.author,
                            callback = function()
                                if current_file(self) ~= path then return end
                                if self._cancelUnifiedAnnotationSync then self:_cancelUnifiedAnnotationSync() end
                                local old = current_entry(self) or {}
                                old.binding = {
                                    book_id = book.book_id, title = book.title,
                                    author = book.author, format = book.format,
                                    bound_at = os.time(),
                                }
                                old.records = {}
                                self._annotation_context = nil
                                self._unified_annotations_active = nil
                                local saved, save_err = self.external_annotations_db:saveDocument(path, old)
                                if not saved then error(save_err) end
                                local cleared, clear_err =
                                    self.external_annotations_db:clearSyncCheckpoint(path)
                                if not cleared then error(clear_err) end
                                if self._xpointer_overlay then self._xpointer_overlay:setRecords({}) end
                                if touchmenu_instance
                                    and type(touchmenu_instance.updateItems) == "function" then
                                    touchmenu_instance:updateItems()
                                end
                                local ConfirmBox = require("ui/widget/confirmbox")
                                UIManager:show(ConfirmBox:new{
                                    title = _("Local book matched"),
                                    text = T(_("Matched with “%1”.\n\nSync underlines and thoughts now?\n\nYou can cancel at any time. Downloaded progress is saved and resumed automatically next time."),
                                        book.title ~= "" and book.title or book.book_id),
                                    ok_text = _("Sync underlines and thoughts"),
                                    cancel_text = _("Later"),
                                    ok_callback = function()
                                        self:syncExternalAnnotations()
                                    end,
                                })
                            end,
                        }
                    end
                    self:showList(_("Select matching WeRead book"), items, _("No search results."))
                end)
            end,
        } } },
    }
    self:showInputDialog(dialog)
end

function M:syncExternalAnnotations(options)
    return self:startUnifiedAnnotationSync(options)
end

function M:clearExternalAnnotations(touchmenu_instance)
    return self:clearUnifiedAnnotationProjections(touchmenu_instance)
end

function M:getXPointerOverlayPrototypeMenuItems()
    return self:getUnifiedAnnotationMenuItems()
end

function M:_invalidateXPointerOverlayLayout()
    if self._xpointer_overlay then self._xpointer_overlay:invalidate() end
end

-- CREngine emits UpdatePos after every layout-affecting typography change
-- (font size/family, line spacing, word spacing, margins, etc.).  The current
-- page number may stay unchanged, so the page-keyed rectangle cache must be
-- discarded before ReaderView paints the newly reflowed document.
function M:onUpdatePos()
    if self._refreshAnnotationOverlay then self:_refreshAnnotationOverlay() end
    self:_invalidateXPointerOverlayLayout()
end

function M:onDocumentRerendered()
    self:_invalidateXPointerOverlayLayout()
end

return M
