--[[--
Thought popup pagination and validation core (pure logic, unit-testable).

* paginateText     xtext measure + makeLine; returns reusable XText/lines.
* paginateLines    compatibility wrapper: line count only (frees temp XText).
* textPieceMetrics line height / glyph overhang / baseline.
* renderTextPiece  rasterize a piece from cached XText (shapeLine + glyph blit).
* freeTextPieces   release XText attached to pieces (layout cache eviction).
* computePages     boundary table -> page starts (no line splits + orphan control).
* buildPagePieceIndex  page -> piece inverted index (util.bsearch_*, O(P log N)).
* pieceVisibleRange visible line slice inside page [p0, p1).

xtext / blitbuffer / rendertext are lazy-required; tests can inject mocks via
package.preload.
--]]

local util = require("util")

local Paginator = {}

local XText
local Blitbuffer
local RenderText
local Screen

local function ensureXText()
    if not XText then XText = require("libs/libkoreader-xtext") end
    return XText
end

local function ensureRenderDeps()
    if not Blitbuffer then Blitbuffer = require("ffi/blitbuffer") end
    if not RenderText then RenderText = require("ui/rendertext") end
    if not Screen then Screen = require("device").screen end
end

local function freeXText(xt)
    if not xt then return end
    pcall(function() xt:free() end)
end

