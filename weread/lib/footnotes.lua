-- Book-footnote conversion for downloaded WeRead XHTML.
--
-- The module is deliberately network-free. Callers scan every pristine chapter
-- before range-based user annotations mutate the markup, build one book-wide
-- anchor index, then transform the finalized chapter bodies cooperatively.

local logger = require("weread.lib.logger").scoped("Footnotes")

local Footnotes = {}

local FOOTNOTE_REFERENCE_CSS = [[
.wr-fn-ref{font-size:0.75em;vertical-align:super;line-height:0;white-space:nowrap;}
.wr-fn-ref a{-cr-hint:noteref;position:relative;text-decoration:none;color:#0366d6;}
.wr-fn-ref a::after{content:"";position:absolute;top:-0.5em;right:-0.3em;bottom:-0.5em;left:-0.3em;}
div.wr-footnotes{margin:0;padding:0;border:0;}
div.wr-footnotes>hr{display:none;}
.wr-fn-num{font-weight:bold;margin-right:0.3em;text-decoration:none;color:inherit;}
]]

Footnotes.IN_PAGE_CSS = FOOTNOTE_REFERENCE_CSS .. [[
/* Render each generated note at the bottom of the page that references it,
 * like KOReader's built-in "In-page EPUB footnotes" tweak (ON by default). */
aside.wr-book-footnote{-cr-hint:footnote-inpage;font-size:0.85em;margin:0!important;}
]]

Footnotes.POPUP_CSS = FOOTNOTE_REFERENCE_CSS .. [[
/* Keep a zero-height rendered block so CREngine can extract exactly one note
 * when KOReader's footnote-link popup option is enabled. */
aside.wr-book-footnote{-cr-hint:footnote;display:block!important;visibility:hidden;height:0!important;max-height:0!important;overflow:hidden!important;margin:0!important;padding:0!important;border:0!important;font-size:0!important;line-height:0!important;text-indent:0!important;}
aside.wr-book-footnote *{margin:0!important;padding:0!important;font-size:0!important;line-height:0!important;}
]]

-- Retain the historical constant as the default download behavior.
Footnotes.FOOTNOTES_CSS = Footnotes.IN_PAGE_CSS

function Footnotes.get_css(use_popup)
    return use_popup == true and Footnotes.POPUP_CSS or Footnotes.IN_PAGE_CSS
end

local function xml_escape(value)
    return (tostring(value or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function decode_entities(value)
    value = tostring(value or "")
    value = value:gsub("&nbsp;", " "):gsub("&#160;", " "):gsub("&#x[Aa]0;", " ")
    value = value:gsub("&amp;", "&"):gsub("&#38;", "&")
    value = value:gsub("&lt;", "<"):gsub("&gt;", ">")
    value = value:gsub("&quot;", '"'):gsub("&#34;", '"')
    value = value:gsub("&apos;", "'"):gsub("&#39;", "'")
    return value
end

local function get_attr(raw, name)
    raw = tostring(raw or "")
    local escaped = tostring(name or ""):gsub("([^%w])", "%%%1")
    return raw:match('^%s*' .. escaped .. '%s*=%s*"([^"]*)"')
        or raw:match('%s+' .. escaped .. '%s*=%s*"([^"]*)"')
        or raw:match("^%s*" .. escaped .. "%s*=%s*'([^']*)'")
        or raw:match("%s+" .. escaped .. "%s*=%s*'([^']*)'")
end

local function has_token(value, token)
    local padded = " " .. tostring(value or ""):lower():gsub("%s+", " ") .. " "
    return padded:find(" " .. tostring(token):lower() .. " ", 1, true) ~= nil
end

local function strip_tags(value)
    value = tostring(value or "")
    value = value:gsub("<[bB][rR]%s*/?>", " ")
    value = value:gsub("</[pP]%s*>", " "):gsub("</[dD][iI][vV]%s*>", " ")
    value = value:gsub("<[^>]+>", " ")
    value = decode_entities(value)
    value = value:gsub("\226\128\139", ""):gsub("\226\128\140", ""):gsub("\226\128\141", "")
    return value:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

local function clean_note_text(value)
    local text = strip_tags(value)
    text = text:gsub("^%[%s*%d+%s*%]%s*", "")
    text = text:gsub("^%(%s*%d+%s*%)%s*", "")
    text = text:gsub("^（%s*%d+%s*）%s*", "")
    text = text:gsub("^%*+%s*", "")
    for _i, marker in ipairs({ "†", "‡", "※" }) do
        if text:sub(1, #marker) == marker then
            text = text:sub(#marker + 1):gsub("^%s*", "")
            break
        end
    end
    return text:match("^%s*(.-)%s*$") or ""
end

local function is_symbol_marker(text)
    return text:match("^%*+$") ~= nil
        or text == "†" or text == "‡" or text == "※"
end

local function is_trivial_note(value)
    local text = strip_tags(value):gsub("%s+", "")
    if text == "" then return true end
    return text:match("^%[%d+%]$") ~= nil
        or text:match("^%d+$") ~= nil
        or text:match("^%(%d+%)$") ~= nil
        or text:match("^（%d+）$") ~= nil
        or is_symbol_marker(text)
end

local function normalize_path(value)
    value = decode_entities(value):gsub("\\", "/")
    value = value:match("^%s*(.-)%s*$") or ""
    value = value:gsub("^/+", "")
    local parts = {}
    for part in value:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/"):lower()
end

local function basename(value)
    return tostring(value or ""):gsub("\\", "/"):match("([^/]+)$") or ""
end

local function split_href(value)
    value = decode_entities(value):match("^%s*(.-)%s*$") or ""
    local file, anchor = value:match("^(.-)#(.+)$")
    if not anchor or anchor == "" then return nil, nil end
    anchor = anchor:gsub("%%([%x][%x])", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return normalize_path(file or ""), anchor
end

local function ref_key(file, anchor)
    file = normalize_path(file)
    if file == "" then return tostring(anchor or "") end
    return file .. "#" .. tostring(anchor or "")
end

local function safe_id(value)
    value = tostring(value or "chapter"):gsub("[^%w_.-]", "_")
    if value == "" then return "chapter" end
    return value
end

local function ref_display(inner)
    local text = strip_tags(inner)
    if text == "" then return "*" end
    return text
end

local function looks_like_ref(attrs, href, inner)
    local file, anchor = split_href(href)
    if not anchor then return false end
    local lower_anchor = anchor:lower()
    if lower_anchor:find("wrthought-", 1, true) == 1
        or lower_anchor:find("thought_", 1, true) == 1
        or lower_anchor:find("wrfn-", 1, true) == 1
        or lower_anchor:find("wrfnref-", 1, true) == 1 then
        return false
    end

    local epub_type = (get_attr(attrs, "epub:type") or ""):lower()
    local role = (get_attr(attrs, "role") or ""):lower()
    local class = (get_attr(attrs, "class") or ""):lower()
    if epub_type:find("backlink", 1, true) or role:find("doc-backlink", 1, true)
        or class:find("backlink", 1, true) or class:find("backref", 1, true)
        or class:find("footnote-back", 1, true) or class:find("note-back", 1, true) then
        return false
    end
    if epub_type:find("noteref", 1, true) or role:find("doc-noteref", 1, true)
        or class:find("noteref", 1, true) or class:find("footnote", 1, true)
        or class:find("fn-ref", 1, true) then
        return true
    end

    local compact = strip_tags(inner):gsub("%s+", "")
    local marker = compact:match("^%[?%d+%]?$")
        or compact:match("^%(%d+%)$")
        or compact:match("^（%d+）$")
        or is_symbol_marker(compact)
    local normalized_file = tostring(file or "")
    local file_hint = normalized_file:find("note", 1, true)
        or normalized_file:match("%.x?html$")
    local anchor_hint = lower_anchor:find("note", 1, true)
        or lower_anchor:find("foot", 1, true)
        or lower_anchor:match("^fn[_%-]?%d+")
        or lower_anchor:match("^n[_%-]?%d+")
        or lower_anchor:match("^ref[_%-]?%d+")
    return marker and (file == "" or file_hint or anchor_hint) and true or false
end

local function collect_refs(html)
    local refs = {}
    for attrs, inner in tostring(html or ""):gmatch("<[aA]([^>]*)>(.-)</[aA]%s*>") do
        local href = get_attr(attrs, "href")
        if href and looks_like_ref(attrs, href, inner) then
            local file, anchor = split_href(href)
            refs[#refs + 1] = {
                href = href,
                file = file,
                anchor = anchor,
                key = ref_key(file, anchor),
                ref_id = get_attr(attrs, "id"),
                display = ref_display(inner),
            }
        end
    end
    return refs
end

local BLOCK_TAGS = { "aside", "li", "p", "div", "section", "blockquote", "dd", "td" }

local function remember_definition(definitions, anchor, inner)
    if not anchor or anchor == "" or definitions[anchor] then return end
    local text = clean_note_text(inner)
    if text ~= "" and not is_trivial_note(text) then
        definitions[anchor] = { text = text }
    end
end

local function collect_definitions(html)
    local definitions = {}
    html = tostring(html or "")
    for _i, tag in ipairs(BLOCK_TAGS) do
        local patterns = {
            "<" .. tag .. "([^>]*)>(.-)</" .. tag .. "%s*>",
            "<" .. tag:upper() .. "([^>]*)>(.-)</" .. tag:upper() .. "%s*>",
        }
        for _j, pattern in ipairs(patterns) do
            for attrs, inner in html:gmatch(pattern) do
                remember_definition(definitions,
                    get_attr(attrs, "id") or get_attr(attrs, "name"), inner)
                for raw_tag in inner:gmatch("<[%a][^>]*>") do
                    remember_definition(definitions,
                        get_attr(raw_tag, "id") or get_attr(raw_tag, "name"), inner)
                end
            end
        end
    end
    for attrs, inner in html:gmatch("<[aA]([^>]*)>(.-)</[aA]%s*>") do
        remember_definition(definitions,
            get_attr(attrs, "id") or get_attr(attrs, "name"), inner)
    end
    -- A common tail-note layout places an empty named anchor immediately
    -- before the paragraph containing the actual note text.
    for attrs, inner in html:gmatch(
        "<[aA]([^>]*)>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]%s*>") do
        remember_definition(definitions,
            get_attr(attrs, "id") or get_attr(attrs, "name"), inner)
    end
    return definitions
end

local function collect_anchor_presence(html)
    local anchors = {}
    for raw_tag in tostring(html or ""):gmatch("<[%a][^>]*>") do
        local anchor = get_attr(raw_tag, "id") or get_attr(raw_tag, "name")
        if anchor and anchor ~= "" then anchors[anchor] = true end
    end
    return anchors
end

local function collect_definition_backlinks(html)
    local backlinks = {}
    for attrs, inner in tostring(html or ""):gmatch("<[pP]([^>]*)>(.-)</[pP]%s*>") do
        local class = get_attr(attrs, "class") or ""
        local lower = class:lower()
        if has_token(class, "note") or lower:find("fncontent", 1, true) then
            for link_attrs, link_inner in inner:gmatch("<[aA]([^>]*)>(.-)</[aA]%s*>") do
                local href = get_attr(link_attrs, "href")
                if href and looks_like_ref(link_attrs, href, link_inner) then
                    local _, anchor = split_href(href)
                    if anchor then backlinks[anchor] = true end
                end
            end
        end
    end
    return backlinks
end

local function chapter_uid(chapter)
    return tostring(chapter and (chapter.chapterUid or chapter.uid) or "")
end

local function chapter_aliases(chapter)
    local aliases, seen = {}, {}
    local function add(value)
        local path = normalize_path(value)
        if path ~= "" and not seen[path] then
            seen[path] = true
            aliases[#aliases + 1] = path
            local base = basename(path)
            if base ~= "" and not seen[base] then
                seen[base] = true
                aliases[#aliases + 1] = base
            end
        end
    end
    if type(chapter) ~= "table" then return aliases end
    for _i, key in ipairs({ "href", "file", "filename", "fileName", "path", "chapterPath" }) do
        add(chapter[key])
    end
    for _i, value in ipairs(chapter.files or {}) do add(value) end
    local idx = tonumber(chapter.chapterIdx or chapter.index)
    if idx then
        add(string.format("chapter%d.xhtml", idx))
        add(string.format("text/chapter%d.xhtml", idx))
    end
    return aliases
end

function Footnotes.scan_chapter(html, chapter)
    local refs = collect_refs(html)
    local forward_ref_ids = {}
    for _i, ref in ipairs(refs) do
        if ref.ref_id and ref.ref_id ~= "" then
            forward_ref_ids[ref.ref_id] = true
        end
    end
    return {
        chapter_uid = chapter_uid(chapter),
        chapter = chapter,
        definitions = collect_definitions(html),
        anchors = collect_anchor_presence(html),
        definition_backlinks = collect_definition_backlinks(html),
        refs = refs,
        forward_ref_ids = forward_ref_ids,
    }
end

local function put_exact(index, key, content)
    local existing = index.exact[key]
    if existing == nil then
        index.exact[key] = content
    elseif existing ~= content then
        index.exact[key] = false
    end
end

function Footnotes.build_book_index(scans, chapters)
    local index = {
        exact = {},
        local_by_uid = {},
        unique = {},
        ambiguous = {},
    }
    local chapter_by_uid = {}
    for _i, chapter in ipairs(chapters or {}) do
        chapter_by_uid[chapter_uid(chapter)] = chapter
    end
    for raw_uid, scan in pairs(scans or {}) do
        local uid = tostring(raw_uid)
        local chapter = scan.chapter or chapter_by_uid[uid]
        index.local_by_uid[uid] = scan.definitions or {}
        local aliases = chapter_aliases(chapter)
        for anchor, content in pairs(scan.definitions or {}) do
            for _i, alias in ipairs(aliases) do
                put_exact(index, ref_key(alias, anchor), content)
            end
            if index.unique[anchor] == nil and not index.ambiguous[anchor] then
                index.unique[anchor] = content
            elseif index.unique[anchor] ~= content then
                index.unique[anchor] = nil
                index.ambiguous[anchor] = true
            end
        end
    end
    return index
end

local function resolve_ref(index, uid, file, anchor)
    if file == "" then
        local local_defs = index.local_by_uid[tostring(uid)] or {}
        if local_defs[anchor] then return local_defs[anchor] end
    else
        local exact = index.exact[ref_key(file, anchor)]
        if exact then return exact end
        local base = basename(file)
        exact = index.exact[ref_key(base, anchor)]
        if exact then return exact end
    end
    return index.unique[anchor]
end

local function image_is_footnote(tag)
    local class = get_attr(tag, "class") or ""
    local lower = class:lower()
    return has_token(class, "qqreader-footnote")
        or has_token(class, "footnote-icon")
        or has_token(class, "footnote-ref")
        or has_token(class, "note-ref")
        or lower == "footnote"
end

local function append_before_body_close(html, fragment)
    if fragment == "" then return html end
    local lower = html:lower()
    -- WeRead may concatenate multiple complete XHTML documents for one
    -- catalog chapter. Append to the final body so all source content stays
    -- before the generated notes.
    local start_pos
    local search_from = 1
    while true do
        local found = lower:find("</body>", search_from, true)
        if not found then break end
        start_pos = found
        search_from = found + 7
    end
    if start_pos then
        return html:sub(1, start_pos - 1) .. fragment .. html:sub(start_pos)
    end
    return html .. fragment
end

local function build_section(notes)
    if #notes == 0 then return "" end
    local out = { '\n<div class="wr-footnotes">\n<hr/>\n' }
    for _i, note in ipairs(notes) do
        out[#out + 1] = string.format(
            '<aside epub:type="footnote" id="%s" class="wr-book-footnote"><p><a href="#%s" class="wr-fn-num">%s</a> %s</p></aside>\n',
            note.target_id, note.ref_id, xml_escape(note.display), xml_escape(note.text))
    end
    out[#out + 1] = "</div>\n"
    return table.concat(out)
end

local function replace_href(attrs, href)
    local escaped = xml_escape(href)
    local replaced, count = attrs:gsub('(href%s*=%s*)"[^"]*"', function(prefix)
        return prefix .. '"' .. escaped .. '"'
    end, 1)
    if count > 0 then return replaced end
    replaced, count = attrs:gsub("(href%s*=%s*)'[^']*'", function(prefix)
        return prefix .. "'" .. escaped .. "'"
    end, 1)
    return count > 0 and replaced or attrs
end

local function strip_consumed_note_blocks(html, converted_anchors)
    local removed = 0
    html = html:gsub("<[pP]([^>]*)>(.-)</[pP]%s*>", function(attrs, inner)
        local class = get_attr(attrs, "class") or ""
        local lower = class:lower()
        if not has_token(class, "note") and not lower:find("fncontent", 1, true) then
            return "<p" .. attrs .. ">" .. inner .. "</p>"
        end
        local consumed = false
        local own_anchor = get_attr(attrs, "id") or get_attr(attrs, "name")
        if own_anchor and converted_anchors[own_anchor] then consumed = true end
        if not consumed then
            for raw_tag in inner:gmatch("<[%a][^>]*>") do
                local anchor = get_attr(raw_tag, "id") or get_attr(raw_tag, "name")
                if anchor and converted_anchors[anchor] then
                    consumed = true
                    break
                end
            end
        end
        if consumed then
            removed = removed + 1
            return ""
        end
        return "<p" .. attrs .. ">" .. inner .. "</p>"
    end)
    return html, removed
end

function Footnotes.transform_chapter(html, scan, index)
    local stats = {
        candidates = 0,
        converted = 0,
        image_notes = 0,
        backlinks = 0,
        removed_note_blocks = 0,
        unresolved = 0,
    }
    if type(html) ~= "string" or html == "" then return html, stats end
    scan = scan or { chapter_uid = "chapter", refs = {}, definitions = {} }
    index = index or Footnotes.build_book_index({ [scan.chapter_uid] = scan }, { scan.chapter })
    local uid = safe_id(scan.chapter_uid)
    local ordinal, notes = 0, {}
    local converted_anchors = {}

    html = html:gsub("(<[iI][mM][gG][^>]*>)", function(tag)
        if not image_is_footnote(tag) then return tag end
        local text = clean_note_text(get_attr(tag, "alt") or get_attr(tag, "title")
            or get_attr(tag, "data-content") or get_attr(tag, "data-note") or "")
        if text == "" then return tag end
        ordinal = ordinal + 1
        local target_id = string.format("wrfn-%s-%d", uid, ordinal)
        local ref_id = string.format("wrfnref-%s-%d", uid, ordinal)
        notes[#notes + 1] = {
            target_id = target_id, ref_id = ref_id,
            display = "[" .. tostring(ordinal) .. "]", text = text,
        }
        stats.image_notes = stats.image_notes + 1
        return string.format(
            '<span class="wr-fn-ref"><a epub:type="noteref" role="doc-noteref" href="#%s" id="%s">[%d]</a></span>',
            target_id, ref_id, ordinal)
    end)

    html = html:gsub("<[aA]([^>]*)>(.-)</[aA]%s*>", function(attrs, inner)
        local href = get_attr(attrs, "href")
        if not href or not looks_like_ref(attrs, href, inner) then
            return "<a" .. attrs .. ">" .. inner .. "</a>"
        end
        stats.candidates = stats.candidates + 1
        local file, anchor = split_href(href)
        if (scan.definition_backlinks and scan.definition_backlinks[anchor])
            or (scan.forward_ref_ids and scan.forward_ref_ids[anchor])
            or (scan.anchors and scan.anchors[anchor]
                and not (scan.definitions and scan.definitions[anchor])) then
            stats.backlinks = stats.backlinks + 1
            return "<a" .. replace_href(attrs, "#" .. anchor) .. ">"
                .. inner .. "</a>"
        end
        local content = resolve_ref(index, scan.chapter_uid, file or "", anchor)
        if not content or is_trivial_note(content.text) then
            if scan.anchors and scan.anchors[anchor] then
                stats.backlinks = stats.backlinks + 1
                return "<a" .. replace_href(attrs, "#" .. anchor) .. ">"
                    .. inner .. "</a>"
            end
            stats.unresolved = stats.unresolved + 1
            return "<a" .. attrs .. ">" .. inner .. "</a>"
        end
        ordinal = ordinal + 1
        local target_id = string.format("wrfn-%s-%d", uid, ordinal)
        local ref_id = string.format("wrfnref-%s-%d", uid, ordinal)
        local display = ref_display(inner)
        notes[#notes + 1] = {
            target_id = target_id, ref_id = ref_id,
            display = display, text = content.text,
        }
        converted_anchors[anchor] = true
        stats.converted = stats.converted + 1
        return string.format(
            '<span class="wr-fn-ref"><a epub:type="noteref" role="doc-noteref" href="#%s" id="%s">%s</a></span>',
            target_id, ref_id, xml_escape(display))
    end)

    html, stats.removed_note_blocks = strip_consumed_note_blocks(html, converted_anchors)
    return append_before_body_close(html, build_section(notes)), stats
end

function Footnotes.validate(html)
    if type(html) ~= "string" then return false, "chapter body is not a string" end
    local ids = {}
    for raw in html:gmatch("<[^>]+>") do
        if not raw:match("^<%s*/") then
            local id = get_attr(raw, "id")
            if id and (id:find("wrfn-", 1, true) == 1 or id:find("wrfnref-", 1, true) == 1) then
                if ids[id] then return false, "duplicate generated footnote id: " .. id end
                ids[id] = true
            end
        end
    end
    for attrs in html:gmatch("<[aA]([^>]*)>") do
        local href = get_attr(attrs, "href")
        local target = href and href:match("^#(wrfn[%w_.-]+)$")
        if target and not ids[target] then
            return false, "missing generated footnote target: " .. target
        end
    end
    return true
end

function Footnotes.has_converted(stats)
    return type(stats) == "table"
        and ((tonumber(stats.converted) or 0) + (tonumber(stats.image_notes) or 0) > 0)
end

function Footnotes.log_stats(stats)
    logger.info("processed:",
        "candidates=", tostring(stats and stats.candidates or 0),
        "converted=", tostring(stats and stats.converted or 0),
        "images=", tostring(stats and stats.image_notes or 0),
        "backlinks=", tostring(stats and stats.backlinks or 0),
        "removed_note_blocks=", tostring(stats and stats.removed_note_blocks or 0),
        "unresolved=", tostring(stats and stats.unresolved or 0))
end

return Footnotes
