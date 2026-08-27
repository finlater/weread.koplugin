-- Shared thought-popup configuration for downloaded and externally matched books.
local M = {}

local function layoutParams(plugin, popup_settings)
    local document = plugin.ui and plugin.ui.document
    if not document then return {} end
    local Screen = require("device").screen

    local font_face = plugin.ui.font and plugin.ui.font.font_face
    if not font_face and G_reader_settings then
        font_face = G_reader_settings:readSetting("cre_font")
    end

    local font_size = popup_settings.font_size
    local font_size_scaled
    if font_size then
        font_size_scaled = Screen:scaleBySize(font_size)
    else
        local relative = tonumber(popup_settings.font_size_relative) or 0
        local doc_font_size = (document.configurable and document.configurable.font_size) or 18
        font_size_scaled = Screen:scaleBySize(doc_font_size) + relative
    end

    local ok, margins = pcall(function()
        return document:getPageMargins()
    end)

    return {
        doc_font_name = font_face,
        doc_font_size = font_size_scaled,
        doc_margins = ok and margins or nil,
    }
end

--- Build the complete ThoughtPopup.show options used by every annotation source.
function M.build(plugin, pages, extra)
    local popup_settings = plugin.settings:get("thought_popup", {})
    local layout = layoutParams(plugin, popup_settings)
    local opts = {
        pages = pages,
        height_ratio = tonumber(popup_settings.height_ratio) or 0.70,
        position = popup_settings.position or "center",
        width_ratio = tonumber(popup_settings.width_ratio) or 0.8,
        contrast = tonumber(popup_settings.contrast) or 9,
        tap_to_page = popup_settings.tap_to_page == true,
        dialog = plugin.dialog,
        doc_font_name = layout.doc_font_name,
        doc_font_size = layout.doc_font_size,
        doc_margins = layout.doc_margins,
    }
    for key, value in pairs(extra or {}) do
        opts[key] = value
    end
    return opts
end

return M
