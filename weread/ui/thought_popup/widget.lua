--[[--
Thought popup widget.

Renders review items by shaping each text block with the document font (or a
fallback chain) and paginating once; pages are blitted into a bitmap viewport
that scrolls. Long content scrolls directly, with no button navigation.

Rendering model: every block is rendered with its own TextBoxWidget, then all
blocks are composited by y offset into a full-content bitmap
(BB8 / BBRGB32); scrolling translates the viewport over that bitmap. The
content bitmap is cached by (item identity | geometry), so reopening the same
thought on the pooled popup rebuilds nothing.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ContentBuilder = require("weread.ui.thought_popup.content_builder")
local Device = require("device")
local FaceFactory = require("weread.ui.thought_popup.face_factory")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Paginator = require("weread.ui.thought_popup.paginator")
local ScrollContainer = require("weread.ui.thought_popup.scroll_container")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("weread.lib.logger")

-- Popup chrome constants.
local TOP_BORDER_SIZE = Size.line.thick
local PADDING_TOP = Size.padding.large
local PADDING_BOTTOM = Size.padding.large

-- Page bitmap cache size (LRU): each page is roughly viewport-sized;
-- 8 pages are ~12 MB on a typical e-reader screen.
local PAGE_BB_CACHE_MAX = 8
-- Piece render cache size (LRU): TextBoxWidget instances are reused across
-- pages, so after a page bitmap is evicted re-rendering does not re-run xtext
-- shaping. 200 pieces cover a full layout (about 100-150 for 30 thoughts),
-- at roughly 15 KB each.
local PIECE_CACHE_MAX = 200
-- Layout cache size (LRU): a layout is pagination metadata without bitmaps,
-- so a few more entries are fine.
local LAYOUT_CACHE_MAX = 6

-- Content bitmap cache key: the rendered content is a pure function of the
-- items, so the item payload itself is the identity (two different ranges
-- with identical items render identically anyway).
local function itemsKey(items)
    local parts = {}
    for _, item in ipairs(items or {}) do
        parts[#parts + 1] = string.format("%s|%s|%s|%d",
            tostring(item.abstract or ""),
            tostring(item.author or ""),
            tostring(item.content or ""),
            tonumber(item.likes_count) or 0)
    end
    return table.concat(parts, "\n")
end

local function geomKey(doc_font_name, doc_font_size, margins, height_ratio)
    local m = margins or {}
    return string.format("%s|%d|%d_%d_%d_%d|%.4f",
        doc_font_name or "", doc_font_size or 0,
        m.left or 0, m.right or 0, m.top or 0, m.bottom or 0,
        height_ratio or 0.35)
end

local ThoughtPopupWidget = InputContainer:extend{
    items = nil,
    doc_font_name = nil,
    doc_font_size = Screen:scaleBySize(18),
    doc_margins = {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = 0.35,
    close_callback = nil,
    dialog = nil,

    -- render state
    _layout_cache = nil,        -- { [key] = layout } (pagination only, no bitmaps)
    _layout_order = nil,
    _page_bbs = nil,            -- { [page_idx] = Blitbuffer }
    _page_order = nil,
    _piece_cache = nil,         -- { [piece] = {tb=TextBoxWidget} }
    _piece_order = nil,
    _bb_key = nil,              -- current layout cache key
    _content_h = 0,
    _text_w = 0,
    _layout = nil,              -- { pieces, boundaries, content_h, text_w }
    _scroll_container = nil,
    _items_key = nil,
    _geom_key = nil,

    covers_footer = true,
}

function ThoughtPopupWidget:init()
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.35))
    self.width = Screen:getWidth()
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
            SwipeClose = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                }
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    self._layout_cache = self._layout_cache or {}
    self._page_bbs = self._page_bbs or {}
    self._items_key = itemsKey(self.items)
    self._geom_key = geomKey(self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio)
    self._bb_key = self._items_key .. "|" .. self._geom_key

    self:_ensureLayout()
    self:_buildLayout()
end

function ThoughtPopupWidget:onShow()
    UIManager:setDirty(self.dialog, function()
        return "partial", self.container.dimen
    end)
end

