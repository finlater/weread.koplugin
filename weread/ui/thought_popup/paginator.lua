--[[--
Thought popup pagination and validation core (pure logic, no KOReader
widget dependencies, unit-testable standalone).

* paginateLines    Line-count pagination of a text run, using the same xtext
                   makeLine walk as TextBoxWidget's use_xtext split branch;
                   it only shapes, never rasterizes, so line counts, line
                   heights and glyph slack match the rendered TextBoxWidget.
* textPieceMetrics Line height and glyph overhang (matches TextBoxWidget:init).
* computePages     Boundary table -> page start list (never splits a line,
                   plus orphan-line control).
* pieceVisibleRange Visible line slice of a piece inside a page [p0, p1)
                   (render clipping).
* ensureTextBoxBB  Makes sure a text piece's TextBoxWidget has a renderable
                   bitmap.

xtext is required lazily so tests can inject a mock via package.preload.
--]]

local Paginator = {}

local XText

--- Line-count pagination of a text run via the xtext makeLine walk.
--- @param text string
--- @param face table FontFaceObj
--- @param width number line width (px)
--- @return number number of lines
function Paginator.paginateLines(text, face, width)
    if not XText then XText = require("libs/libkoreader-xtext") end
    local xt = XText.new(text, face, false, nil, nil)
    xt:measure()
    local count = 0
    local idx = 1
    local size = #xt -- xtext userdata __len = character count
    while idx and idx <= size do
        local line = xt:makeLine(idx, width, false, nil)
        if line.next_start_offset and line.next_start_offset == line.offset then
            -- Width too small for any character: force one character per line
            -- (same fallback as _splitToLines).
            line.next_start_offset = line.offset + 1
        end
        count = count + 1
        if line.hard_newline_at_eot and not line.next_start_offset then
            -- A trailing hard newline adds one empty line (same as _splitToLines).
            count = count + 1
        end
        idx = line.next_start_offset
    end
    return count
end

--- Line height and glyph overhang of a text fragment (matches TextBoxWidget:init
--- with line_height = 0.2).
--- @param face table FontFaceObj
--- @return number line_h
--- @return number extra glyph overhang folded into the piece height
function Paginator.textPieceMetrics(face)
    local line_h = math.floor((1 + 0.2) * face.size + 0.5) -- Math.round
    local face_height = face.ftsize:getHeightAndAscender()
    local extra = math.max(0, face_height - line_h)
    return line_h, extra
end

--- Page start list computed from a boundary table.
--- A boundary is { top, bottom, keep_prev }: top = line top, bottom = the true
--- line bottom (top + line height, without inter-block slack — using the next
--- boundary as the line bottom would over-count glyph overhang and item gaps
--- and push a fitting last item to the next page; the content end uses
--- content_h for the same reason).
--- A page is the maximal run of lines whose bottoms fit inside the viewport,
--- starting at page_start; the page bottom is the top of the first line that
--- does not fit, so no line is ever split across pages.
--- keep_prev (first line of an item): when the page would end right before the
--- protected line, leaving the item's meta line orphaned at the page bottom,
--- pull the page bottom back one line so the meta line and the content's first
--- line move to the next page together.
--- @param boundaries table[] {top, bottom, keep_prev?}
--- @param viewport_h number
--- @param content_h number
--- @return number[] page start list (first element always 0)
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
        -- Skip boundaries above page_start (the first line of the page is
        -- implicitly included).
        while k <= n and boundaries[k].top < page_start do
            k = k + 1
        end
        -- Advance line by line while the true line bottom fits in the viewport.
        while k <= n do
            local b = boundaries[k]
            if b.bottom - page_start > viewport_h then
                break
            end
            end_y = b.bottom
            k = k + 1
        end
        -- Orphan control: if the page bottom lands right before a protected
        -- line, pull back to the previous line bottom so the protected line
        -- and its meta line stay together on the next page.
        -- Never pull back past page_start: if the protected line already is
        -- the first line of the page, pulling back would move end_y before the
        -- page start and oscillate forever.
        if k <= n and boundaries[k].keep_prev and k - 2 >= 1 then
            local back_y = boundaries[k - 2].bottom
            if back_y > page_start then
                end_y = back_y
                k = k - 1
            end
        end
        if end_y == page_start then
            -- Defensive: the first line itself overflows the viewport, so
            -- advance to the next line top (must skip boundaries with
            -- top <= page_start, or a zero viewport would loop forever).
            while k <= n and boundaries[k].top <= page_start do
                k = k + 1
            end
            if k <= n then
                -- Use that boundary's top as the page bottom but do NOT
                -- advance k: the next page re-checks the boundary's line from
                -- the start (advancing k would lose the tail content when the
                -- overflowing line is followed by more lines).
                end_y = boundaries[k].top
            else
                end_y = content_h
            end
        end
        if k > n then
            -- Content exhausted: the last page is [page_start, content_h);
            -- do not append phantom pages at content_h or trailing slack.
            break
        end
        starts[#starts + 1] = end_y
        i = k
    end
    return starts
end

--- Visible slice of a text piece inside page [p0, p1).
--- @return table|nil {k0, k1, src_y, src_h, dest_y}; nil when invisible.
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

--- Make sure a text piece's TextBoxWidget has a renderable bitmap.
--- On the rare recycled path _bb can be missing; getSize triggers a re-render.
--- @param tb table|nil TextBoxWidget
--- @return table|nil a renderable tb, or nil on failure
function Paginator.ensureTextBoxBB(tb)
    if not tb then return nil end
    if not tb._bb then
        tb:getSize()
    end
    if not tb._bb then return nil end
    return tb
end

return Paginator
