--[[--
Native WeRead thought dialog.

Renders a thought's review items as a popup in one of two positions:

  * "bottom" (default): the bottom bar with a solid top border; long reviews
    scroll inside a bitmap viewport (widget.lua + scroll_container.lua);
  * "center": a TextViewer-style centered window with a title bar and explicit
    Previous/Next page buttons; long reviews — including a single long thought
    — are paginated across pages instead of scrolling (center_widget.lua).

Both positions share the same rendering pipeline (pages.lua: layout, page and
piece caches) and the same font/height settings. Implementation lives in
weread/ui/thought_popup/: this module is the public entry point; the widget
for the active position is pooled and reused across opens so reopening the
same thought rebuilds nothing.

@module weread.ui.thought_popup
--]]

local FaceFactory = require("weread.ui.thought_popup.face_factory")
local UIManager = require("ui/uimanager")

FaceFactory:init()

local M = {}
local _pool = {}  -- position ("bottom" | "center") -> pooled widget

local function normalizePosition(position)
    return position == "center" and "center" or "bottom"
end

--- The widget class for a position; required lazily so the entry can be
--- loaded without instantiating UI (and so tests can mock either widget).
local function widgetClassFor(position)
    if position == "center" then
        return require("weread.ui.thought_popup.center_widget")
    end
    return require("weread.ui.thought_popup.widget")
end

--- Show (or reopen the pooled instance for the position) a thought popup.
--- @param opts table { pages, position?, doc_font_name, doc_font_size,
---                    doc_margins, height_ratio, dialog, close_callback }
function M.show(opts)
    opts = opts or {}
    if type(opts.pages) ~= "table" or #opts.pages == 0 then
        error("thought popup: invalid pages")
    end

    -- The widget stores the records under "items" (its field name); the
    -- public contract uses "pages". Normalize once so the initial construction
    -- and the pooled reopen below both receive the items.
    opts.items = opts.items or opts.pages

    local position = normalizePosition(opts.position)

    -- Only the active position stays resident: drop the other pool so its
    -- page/piece/layout caches (bitmaps) are not held for the whole session.
    for other_position, pooled in pairs(_pool) do
        if other_position ~= position then
            pcall(function()
                if UIManager:isWidgetShown(pooled) then
                    UIManager:close(pooled)
                end
            end)
            pooled:clear()
            pooled:_freeContentCaches()
            _pool[other_position] = nil
        end
    end

    local pooled = _pool[position]
    if pooled then
        pooled:_reopen(opts)
        UIManager:show(pooled)
        return pooled
    end

    local popup = widgetClassFor(position):new{
        items = opts.items,
        doc_font_name = opts.doc_font_name,
        doc_font_size = opts.doc_font_size,
        doc_margins = opts.doc_margins,
        height_ratio = opts.height_ratio,
        width_ratio = opts.width_ratio,
        contrast = opts.contrast,
        dialog = opts.dialog,
        close_callback = opts.close_callback,
    }
    _pool[position] = popup
    UIManager:show(popup)
    return popup
end

function M.closeVisible()
    for _, pooled in pairs(_pool) do
        pcall(function()
            UIManager:close(pooled)
        end)
    end
end

function M.isShowing()
    for _, pooled in pairs(_pool) do
        local ok, shown = pcall(function()
            return UIManager:isWidgetShown(pooled)
        end)
        if ok and shown == true then
            return true
        end
    end
    return false
end

function M.getPoolStats()
    local count = 0
    for _, pooled in pairs(_pool) do
        if pooled then
            count = count + 1
        end
    end
    return {
        pool_size = count,
        max_size = 1,
        has_active = count > 0,
    }
end

function M.cleanup()
    if not next(_pool) then
        return
    end
    for _, pooled in pairs(_pool) do
        pcall(function()
            UIManager:close(pooled)
        end)
        -- clear() frees the subtree; bitmaps are freed by _freeContentCaches.
        pooled:clear()
        pooled:_freeContentCaches()
    end
    _pool = {}
end

return M
