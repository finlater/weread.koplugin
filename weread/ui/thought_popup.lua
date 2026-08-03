--[[--
Native WeRead thought dialog.

Renders a thought's review items as a bottom popup: each item is shaped and
paginated directly, then drawn into a scrollable bitmap viewport. Long reviews
scroll; short ones shrink to their content height.

Implementation lives in weread/ui/thought_popup/: widget.lua (rendering and
caching), content_builder.lua (items -> blocks), face_factory.lua (fonts),
paginator.lua (pagination) and scroll_container.lua (viewport). This module is
the public entry point; the pooled widget is reused across opens so reopening
the same thought rebuilds nothing.

@module weread.ui.thought_popup
--]]

local FaceFactory = require("weread.ui.thought_popup.face_factory")
local ThoughtPopupWidget = require("weread.ui.thought_popup.widget")
local UIManager = require("ui/uimanager")

FaceFactory:init()

local M = {}
local _pooled_popup = nil

--- Show (or reopen the pooled instance) a thought popup.
--- @param opts table { pages, doc_font_name, doc_font_size, doc_margins,
---                    height_ratio, dialog, close_callback }
function M.show(opts)
    opts = opts or {}
    if type(opts.pages) ~= "table" or #opts.pages == 0 then
        error("thought popup: invalid pages")
    end

    -- The widget stores the records under `items` (its field name); the
    -- public contract uses `pages`. Normalize once so the initial construction
    -- and the pooled reopen below both receive the items.
    opts.items = opts.items or opts.pages

    if _pooled_popup then
        _pooled_popup:_reopen(opts)
        UIManager:show(_pooled_popup)
        return _pooled_popup
    end

    local popup = ThoughtPopupWidget:new{
        items = opts.items,
        doc_font_name = opts.doc_font_name,
        doc_font_size = opts.doc_font_size,
        doc_margins = opts.doc_margins,
        height_ratio = opts.height_ratio,
        dialog = opts.dialog,
        close_callback = opts.close_callback,
    }
    _pooled_popup = popup
    UIManager:show(popup)
    return popup
end

function M.closeVisible()
    if _pooled_popup then
        UIManager:close(_pooled_popup)
    end
end

function M.isShowing()
    if not _pooled_popup then
        return false
    end
    local ok, shown = pcall(function()
        return UIManager:isWidgetShown(_pooled_popup)
    end)
    return ok and shown == true
end

function M.getPoolStats()
    return {
        pool_size = _pooled_popup and 1 or 0,
        max_size = 1,
        has_active = _pooled_popup ~= nil,
    }
end

function M.cleanup()
    if _pooled_popup then
        pcall(function()
            UIManager:close(_pooled_popup)
        end)
        -- clear() frees the subtree; bitmaps are freed by _freeContentCaches.
        _pooled_popup:clear()
        _pooled_popup:_freeContentCaches()
        _pooled_popup = nil
    end
end

return M