--- Reopen (pooled): rebuild the widget tree, and only re-render content when
--- the items or the geometry changed.
function ThoughtPopupWidget:_reopen(opts)
    self.items = opts.items or {}
    if opts.doc_font_name then self.doc_font_name = opts.doc_font_name end
    if opts.doc_font_size then self.doc_font_size = opts.doc_font_size end
    if opts.doc_margins then self.doc_margins = opts.doc_margins end
    if opts.height_ratio then self.height_ratio = opts.height_ratio end
    if opts.dialog then self.dialog = opts.dialog end
    self.close_callback = opts.close_callback
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.35))
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    local new_items_key = itemsKey(self.items)
    local new_geom_key = geomKey(self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio)
    local new_bb_key = new_items_key .. "|" .. new_geom_key

    if new_bb_key ~= self._bb_key then
        self._items_key = new_items_key
        self._geom_key = new_geom_key
        self._bb_key = new_bb_key
        self:_ensureLayout()
    end

    self:_buildLayout()
end

--- Paginate the layout (once per open; creates no widgets and rasterizes no
--- glyphs). Produces piece layouts (with per-line top/bottom boundaries);
--- page bitmaps render lazily.
function ThoughtPopupWidget:_paginate()
    local t0 = os.clock()
    local blocks = ContentBuilder.build(self.items)
    local t1 = os.clock()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local text_w = Screen:getWidth() - self.doc_margins.left - self.doc_margins.right - item_width
    if text_w < 10 then text_w = 10 end
    local base_size = math.max(8, math.floor(self.doc_font_size or 0))

    local pieces = {}       -- layout records (no widget handles)
    local boundaries = {}   -- page-break boundaries {top, bottom, keep_prev}
    local y = 0

    local function addTextPiece(variant, text, fg, width, x, keep_first)
        local face = FaceFactory:getFace(self.doc_font_name, base_size, variant)
        if not face then return false end
        local line_h, extra = Paginator.textPieceMetrics(face)
        local n_lines = Paginator.paginateLines(text, face, width)
        local piece_h = n_lines * line_h + extra
        local piece_y = y
        pieces[#pieces + 1] = {
            kind = "text", variant = variant, text = text, fg = fg,
            face = face, width = width, x = x, y = piece_y,
            n_lines = n_lines, line_h = line_h, piece_h = piece_h,
        }
        for k = 1, n_lines do
            boundaries[#boundaries + 1] = {
                top = piece_y + (k - 1) * line_h,
                bottom = piece_y + k * line_h,
                keep_prev = keep_first and k == 1,
            }
        end
        y = y + piece_h
        return true
    end

    for _, block in ipairs(blocks) do
        if block.kind == "paragraph" then
            addTextPiece(block.variant, block.text, block.fg, text_w, 0,
                block.variant == "content")
        end
    end

    local content_h = math.max(1, y)
    local t2 = os.clock()
    logger.info(string.format(
        "thought popup paginated in %.1fms (blocks %.1fms) items=%d content_h=%d",
        (t2 - t0) * 1000, (t1 - t0) * 1000, #self.items, content_h))
    return {
        pieces = pieces,
        boundaries = boundaries,
        content_h = content_h,
        item_count = #self.items,
        text_w = text_w,
    }
end

--- Create a text piece's TextBoxWidget (rendered on demand; glyphs are cached
--- across pages by KOReader's GlyphCache).
function ThoughtPopupWidget:_createTextBox(piece)
    local tb = TextBoxWidget:new{
        face = piece.face,
        text = piece.text,
        width = piece.width,
        height = nil,
        height_adjust = true,
        fgcolor = piece.fg or Blitbuffer.COLOR_BLACK,
        line_height = 0.2,
        use_xtext = true,
    }
    local actual = tb.vertical_string_list and #tb.vertical_string_list or 0
    if actual ~= piece.n_lines then
        -- Pagination consistency check: the same-source makeLine should always
        -- agree; a mismatch means the pagination copy drifted.
        logger.warn("thought popup pagination mismatch:",
            "piece_lines=", actual, "expected=", piece.n_lines)
    end
    return tb
end

--- Get a text piece's TextBoxWidget (piece-level cache reuse).
--- When a page bitmap is evicted from the LRU and re-rendered, the piece's
--- xtext shaping and bitmap are not rebuilt.
function ThoughtPopupWidget:_getPieceTB(piece)
    local cached = self._piece_cache and self._piece_cache[piece]
    if cached then
        self:_touchPiece(piece)
        return cached.tb
    end
    local tb = Paginator.ensureTextBoxBB(self:_createTextBox(piece))
    if not tb then return nil end
    self:_cachePiece(piece, { tb = tb })
    return tb
end

--- Write a piece into the cache and maintain LRU (evict the least recently
--- used when over the cap, freeing its bitmap).
function ThoughtPopupWidget:_cachePiece(piece, payload)
    self._piece_cache = self._piece_cache or {}
    self._piece_order = self._piece_order or {}
    self._piece_cache[piece] = payload
    self._piece_order[#self._piece_order + 1] = piece
    while #self._piece_order > PIECE_CACHE_MAX do
        local oldest = table.remove(self._piece_order, 1)
        local p = self._piece_cache[oldest]
        if p then
            if p.tb then p.tb:free() end
            self._piece_cache[oldest] = nil
        end
    end
end

--- LRU touch: move the hit piece to the end (keeps it hot).
function ThoughtPopupWidget:_touchPiece(piece)
    local order = self._piece_order
    if not order then return end
    for i, k in ipairs(order) do
        if k == piece then
            table.remove(order, i)
            break
        end
    end
    order[#order + 1] = piece
end

--- Free the whole piece cache (layout switch / cleanup).
function ThoughtPopupWidget:_freePieceCache()
    for _, p in pairs(self._piece_cache or {}) do
        if p.tb then p.tb:free() end
    end
    self._piece_cache = {}
    self._piece_order = {}
end

--- Render page n on demand (page bitmap LRU cache).
function ThoughtPopupWidget:_renderPage(n)
    if self._page_bbs[n] then return self._page_bbs[n] end
    local scroll = self._scroll_container
    local pages = scroll and scroll.pages
    if not pages or n < 1 or n > #pages then return nil end
    local p0 = pages[n]
    local p1 = pages[n + 1] or self._content_h
    local h = math.max(1, p1 - p0)
    local bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local bb = Blitbuffer.new(self._text_w, h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    for _, piece in ipairs(self._layout.pieces) do
        local r = Paginator.pieceVisibleRange(piece, p0, p1)
        if r then
            local tb = self:_getPieceTB(piece)
            if tb then
                bb:blitFrom(tb._bb, piece.x, r.dest_y, 0, r.src_y, piece.width, r.src_h)
            else
                logger.warn("thought popup textbox render failed:",
                    "y=", piece.y, "n_lines=", piece.n_lines,
                    "text=", tostring(piece.text):sub(1, 40))
            end
        end
    end

    self._page_bbs[n] = bb
    -- LRU: cap the page bitmap cache.
    self._page_order = self._page_order or {}
    for i, k in ipairs(self._page_order) do
        if k == n then table.remove(self._page_order, i) break end
    end
    self._page_order[#self._page_order + 1] = n
    while #self._page_order > PAGE_BB_CACHE_MAX do
        local oldest = table.remove(self._page_order, 1)
        local old_bb = self._page_bbs[oldest]
        if old_bb and old_bb.free then old_bb:free() end
        self._page_bbs[oldest] = nil
    end
    return bb
end

--- Free all page bitmaps (layout change / cleanup).
function ThoughtPopupWidget:_freePageBBs()
    for _, bb in pairs(self._page_bbs or {}) do
        if bb.free then bb:free() end
    end
    self._page_bbs = {}
    self._page_order = {}
end

--- Ensure the layout for the current key (with cache reuse).
--- Called only when the layout key (items|geometry) changes (init/_reopen),
--- so the page bitmap cache is unconditionally cleared here: page bitmaps are
--- stored by page index and belong to the previous layout — reusing an old
--- layout without clearing would make _renderPage return the previous
--- content's bitmap for the new layout.
function ThoughtPopupWidget:_ensureLayout()
    self:_freePageBBs()
    self:_freePieceCache()
    local cached = self._layout_cache[self._bb_key]
    if cached then
        self._layout = cached
        self._content_h = cached.content_h
        self._boundaries = cached.boundaries
        self._text_w = cached.text_w
        return
    end
    local layout = self:_paginate()
    self._layout_cache[self._bb_key] = layout
    -- LRU layout cache
    self._layout_order = self._layout_order or {}
    for i, k in ipairs(self._layout_order) do
        if k == self._bb_key then table.remove(self._layout_order, i) break end
    end
    self._layout_order[#self._layout_order + 1] = self._bb_key
    while #self._layout_order > LAYOUT_CACHE_MAX do
        local oldest = table.remove(self._layout_order, 1)
        self._layout_cache[oldest] = nil
    end
    self._layout = layout
    self._content_h = layout.content_h
    self._boundaries = layout.boundaries
    self._text_w = layout.text_w
end

function ThoughtPopupWidget:_buildLayout()
    self:clear()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    -- Reuse _paginate's text_w (stored by _ensureLayout) so the two code paths
    -- cannot drift.
    local text_w = self._text_w

    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local chrome = TOP_BORDER_SIZE + PADDING_TOP + PADDING_BOTTOM
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(18)) * 1.2)

    -- Shrink mode: when the content is shorter than the popup by more than one
    -- text line, shrink the popup to the content height.
    local viewport_h
    if self._content_h + chrome <= ratio_h - blank_tolerance then
        viewport_h = self._content_h
        self.height = self._content_h + chrome
    else
        viewport_h = ratio_h - chrome
        self.height = ratio_h
    end
    if viewport_h < 1 then viewport_h = 1 end

    self._text_w = text_w
    local scroll = ScrollContainer:new{
        content_h = self._content_h,
        viewport_h = viewport_h,
        scrollbar_w = item_width,
        margin_left = self.doc_margins.left,
        text_w = text_w,
        dialog = self.dialog,
        boundaries = self._boundaries,
        page_bb_getter = function(n)
            return self:_renderPage(n)
        end,
    }
    self._scroll_container = scroll

    local vgroup_children = {
        LineWidget:new{
            dimen = Geom:new{ w = self.width, h = TOP_BORDER_SIZE },
        },
        VerticalSpan:new{ width = PADDING_TOP },
        scroll,
        VerticalSpan:new{ width = PADDING_BOTTOM },
    }

    local vgroup = VerticalGroup:new(vgroup_children)

    self.container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        vgroup,
    }

    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        self.container
    }
end

function ThoughtPopupWidget:onCloseWidget()
    UIManager:setDirty(self.dialog, function()
        return "partial", self.container.dimen
    end)
    -- Pooled: closing does not free the content bitmaps (they stay cached for
    -- reuse); resources are freed by _reopen when the content changes or by
    -- M.cleanup at document close.
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback(self.height)
    end
end

function ThoughtPopupWidget:onClose()
    UIManager:close(self)
    return true
end

function ThoughtPopupWidget:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.container.dimen) then
        UIManager:close(self)
    end
    -- Consume every tap. Viewport taps (page turn) were already handled and
    -- consumed by the ScrollContainer before this handler runs; taps landing on
    -- the popup's border/padding strips must not fall through to the reader.
    return true
end

function ThoughtPopupWidget:onSwipeClose(_, ges)
    local BD = require("ui/bidi")
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" or direction == "east" then
        UIManager:close(self)
        return true
    end
    -- north/south inside the viewport are consumed by the ScrollContainer;
    -- on the border/padding strips they must not fall through to the reader
    -- either. Swipes starting outside the popup keep paging the book.
    if ges.pos:intersectWith(self.container.dimen) then
        return true
    end
    return false
end

--- Free the child widget tree (_buildLayout's clear() calls this on every
--- rebuild). Note: only the subtree is freed — the layout/page-bitmap caches
--- must survive here, or a popup currently on screen would lose the bitmaps it
--- is painting from. The caches are released by _freeContentCaches in
--- M.cleanup (document close). Also never call self:clear() from here:
--- WidgetContainer:clear calls free() internally, which would recurse forever.
function ThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

--- Free every layout and page-bitmap cache (M.cleanup only; never while the
--- popup is visible).
function ThoughtPopupWidget:_freeContentCaches()
    self:_freePageBBs()
    self:_freePieceCache()
    self._layout_cache = {}
    self._layout_order = {}
    self._layout = nil
    self._boundaries = nil
end

return ThoughtPopupWidget
