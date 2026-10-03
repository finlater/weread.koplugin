--[[--
Thought popup pagination and page rendering (shared by both popup positions).

The bottom bar (widget.lua) and the centered dialog (center_widget.lua) render
the same review content with the same fonts and size settings; this module
owns the pipeline they share:

  * one-shot pagination of the review blocks (ContentBuilder + Paginator),
    cached in a koreader Cache keyed by (items, font, margins, height_ratio);
  * per-piece glyph bitmaps (piece cache);
  * lazy page bitmaps (page cache), where a page is a y-slice of the flowing
    content, so a single long thought may span several pages.

Widgets ask for page starts with computePages(viewport_h) and render page
bitmaps on demand with renderPage(page_idx, page_starts). The page -> piece
inverted index is rebuilt whenever the page_starts table changes (i.e. when
the viewport height changes), while layout and piece caches are freed only
when the content or geometry key changes.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Cache = require("cache")
local CacheItem = require("cacheitem")
local ContentBuilder = require("weread.ui.thought_popup.content_builder")
local Device = require("device")
local FaceFactory = require("weread.ui.thought_popup.face_factory")
local Paginator = require("weread.ui.thought_popup.paginator")
local Screen = Device.screen
local logger = require("weread.lib.logger")

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

local function geomKey(doc_font_name, doc_font_size, margins, height_ratio, content_width, contrast)
    local m = margins or {}
    return string.format("%s|%d|%d_%d_%d_%d|%.4f|%d|%d",
        doc_font_name or "", doc_font_size or 0,
        m.left or 0, m.right or 0, m.top or 0, m.bottom or 0,
        height_ratio or 0.35,
        content_width or 0,
        tonumber(contrast) or 0)
end

local PageRenderer = {}

--- @param opts table { items, doc_font_name, doc_font_size, doc_margins,
---                    height_ratio, content_width? }
--- content_width (optional) is the full inner column width before margins
--- (defaults to the screen width, which is what the bottom popup uses; the
--- centered popup passes its narrower frame width).
function PageRenderer:new(opts)
    opts = opts or {}
    local self_obj = setmetatable({}, { __index = PageRenderer })
    self_obj.items = opts.items or {}
    self_obj.doc_font_name = opts.doc_font_name
    self_obj.doc_font_size = opts.doc_font_size or Screen:scaleBySize(18)
    self_obj.doc_margins = opts.doc_margins or {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    }
    self_obj.height_ratio = opts.height_ratio or 0.35
    self_obj.content_width = opts.content_width
    self_obj.contrast = tonumber(opts.contrast) or 0
    self_obj.skip_quote = opts.skip_quote == true
    self_obj.hide_leading_separator = opts.hide_leading_separator == true
    self_obj._layout_cache = newLayoutCache()
    self_obj._page_bbs = newPageCache()
    self_obj._piece_cache = newPieceCache()
    self_obj._items_key = itemsKey(self_obj.items)
    self_obj._geom_key = geomKey(self_obj.doc_font_name, self_obj.doc_font_size,
        self_obj.doc_margins, self_obj.height_ratio, self_obj.content_width,
        self_obj.contrast)
    self_obj._bb_key = self_obj._items_key .. "|" .. self_obj._geom_key
    self_obj._page_pieces = {}
    self_obj._page_pieces_key = nil
    -- Public layout results, refreshed by ensureLayout():
    self_obj.layout = nil
    self_obj.content_h = 0
    self_obj.text_w = 0
    self_obj.boundaries = nil
    return self_obj
end

--- Reload content/geometry; re-layout only when the cache key changed.
--- content_width (optional) is the full inner column width before margins;
--- the centered popup passes its frame width so a width change re-paginates.
--- contrast (optional) shifts every block's gray level; a change re-lays out
--- because the colors are baked into the pieces.
function PageRenderer:setContent(items, doc_font_name, doc_font_size, doc_margins, height_ratio, content_width, contrast)
    self.items = items or {}
    if doc_font_name ~= nil then self.doc_font_name = doc_font_name end
    if doc_font_size ~= nil then self.doc_font_size = doc_font_size end
    if doc_margins ~= nil then self.doc_margins = doc_margins end
    if height_ratio ~= nil then self.height_ratio = height_ratio end
    if content_width ~= nil then self.content_width = content_width end
    if contrast ~= nil then self.contrast = tonumber(contrast) or 0 end
    local new_items_key = itemsKey(self.items)
    local new_geom_key = geomKey(self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.content_width, self.contrast)
    local new_bb_key = new_items_key .. "|" .. new_geom_key
    if new_bb_key ~= self._bb_key then
        self._items_key = new_items_key
        self._geom_key = new_geom_key
        self._bb_key = new_bb_key
        self:ensureLayout()
    end
end

function PageRenderer:paginate()
    local t0 = os.clock()
    local blocks = ContentBuilder.build(self.items, { contrast = self.contrast, skip_quote = self.skip_quote })
    local t1 = os.clock()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local inner_w = self.content_width or Screen:getWidth()
    local text_w = inner_w - self.doc_margins.left - self.doc_margins.right - item_width
    if text_w < 10 then text_w = 10 end
    local base_size = math.max(8, math.floor(self.doc_font_size or 0))

    local pieces = {}
    local boundaries = {}
    local y = 0

    local function textPiece(variant, text, fg, width, x)
        local face = FaceFactory:getFace(self.doc_font_name, base_size, variant)
        if not face then return nil end
        local line_h, extra, baseline = Paginator.textPieceMetrics(face)
        local paginated = Paginator.paginateText(text, face, width)
        local n_lines = paginated.n_lines
        local piece_h = n_lines * line_h + extra
        return {
            kind = "text", variant = variant, text = text, fg = fg,
            face = face, width = width, x = x, y = y,
            n_lines = n_lines, line_h = line_h, piece_h = piece_h,
            baseline = baseline, xtext = paginated.xtext, lines = paginated.lines,
        }
    end

    local header_top
    for _, block in ipairs(blocks) do
        if block.kind == "separator" then
            -- Keep the rule and its whitespace with the following author row.
            header_top = y
            y = y + math.floor(base_size * block.spacing_before + 0.5)
            local thickness = math.max(1, Screen:scaleBySize(1))
            pieces[#pieces + 1] = {
                kind = "separator", fg = block.fg, x = 0, y = y,
                width = text_w, piece_h = thickness,
            }
            y = y + thickness + math.floor(base_size * block.spacing_after + 0.5)
        elseif block.variant == "meta" then
            local author_width = text_w
            -- Reserve space for likes before wrapping a long username. Each
            -- column is bounded even in a narrow popup or with a large count.
            local likes
            if block.likes_text then
                likes = textPiece("likes", block.likes_text, block.likes_fg,
                    math.max(1, math.floor(text_w * 0.4)), 0)
                if likes then
                    local width = 0
                    for _, line in ipairs(likes.lines) do
                        width = math.max(width, line.width or 0)
                    end
                    likes.width = math.max(1, math.min(likes.width, math.ceil(width)))
                    likes.x = text_w - likes.width
                    likes.align = "right"
                    author_width = math.max(1, likes.x - math.floor(base_size * 0.6 + 0.5))
                end
            end
            local author = textPiece("meta", block.text, block.fg, author_width, 0)
            local row_h = author and author.piece_h or 0
            -- Long-press lookup uses meta to identify the start of a thought.
            if author then pieces[#pieces + 1] = author end
            if likes then
                if author then
                    likes.y = y + math.max(0, author.baseline - likes.baseline)
                end
                row_h = math.max(row_h, likes.y - y + likes.piece_h)
                pieces[#pieces + 1] = likes
            end
            boundaries[#boundaries + 1] = {
                top = header_top or y,
                bottom = y + row_h,
                keep_next = true,
            }
            header_top = nil
            y = y + row_h + math.floor(base_size * block.spacing_after + 0.5)
        elseif block.kind == "paragraph" then
            local piece = textPiece(block.variant, block.text, block.fg, text_w, 0)
            if piece then
                pieces[#pieces + 1] = piece
                for k = 1, piece.n_lines do
                    boundaries[#boundaries + 1] = {
                        top = y + (k - 1) * piece.line_h,
                        bottom = y + k * piece.line_h,
                    }
                end
                y = y + piece.piece_h
            end
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

--- (Re)build the layout: free stale page bitmaps, load the cached layout or
--- paginate. Idempotent; call once after construction / setContent.
function PageRenderer:ensureLayout()
    self:_freePageBBs()
    self:_freePieceCache()
    self._layout_cache = self._layout_cache or newLayoutCache()
    local cached = self._layout_cache:get(self._bb_key)
    if cached then
        self.layout = cached
        self.content_h = cached.content_h
        self.boundaries = cached.boundaries
        self.text_w = cached.text_w
        return
    end
    local layout = LayoutItem:new(self:paginate())
    self._layout_cache:insert(self._bb_key, layout)
    self.layout = layout
    self.content_h = layout.content_h
    self.boundaries = layout.boundaries
    self.text_w = layout.text_w
end

--- Page start list for a viewport height (pure logic, see paginator.lua).
--- Always contains at least { 0 }.
function PageRenderer:computePages(viewport_h)
    return Paginator.computePages(self.boundaries, viewport_h, self.content_h)
end

function PageRenderer:_getPieceTextBB(piece)
    self._piece_cache = self._piece_cache or newPieceCache()
    local cached = self._piece_cache:get(piece)
    if cached then return cached.bb end
    local bb = Paginator.renderTextPiece(piece)
    if not bb then return nil end
    self._piece_cache:insert(piece, PieceItem:new{ bb = bb })
    return bb
end

function PageRenderer:_freePieceCache()
    if self._piece_cache and self._piece_cache.clear then
        self._piece_cache:clear()
    else
        self._piece_cache = newPieceCache()
    end
end

--- Original content coordinate at the top of a rendered page. Centered
--- pages drop leading separators AND their spacing; painting and long-press
--- lookup must use the same origin. Continuous scrolling keeps every pixel.
function PageRenderer:getPageContentStart(page_idx, page_starts)
    if self._page_pieces_key ~= page_starts then
        self:_freePageBBs()
        self._page_pieces = Paginator.buildPagePieceIndex(
            self.layout and self.layout.pieces, page_starts, self.content_h)
        self._page_pieces_key = page_starts
    end
    local p0 = page_starts[page_idx]
    if self.hide_leading_separator then
        local p1 = page_starts[page_idx + 1] or self.content_h
        for _, piece in ipairs(self._page_pieces[page_idx] or {}) do
            if piece.kind ~= "separator" then
                local r = Paginator.pieceVisibleRange(piece, p0, p1)
                if r then return p0 + r.dest_y end
            end
        end
    end
    return p0
end

--- Render (and cache) the bitmap of page page_idx within page_starts.
function PageRenderer:renderPage(page_idx, page_starts)
    if not page_starts or page_idx < 1 or page_idx > #page_starts then return nil end
    local p0 = self:getPageContentStart(page_idx, page_starts)
    self._page_bbs = self._page_bbs or newPageCache()
    local cached = self._page_bbs:get(page_idx)
    if cached then return cached.bb end
    local p1 = page_starts[page_idx + 1] or self.content_h
    local h = math.max(1, p1 - p0)
    local bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local bb = Blitbuffer.new(self.text_w, h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    local has_text = false
    for _, piece in ipairs(self._page_pieces[page_idx] or {}) do
        if piece.kind == "separator" then
            -- A separator is only useful between thoughts visible on this
            -- page. Keep it in continuous-scroll bitmaps, whose page seams
            -- can appear in the middle of the viewport while panning.
            if has_text or not self.hide_leading_separator then
                local top = math.max(piece.y, p0)
                local bottom = math.min(piece.y + piece.piece_h, p1)
                bb:paintRect(piece.x, top - p0, piece.width, bottom - top, piece.fg)
            end
        else
            local r = Paginator.pieceVisibleRange(piece, p0, p1)
            if r then
                has_text = true
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
    end

    self._page_bbs:insert(page_idx, PageItem:new{ bb = bb })
    return bb
end

function PageRenderer:_freePageBBs()
    if self._page_bbs and self._page_bbs.clear then
        self._page_bbs:clear()
    else
        self._page_bbs = newPageCache()
    end
    self._page_pieces = {}
    self._page_pieces_key = nil
end

--- Drop every cached bitmap and layout (called on document close / position
--- switch); the next use re-paginates from scratch.
function PageRenderer:freeContentCaches()
    self:_freePageBBs()
    self:_freePieceCache()
    if self._layout_cache and self._layout_cache.clear then
        self._layout_cache:clear()
    else
        self._layout_cache = newLayoutCache()
    end
    self.layout = nil
    self.boundaries = nil
end

return PageRenderer
