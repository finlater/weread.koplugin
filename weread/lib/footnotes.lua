-- Book-footnote conversion for downloaded WeRead XHTML.
--
-- The module is deliberately network-free. Callers scan every pristine chapter
-- before range-based user annotations mutate the markup, build one book-wide
-- anchor index, then transform the finalized chapter bodies cooperatively.

local logger = require("weread.lib.logger").scoped("Footnotes")

local Footnotes = {}

-- Standard endnotes stay readable; the reading system controls their display.
Footnotes.FOOTNOTES_CSS = [[
.wr-fn-ref{font-size:0.75em;vertical-align:super;line-height:0;white-space:nowrap;}
.wr-fn-ref a{position:relative;text-decoration:none;color:#0366d6;}
.wr-fn-ref a::after{content:"";position:absolute;top:-0.5em;right:-0.3em;bottom:-0.5em;left:-0.3em;}
div.wr-footnotes>hr{display:none;}
.wr-fn-num{font-weight:bold;margin-right:0.3em;text-decoration:none;color:inherit;}
div.wr-footnotes{margin-top:1em;padding-top:0.5em;border-top:1px solid #ccc;}
aside.wr-book-footnote{font-size:0.85em;margin:0.5em 0;text-indent:0;}
]]

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
    -- WeRead separates the marker from the note text with a
    -- full-width space (U+2003) or a NBSP; Lua's %s only matches ASCII space,
    -- so the generated note would otherwise start with a stray wide space.
    -- One whole sequence at a time: a byte class here would also match the
    -- 0xE3 lead byte of U+3000-U+3FFF and cut the first byte off kana or CJK
    -- punctuation, leaving invalid UTF-8.
    while true do
        local trimmed = text:gsub("^\194\160", ""):gsub("^\227\128\128", "")
        if trimmed == text then break end
        text = trimmed
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

-- Decode the UTF-8 codepoint starting at byte i; returns the codepoint (nil
-- for a malformed sequence) and the number of bytes consumed.
local function utf8_codepoint(text, i)
    local b = text:byte(i)
    if b < 0x80 then return b, 1 end
    local cp, len
    if b >= 0xC2 and b < 0xE0 then cp, len = b - 0xC0, 2
    elseif b >= 0xE0 and b < 0xF0 then cp, len = b - 0xE0, 3
    elseif b >= 0xF0 and b < 0xF5 then cp, len = b - 0xF0, 4
    else return nil, 1 end
    for j = 1, len - 1 do
        local cb = text:byte(i + j)
        if not cb or cb < 0x80 or cb > 0xBF then return nil, j end
        cp = cp * 64 + (cb - 0x80)
    end
    return cp, len
end

-- Backlink glyphs (↩ ↑ ← ⤴) are pure symbols, yet an element carrying one may
-- share the note target's id; such a capture can never be a definition.
-- Enumerating "known" text scripts instead (the old %w + CJK lead-byte check)
-- silently dropped notes written only in kana, hangul, Cyrillic or any other
-- non-ASCII script, so reject a candidate only when EVERY codepoint it holds
-- is a symbol or punctuation: arrows, dingbats and enclosed numbers
-- (U+2000-U+2FFF), CJK punctuation (U+3000-U+303F), Latin-1 symbols
-- (U+0080-U+00BF), variation selectors and the BOM. Any other codepoint
-- (Latin letters, kana, hangul, CJK, emoji …) counts as note text.
local function is_symbol_only(text)
    local i, n = 1, #text
    while i <= n do
        local cp, len = utf8_codepoint(text, i)
        if not cp then
            i = i + (len or 1)
        elseif cp < 128 then
            if text:sub(i, i):match("%w") then return false end
            i = i + 1
        elseif (cp >= 0x80 and cp <= 0xBF)
            or (cp >= 0x2000 and cp <= 0x2FFF)
            or (cp >= 0x3000 and cp <= 0x303F)
            or (cp >= 0xFE00 and cp <= 0xFE0F)
            or cp == 0xFEFF then
            i = i + len
        else
            return false
        end
    end
    return true
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

-- Is this marker link drawn as a superscript? WeRead writes a
-- citation as `<a href="#note" id="ref"><span class="text-sup">[8]</span></a>`
-- (or `<span class="super"><a …>[8]</a></span>`, i.e. the styling sits on the
-- parent) and the matching note as `<a href="#ref" id="note"><span>[8]</span></a>`.
-- Both ends carry a numeric marker and an intra-document href, so
-- `looks_like_ref` accepts both; the superscript styling is what tells the
-- citation end from the note end. `context` is the raw markup right before the
-- link, used to catch the "styling on the parent" variant.
local function ref_is_superscript(attrs, inner, context)
    inner = tostring(inner or "")
    if inner:find("<[sS][uU][pP]%s*[>/]") then return true end
    for raw_tag in inner:gmatch("<[%a][^>]*>") do
        if (get_attr(raw_tag, "class") or ""):lower():find("sup", 1, true) then
            return true
        end
        if (get_attr(raw_tag, "style") or ""):lower():gsub("%s+", "")
            :find("vertical%-align:super") then
            return true
        end
    end
    local style = (get_attr(attrs, "style") or ""):lower():gsub("%s+", "")
    if style:find("vertical%-align:super", 1) then return true end
    local open_tag = tostring(context or ""):match("<[%a][^>]*>%s*$")
    if open_tag then
        local tag = open_tag:match("^<([%a]+)")
        if tag and tag:lower() == "sup" then return true end
        if (get_attr(open_tag, "class") or ""):lower():find("sup", 1, true) then
            return true
        end
        if (get_attr(open_tag, "style") or ""):lower():gsub("%s+", "")
            :find("vertical%-align:super") then
            return true
        end
    end
    return false
end

local function collect_refs(html)
    html = tostring(html or "")
    local refs = {}
    local init = 1
    while true do
        -- find() instead of gmatch() so the markup before the link is available
        local s, e, attrs, inner = html:find("<[aA]([^>]*)>(.-)</[aA]%s*>", init)
        if not s then break end
        init = e + 1
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
                sup = ref_is_superscript(attrs, inner,
                    html:sub(math.max(1, s - 240), s - 1)),
            }
        end
    end
    return refs
end

local BLOCK_TAGS = { "aside", "li", "p", "div", "section", "blockquote", "dd", "td" }

-- Cap on cleaned note text length in bytes (#text counts bytes, so this is
-- ~2000 CJK chars); genuine notes are far smaller, whole-chapter captures are
-- far larger.
local MAX_NOTE_TEXT_BYTES = 6000

local function remember_definition(definitions, anchor, inner)
    if not anchor or anchor == "" then return end
    local text = clean_note_text(inner)
    if text == "" or is_trivial_note(text) then return end
    if is_symbol_only(text) then return end
    -- Ancestor blocks spanning most of the chapter poison the definition;
    -- reject oversized candidates outright instead of storing them.
    if #text > MAX_NOTE_TEXT_BYTES then
        logger.warn("dropping oversized note candidate:",
            "anchor=", tostring(anchor), "bytes=", tostring(#text))
        return
    end
    local current = definitions[anchor]
    -- The true note content is the smallest region describing the anchor,
    -- so keep whichever candidate has the shortest cleaned text.
    if not current or #text < #current.text then
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
    -- Tell the two ends of a reciprocal footnote pair apart.
    -- `note_targets` holds the anchors cited by superscript marker links (the
    -- real footnotes). A marker link that is itself pointed at by one of them,
    -- and that is not superscripted, is the note end: its own id is what the
    -- citation links to. Keeping those ids out of `forward_ref_ids` is the
    -- whole fix -- otherwise every citation target is also "the id of some
    -- reference", every citation is classified as a backlink, and the chapter
    -- is left with its original (footnote-hint-free) markup.
    local note_targets = {}
    for _i, ref in ipairs(refs) do
        if ref.sup and ref.anchor and ref.anchor ~= "" then
            note_targets[ref.anchor] = true
        end
    end
    local forward_ref_ids, note_end_ids = {}, {}
    for _i, ref in ipairs(refs) do
        if ref.ref_id and ref.ref_id ~= "" then
            if not ref.sup and note_targets[ref.ref_id] then
                note_end_ids[ref.ref_id] = true
                ref.note_end = true
            else
                forward_ref_ids[ref.ref_id] = true
            end
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
        note_end_ids = note_end_ids,
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
        -- A note paragraph may itself cite another note; after
        -- the rewrite above that inner citation is a `.wr-fn-ref` anchor whose
        -- id is the backlink target of its own note. Removing the paragraph
        -- would delete that anchor and leave a dangling backlink, so such
        -- paragraphs are always kept (their note text stays visible in place).
        if inner:find('class="wr%-fn%-ref"') then
            return "<p" .. attrs .. ">" .. inner .. "</p>"
        end
        local consumed = false
        local own_anchor = get_attr(attrs, "id") or get_attr(attrs, "name")
        if own_anchor and converted_anchors[own_anchor] then consumed = true end
        if not consumed
            and (has_token(class, "note") or lower:find("fncontent", 1, true)) then
            for raw_tag in inner:gmatch("<[%a][^>]*>") do
                local anchor = get_attr(raw_tag, "id") or get_attr(raw_tag, "name")
                if anchor and converted_anchors[anchor] then
                    consumed = true
                    break
                end
            end
        end
        -- WeRead keeps the note text in an ordinary paragraph
        -- (`<p class="content"><a href="#ref" id="note">[8]</a> text</p>`) with
        -- no note-ish class. Recognize it by the fact that the paragraph
        -- *starts* with an anchor whose text was consumed as a note; without
        -- this the note would stay in the chapter flow and be shown twice
        -- (once in place, once in the generated note section).
        if not consumed then
            local lead_attrs = inner:match("^%s*<[aA]([^>]*)>")
            if lead_attrs then
                local anchor = get_attr(lead_attrs, "id") or get_attr(lead_attrs, "name")
                if anchor and converted_anchors[anchor] then consumed = true end
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
        -- The note-side marker of a reciprocal pair is not a
        -- citation: leave its downstream markup untouched and let the note
        -- paragraph be removed together with the generated note section.
        local own_id = get_attr(attrs, "id")
        if own_id and scan.note_end_ids and scan.note_end_ids[own_id] then
            stats.backlinks = stats.backlinks + 1
            return "<a" .. attrs .. ">" .. inner .. "</a>"
        end
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