--- Paginate once: measure + makeLine, returning XText reusable for rendering.
--- @return table { xtext, lines, n_lines }
function Paginator.paginateText(text, face, width)
    ensureXText()
    local xt = XText.new(text or "", face, false, nil, nil)
    xt:measure()
    local lines = {}
    local idx = 1
    local size = #xt
    while idx and idx <= size do
        local line = xt:makeLine(idx, width, false, nil)
        if line.next_start_offset and line.next_start_offset == line.offset then
            line.next_start_offset = line.offset + 1
            line.width = width
        end
        lines[#lines + 1] = line
        if line.hard_newline_at_eot and not line.next_start_offset then
            lines[#lines + 1] = {
                offset = size + 1,
                end_offset = nil,
                width = 0,
                targeted_width = width,
            }
        end
        idx = line.next_start_offset
    end
    return {
        xtext = xt,
        lines = lines,
        n_lines = #lines,
    }
end

--- Line-count pagination (compat wrapper; frees temporary XText).
function Paginator.paginateLines(text, face, width)
    local result = Paginator.paginateText(text, face, width)
    freeXText(result.xtext)
    return result.n_lines
end

--- Line height, glyph overhang, and first-line baseline (line_height = 0.2).
function Paginator.textPieceMetrics(face)
    local line_h = math.floor((1 + 0.2) * face.size + 0.5)
    local face_height, face_ascender = face.ftsize:getHeightAndAscender()
    local extra = math.max(0, face_height - line_h)
    local line_heights_diff = math.floor(line_h - face_height)
    local baseline
    if line_heights_diff >= 0 then
        baseline = math.floor(face_ascender + line_heights_diff / 2)
    else
        baseline = math.floor(face_ascender)
    end
    return line_h, extra, baseline
end

local function shapeLineCached(xtext, line)
    if line._shaped then return end
    line._shaped = true
    if not line.end_offset or line.end_offset < line.offset then
        line.xglyphs = nil
        return
    end
    local xshaping = xtext:shapeLine(line.offset, line.end_offset)
    local alignment = xshaping.para_is_rtl and "right" or "left"
    local targeted = line.targeted_width or line.width or 0
    local pen_x = 0
    if alignment == "right" then
        pen_x = (targeted - (line.width or xshaping.width or 0))
    elseif alignment == "center" then
        pen_x = (targeted - (line.width or xshaping.width or 0)) / 2
    end
    line.x_start = pen_x
    for _, xglyph in ipairs(xshaping) do
        xglyph.x0 = pen_x
        pen_x = pen_x + xglyph.x_advance
        xglyph.x1 = pen_x
        xglyph.w = xglyph.x1 - xglyph.x0
        if xglyph.is_tab then
            xglyph.no_drawing = true
        end
    end
    line.x_end = pen_x
    line.xglyphs = xshaping
    line.para_is_rtl = xshaping.para_is_rtl
end

--- Rasterize a text piece from pagination-cached XText.
function Paginator.renderTextPiece(piece)
    if not piece or not piece.xtext or not piece.lines then return nil end
    if not piece.n_lines or piece.n_lines < 1 then return nil end
    ensureRenderDeps()

    local width = piece.width
    local line_h = piece.line_h
    local h = math.max(1, piece.piece_h or (piece.n_lines * line_h))
    local fgcolor = piece.fg or Blitbuffer.COLOR_BLACK
    local color_fg = not Blitbuffer.isColor8(fgcolor)
    local bbtype = color_fg
        and (Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
        or nil
    local bb = Blitbuffer.new(width, h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    local y = piece.baseline or math.floor(line_h * 0.8)
    local face = piece.face
    for i = 1, #piece.lines do
        local line = piece.lines[i]
        shapeLineCached(piece.xtext, line)
        if line.xglyphs then
            for _, xglyph in ipairs(line.xglyphs) do
                if not xglyph.no_drawing then
                    local glyph_face = face.getFallbackFont(xglyph.font_num)
                    if glyph_face then
                        local glyph = RenderText:getGlyphByIndex(glyph_face, xglyph.glyph, false, false)
                        if glyph and glyph.bb then
                            local dx = xglyph.x0 + glyph.l + xglyph.x_offset
                            local dy = y - glyph.t - xglyph.y_offset
                            if not color_fg then
                                bb:colorblitFrom(glyph.bb, dx, dy, 0, 0,
                                    glyph.bb:getWidth(), glyph.bb:getHeight(), fgcolor)
                            else
                                bb:colorblitFromRGB32(glyph.bb, dx, dy, 0, 0,
                                    glyph.bb:getWidth(), glyph.bb:getHeight(), fgcolor)
                            end
                        end
                    end
                end
            end
        end
        y = y + line_h
    end
    return bb
end

--- Release XText attached to layout pieces (layout cache eviction / cleanup).
function Paginator.freeTextPieces(pieces)
    if not pieces then return end
    for _, piece in ipairs(pieces) do
        if piece.xtext then
            freeXText(piece.xtext)
            piece.xtext = nil
        end
        piece.lines = nil
    end
end

--- Page start list from a boundary table.
--- Boundary = { top, bottom, keep_next? }: bottom is the true line bottom
--- (top + line height, without inter-block slack).
--- keep_next (author meta line): when the page bottom lands after an atomic
--- author boundary, pull back so the author line is not orphaned at page end.
function Paginator.computePages(boundaries, viewport_h, content_h)
    local n = boundaries and #boundaries or 0
    local starts = { 0 }
    if n == 0 or viewport_h <= 0 then
        return starts
    end
    local i = 1
    while i <= n do
        local page_start = starts[#starts]
        local end_y = page_start
        local k = i
        while k <= n and boundaries[k].top < page_start do
            k = k + 1
        end
        while k <= n do
            local b = boundaries[k]
            if b.bottom - page_start > viewport_h then
                break
            end
            end_y = b.bottom
            k = k + 1
        end
        if k <= n and k >= 2 and boundaries[k - 1].keep_next and k - 2 >= 1 then
            local back_y = boundaries[k - 2].bottom
            if back_y > page_start then
                end_y = back_y
                k = k - 1
            end
        end
        if end_y == page_start then
            while k <= n and boundaries[k].top <= page_start do
                k = k + 1
            end
            if k <= n then
                end_y = boundaries[k].top
            else
                end_y = content_h
            end
        end
        if k > n then
            break
        end
        starts[#starts + 1] = end_y
        i = k
    end
    return starts
end

--- Inverted index: page -> pieces spanning that page (O(pieces * log pages)).
function Paginator.buildPagePieceIndex(pieces, pages, _content_h)
    local n_pages = pages and #pages or 0
    local index = {}
    for i = 1, n_pages do
        index[i] = {}
    end
    if n_pages == 0 or not pieces or #pieces == 0 then
        return index
    end

    for _, piece in ipairs(pieces) do
        local y0 = piece.y or 0
        local y1 = y0 + (piece.piece_h or 0)
        if y1 > y0 then
            local first = util.bsearch_right(pages, y0) - 1
            if first < 1 then first = 1 end
            local last = util.bsearch_left(pages, y1) - 1
            if first <= last then
                for page_idx = first, last do
                    local bucket = index[page_idx]
                    bucket[#bucket + 1] = piece
                end
            end
        end
    end
    return index
end

function Paginator.pieceVisibleRange(piece, p0, p1)
    local ptop = math.max(p0, piece.y)
    local pbot = math.min(p1, piece.y + piece.piece_h)
    if pbot <= ptop then return nil end

    local k0 = math.max(0, math.floor((ptop - piece.y) / piece.line_h))
    local k1 = math.min(piece.n_lines - 1,
        math.ceil((pbot - piece.y) / piece.line_h) - 1)
    if k1 < k0 then return nil end

    return {
        k0 = k0,
        k1 = k1,
        src_y = k0 * piece.line_h,
        src_h = (k1 - k0 + 1) * piece.line_h,
        dest_y = ptop - p0,
    }
end

return Paginator
