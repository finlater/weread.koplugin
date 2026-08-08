--[[--
Thought popup widget.

Renders review items by shaping each text block with the document font (or a
fallback chain) and paginating once; pages are blitted into a bitmap viewport
that scrolls. Long content scrolls directly, with no button navigation.

Rendering model: pagination runs XText measure/makeLine once; rendering reuses
the same XText to draw piece bitmaps (shapeLine + glyph blit), then composites
pages. Layout/page/piece caches use koreader Cache (ffi/lru slots + onFree).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Cache = require("cache")
local CacheItem = require("cacheitem")
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
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("weread.lib.logger")

local TOP_BORDER_SIZE = Size.line.thick
local PADDING_TOP = Size.padding.large
local PADDING_BOTTOM = Size.padding.large

local PAGE_BB_CACHE_MAX = 8
local PIECE_CACHE_MAX = 200
local LAYOUT_CACHE_MAX = 6

local PieceItem = CacheItem:extend{}
function PieceItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local PageItem = CacheItem:extend{}
function PageItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local LayoutItem = CacheItem:extend{}
function LayoutItem:onFree()
    Paginator.freeTextPieces(self.pieces)
end

local function newPieceCache()
    return Cache:new{ slots = PIECE_CACHE_MAX, enable_eviction_cb = true }
end

local function newPageCache()
    return Cache:new{ slots = PAGE_BB_CACHE_MAX, enable_eviction_cb = true }
end

local function newLayoutCache()
    return Cache:new{ slots = LAYOUT_CACHE_MAX, enable_eviction_cb = true }
end

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

    _layout_cache = nil,
    _page_bbs = nil,
    _page_pieces = nil,
    _piece_cache = nil,
    _bb_key = nil,
    _content_h = 0,
    _text_w = 0,
    _layout = nil,
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

    self._layout_cache = self._layout_cache or newLayoutCache()
    self._page_bbs = self._page_bbs or newPageCache()
    self._piece_cache = self._piece_cache or newPieceCache()
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

function ThoughtPopupWidget:_paginate()
    local t0 = os.clock()
    local blocks = ContentBuilder.build(self.items)
    local t1 = os.clock()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local text_w = Screen:getWidth() - self.doc_margins.left - self.doc_margins.right - item_width
    if text_w < 10 then text_w = 10 end
    local base_size = math.max(8, math.floor(self.doc_font_size or 0))

    local pieces = {}
    local boundaries = {}
    local y = 0

    local function addTextPiece(variant, text, fg, width, x, keep_next)
        local face = FaceFactory:getFace(self.doc_font_name, base_size, variant)
        if not face then return false end
        local line_h, extra, baseline = Paginator.textPieceMetrics(face)
        local paginated = Paginator.paginateText(text, face, width)
        local n_lines = paginated.n_lines
        local piece_h = n_lines * line_h + extra
        local piece_y = y
        pieces[#pieces + 1] = {
            kind = "text", variant = variant, text = text, fg = fg,
            face = face, width = width, x = x, y = piece_y,
            n_lines = n_lines, line_h = line_h, piece_h = piece_h,
            baseline = baseline, xtext = paginated.xtext, lines = paginated.lines,
        }
        if keep_next and n_lines >= 1 then
            boundaries[#boundaries + 1] = {
                top = piece_y,
                bottom = piece_y + piece_h,
                keep_next = true,
            }
        else
            for k = 1, n_lines do
                boundaries[#boundaries + 1] = {
                    top = piece_y + (k - 1) * line_h,
                    bottom = piece_y + k * line_h,
                }
            end
        end
        y = y + piece_h
        return true
    end

    for _, block in ipairs(blocks) do
        if block.kind == "paragraph" then
            addTextPiece(block.variant, block.text, block.fg, text_w, 0,
                block.variant == "meta")
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

function ThoughtPopupWidget:_getPieceTextBB(piece)
    self._piece_cache = self._piece_cache or newPieceCache()
    local cached = self._piece_cache:get(piece)
    if cached then return cached.bb end
    local bb = Paginator.renderTextPiece(piece)
    if not bb then return nil end
    self._piece_cache:insert(piece, PieceItem:new{ bb = bb })
    return bb
end

function ThoughtPopupWidget:_freePieceCache()
    if self._piece_cache and self._piece_cache.clear then
        self._piece_cache:clear()
    else
        self._piece_cache = newPieceCache()
    end
end

function ThoughtPopupWidget:_pagePiecesFor(n)
    if not self._page_pieces then
        local scroll = self._scroll_container
        local pages = scroll and scroll.pages
        local layout_pieces = self._layout and self._layout.pieces
        if pages and layout_pieces then
            self._page_pieces = Paginator.buildPagePieceIndex(layout_pieces, pages, self._content_h)
        else
            self._page_pieces = {}
        end
    end
    return self._page_pieces[n] or {}
end

function ThoughtPopupWidget:_renderPage(n)
    self._page_bbs = self._page_bbs or newPageCache()
    local cached = self._page_bbs:get(n)
    if cached then return cached.bb end
    local scroll = self._scroll_container
    local pages = scroll and scroll.pages
    if not pages or n < 1 or n > #pages then return nil end
    local p0 = pages[n]
    local p1 = pages[n + 1] or self._content_h
    local h = math.max(1, p1 - p0)
    local bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local bb = Blitbuffer.new(self._text_w, h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    for _, piece in ipairs(self:_pagePiecesFor(n)) do
        local r = Paginator.pieceVisibleRange(piece, p0, p1)
        if r and piece.kind == "text" then
            local text_bb = self:_getPieceTextBB(piece)
            if text_bb then
                bb:blitFrom(text_bb, piece.x, r.dest_y, 0, r.src_y, piece.width, r.src_h)
            else
                logger.warn("thought popup text render failed:",
                    "y=", piece.y, "n_lines=", piece.n_lines,
                    "text=", tostring(piece.text):sub(1, 40))
            end
        end
    end

    self._page_bbs:insert(n, PageItem:new{ bb = bb })
    return bb
end

function ThoughtPopupWidget:_freePageBBs()
    if self._page_bbs and self._page_bbs.clear then
        self._page_bbs:clear()
    else
        self._page_bbs = newPageCache()
    end
    self._page_pieces = nil
end

function ThoughtPopupWidget:_ensureLayout()
    self:_freePageBBs()
    self:_freePieceCache()
    self._layout_cache = self._layout_cache or newLayoutCache()
    local cached = self._layout_cache:get(self._bb_key)
    if cached then
        self._layout = cached
        self._content_h = cached.content_h
        self._boundaries = cached.boundaries
        self._text_w = cached.text_w
        return
    end
    local layout = LayoutItem:new(self:_paginate())
    self._layout_cache:insert(self._bb_key, layout)
    self._layout = layout
    self._content_h = layout.content_h
    self._boundaries = layout.boundaries
    self._text_w = layout.text_w
end

function ThoughtPopupWidget:_buildLayout()
    self:clear()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local text_w = self._text_w

    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local chrome = TOP_BORDER_SIZE + PADDING_TOP + PADDING_BOTTOM
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(18)) * 1.2)

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
        page_bb_getter = function(page_idx)
            return self:_renderPage(page_idx)
        end,
    }
    self._scroll_container = scroll
    self._page_pieces = Paginator.buildPagePieceIndex(
        self._layout and self._layout.pieces, scroll.pages, self._content_h)

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
    return true
end

function ThoughtPopupWidget:onSwipeClose(_, ges)
    local BD = require("ui/bidi")
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" or direction == "east" then
        UIManager:close(self)
        return true
    end
    if ges.pos:intersectWith(self.container.dimen) then
        return true
    end
    return false
end

function ThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function ThoughtPopupWidget:_freeContentCaches()
    self:_freePageBBs()
    self:_freePieceCache()
    if self._layout_cache and self._layout_cache.clear then
        self._layout_cache:clear()
    else
        self._layout_cache = newLayoutCache()
    end
    self._layout = nil
    self._boundaries = nil
end

return ThoughtPopupWidget
