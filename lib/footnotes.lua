--[[--
书籍脚注处理：img 注脚、跨文件 Text/*.xhtml 链接 → EPUB3 内联脚注

@module lib.footnotes
--]]--

local ok_json, JSON = pcall(require, "json")
if not ok_json then
    JSON = require("rapidjson")
end

local ffiutil = require("ffi/util")
local ok_logger, logger = pcall(require, "logger")
if not ok_logger then
    logger = nil
end

local LOG_MODULE = "[WeRead]"
local util = require("util")

local Footnotes = {}

Footnotes.FOOTNOTES_CSS = [[
.fn-ref{font-size:0.75em;vertical-align:super;line-height:0;}
.fn-ref a{position:relative;text-decoration:none;color:#0366d6;}
.fn-ref a::after{content:"";position:absolute;top:-0.5em;right:-0.3em;bottom:-0.5em;left:-0.3em;}
aside.footnote{margin:0.5em 0;font-size:0.85em;text-indent:0!important;text-align:left!important;}
div.footnotes{margin-top:2em;padding-top:0.5em;border-top:1px solid #ccc;}
.fn-num{font-weight:bold;margin-right:0.3em;text-decoration:none;color:inherit;}
]]

local TEXT_FOOTNOTE_LINK_SCAN_RE = '<a%s+[^>]-href="[^"]*/Text/[^"]+%.[x]?html#[^"]+"[^>]*>.-</a>'
local LOCAL_HASH_LINK_SCAN_RE = '<a%s+[^>]-href="#[^"]+"[^>]*>.-</a>'
local FOOTNOTE_BLOCK_PATTERNS = {
    '<p[^>]-class="fnContent[^"]*"[^>]->.-</p>',
    '<p[^>]-class="note"[^>]->.-</p>',
}

local BLOCK_PLACEHOLDER_PREFIX = "\029BLOCK"
local BLOCK_PLACEHOLDER_SUFFIX = "\029"

local SECTION_CN = {
    "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
}

local function log_info(...)
    if logger then
        logger.info(LOG_MODULE, ...)
    end
end

local function join_path(a, b)
    return ffiutil.joinPath(a, b)
end

local function ensure_dir(path)
    util.makePath(path)
end

local function sort_chapters(chapters)
    if type(chapters) ~= "table" then
        return {}
    end
    local sorted = {}
    for index, chapter in ipairs(chapters) do
        sorted[index] = chapter
    end
    table.sort(sorted, function(a, b)
        local ia = a.chapterIdx or a.chapterUid or 0
        local ib = b.chapterIdx or b.chapterUid or 0
        return ia < ib
    end)
    return sorted
end

local function find_chapter_by_idx(chapters, idx)
    if type(chapters) ~= "table" or not idx then
        return nil
    end
    for _, chapter in ipairs(chapters) do
        if chapter.chapterIdx == idx then
            return chapter
        end
    end
    return nil
end

local function xml_escape(text)
    return (tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function strip_tags(html)
    return (tostring(html or ""):gsub("<[^>]+>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
end

local function escape_pattern(text)
    return tostring(text or ""):gsub("([%.%-%+%[%]%(%)%$%^%%%?%*])", "%%%1")
end

local function utf8_char_len(str, pos)
    local b = str:byte(pos)
    if not b then return 1 end
    if b < 0x80 then return 1 end
    if b < 0xE0 then return 2 end
    if b < 0xF0 then return 3 end
    return 4
end

--- 字节位置 → 1-based rune 索引（与 annotations.toRunes 一致）。
local function byte_to_rune_index(str, byte_pos)
    local rune_idx = 0
    local i = 1
    while i < byte_pos and i <= #str do
        rune_idx = rune_idx + 1
        i = i + utf8_char_len(str, i)
    end
    return rune_idx + 1
end

local function byte_range_to_rune_range(str, bstart, bend)
    return byte_to_rune_index(str, bstart), byte_to_rune_index(str, bend + 1)
end

local function is_trivial_footnote_text(text)
    if type(text) ~= "string" or text == "" then
        return true
    end
    return text:match("^%[%d+%]$") ~= nil or text:match("^%(%d+%)$") ~= nil
end

local function cleanup_footnote_text(text)
    text = strip_tags(text)
    if text == "" then return "" end
    text = text:gsub("^%[%d+%]%s*", "")
    text = text:gsub("^%(%d+%)%s*", "")
    text = text:gsub("^%*%s*", "")
    return text:match("^%s*(.-)%s*$") or ""
end

local function extract_footnote_num(inner)
    if type(inner) ~= "string" then return nil end
    local text = strip_tags(inner)
    if text == "" then return nil end
    return text:match("^%[(%d+)%]$")
        or text:match("%[(%d+)%]")
        or text:match("^%((%d+)%)$")
        or text:match("%((%d+)%)")
end

local function link_inner_html(link)
    return (tostring(link or ""):match("<a[^>]*>(.-)</a>") or "")
end

local function href_fragment(href)
    if type(href) ~= "string" then return nil end
    return href:match("#([^#]+)$")
end

local function is_cross_text_href(href)
    return type(href) == "string" and href:find('/Text/[^"]+%.[x]?html#', 1, false) ~= nil
end

local function num_from_link_context(link)
    if type(link) ~= "string" then return nil end
    local id = link:match('id="([^"]+)"')
    local fragment = href_fragment(link:match('href="([^"]+)"') or "")
    for _, token in ipairs({ id or fragment, id and fragment }) do
        if token then
            local num = token:match("_(%d+)_")
                or token:match("^(%d+)$")
                or token:match("_(%d+)$")
            if num then return num end
        end
    end
    return nil
end

local function footnote_num_from_link(link)
    if type(link) ~= "string" then return nil end
    return extract_footnote_num(link_inner_html(link)) or num_from_link_context(link)
end

local function each_footnote_block(html, fn)
    if type(html) ~= "string" then return end
    for _, pattern in ipairs(FOOTNOTE_BLOCK_PATTERNS) do
        for block in html:gmatch(pattern) do
            fn(block)
        end
    end
end

local function parse_footnote_reference_link(link)
    if type(link) ~= "string" then return nil end
    local href = link:match('href="([^"]+)"')
    if not href then return nil end
    local num = footnote_num_from_link(link)
    if not num then return nil end

    local fragment = href_fragment(href)
    if not fragment then return nil end

    if is_cross_text_href(href) then
        local full_href, file = href:match('^(.*/Text/([^"]+%.[x]?html))#')
        if not full_href or not file then return nil end
        return { anchor = fragment, num = num, file = file, href = full_href .. "#" .. fragment }
    end

    if href:match("^#") then
        return { anchor = fragment, num = num, href = href }
    end

    return nil
end

local function is_publisher_footnote_link(link)
    if type(link) ~= "string" then return false end
    if link:find('epub:type="noteref"', 1, false) or link:find('href="#wt_', 1, false) then
        return false
    end
    return parse_footnote_reference_link(link) ~= nil
end

local function parse_footnote_definition_link(link)
    if type(link) ~= "string" then return nil end
    local id = link:match('id="([^"]+)"')
    if not id then return nil end
    local num = footnote_num_from_link(link)
    if not num then return nil end

    local href = link:match('href="([^"]+)"')
    local file
    if href and is_cross_text_href(href) then
        local _, ref_file = href:match('^(.*/Text/([^"]+%.[x]?html))#')
        file = ref_file
    end

    return {
        anchor = id,
        num = num,
        file = file,
        href = href or ("#" .. id),
    }
end

local function discover_reciprocal_anchors(html)
    local reciprocal = {}
    if type(html) ~= "string" or html == "" then
        return reciprocal
    end

    local by_id = {}
    for link in html:gmatch("<a%s+[^>]*>.-</a>") do
        local id = link:match('id="([^"]+)"')
        local target = href_fragment(link:match('href="([^"]+)"') or "")
        if id and target then
            by_id[id] = target
        end
    end
    for id, target in pairs(by_id) do
        if by_id[target] == id then
            reciprocal[id] = target
            reciprocal[target] = id
        end
    end

    each_footnote_block(html, function(block)
        local marker_id = block:match('<a[^>]-id="([^"]+)"[^>]*>%s*</a>')
        local back_link = block:match('<a[^>]-href="[^"]-#[^"]+"[^>]*>.-</a>')
        local back_target = back_link and href_fragment(back_link:match('href="([^"]+)"') or "")
        if marker_id and back_target and footnote_num_from_link(back_link) then
            reciprocal[marker_id] = back_target
            reciprocal[back_target] = marker_id
        end
    end)

    return reciprocal
end

local function is_disposable_marker_anchor(html, anchor)
    if type(html) ~= "string" or type(anchor) ~= "string" or anchor == "" then
        return false
    end
    local esc = escape_pattern(anchor)
    if not html:find('<a[^>]-id="' .. esc .. '"[^>]*>%s*</a>', 1, false) then
        return false
    end
    local in_footnote_block = false
    each_footnote_block(html, function(block)
        if block:find('id="' .. esc .. '"', 1, false) then
            in_footnote_block = true
        end
    end)
    if in_footnote_block then return false end
    return true
end

local function strip_empty_marker_anchors(html)
    if type(html) ~= "string" then return html end
    return html:gsub(
        '<a%s+id="([^"]+)"[^>]*>%s*</a>%s*(<a%s+[^>]-href="[^"]*/Text/[^"]+%.[x]?html#[^"]+"[^>]*>.-</a>)',
        function(_marker_id, ref_link)
            if parse_footnote_reference_link(ref_link) then
                return ref_link
            end
            return nil
        end
    )
end

local function merge_footnote_spans(spans)
    if #spans == 0 then return spans end
    table.sort(spans, function(a, b) return a.start < b.start end)
    local merged = { spans[1] }
    for i = 2, #spans do
        local cur = spans[i]
        local last = merged[#merged]
        if cur.start <= last.end_pos then
            if cur.end_pos > last.end_pos then
                last.end_pos = cur.end_pos
            end
        else
            merged[#merged + 1] = cur
        end
    end
    return merged
end

local function append_link_spans(html, spans, scan_re, predicate)
    local pos = 1
    while true do
        local bstart, bend = html:find(scan_re, pos)
        if not bstart then break end
        local link = html:sub(bstart, bend)
        if not predicate or predicate(link) then
            local rs, re_ex = byte_range_to_rune_range(html, bstart, bend)
            spans[#spans + 1] = { start = rs, end_pos = re_ex }
        end
        pos = bend + 1
    end
end

local function replace_sup_paren_with_span_bracket(html)
    return html:gsub("<sup>%((%d+)%)%</sup>", "<span>[%1]</span>")
end

local function normalize_footnote_link_tag(a_tag)
    if type(a_tag) ~= "string" then return a_tag end

    if a_tag:find("reader_footer_note", 1, true) then
        local num = footnote_num_from_link(a_tag) or "1"
        local open = a_tag:match("^(<a%s+[^>]*>)")
        if open then
            return open .. "<span>[" .. num .. "]</span></a>"
        end
    end

    if a_tag:find("<sup", 1, true) and a_tag:find("%(%d+%)", 1, false) then
        local num = a_tag:match("<span[^>]*>%((%d+)%)</span>")
            or a_tag:match("<sup[^>]*>%((%d+)%)</sup>")
        if num then
            local open = a_tag:match("^(<a%s+[^>]*>)")
            if open then
                return open .. "<span>[" .. num .. "]</span></a>"
            end
        end
        return replace_sup_paren_with_span_bracket(a_tag)
    end

    return a_tag
end

--- 将脚注 markup 中的 (N) 统一为 [N]（不触碰正文普通括号）。
function Footnotes.normalize_markup(html)
    if type(html) ~= "string" or html == "" then
        return html
    end

    html = html:gsub("(<p[^>]-class=\"fnContent[^\"]*\"[^>]->.-)(</p>)", function(block, close)
        block = block:gsub("<span[^>]*>%((%d+)%)</span></a>", "<span>[%1]</span></a>")
        block = block:gsub(">%((%d+)%)</a>", ">[%1]</a>")
        return block .. close
    end)

    local function maybe_normalize_footnote_link(link)
        if parse_footnote_reference_link(link) or link:find("reader_footer_note", 1, true) then
            return normalize_footnote_link_tag(link)
        end
        return link
    end

    html = html:gsub(TEXT_FOOTNOTE_LINK_SCAN_RE, maybe_normalize_footnote_link)
    html = html:gsub(LOCAL_HASH_LINK_SCAN_RE, maybe_normalize_footnote_link)

    return html
end

--- 返回脚注保护区 rune 区间（end_pos 为开区间，与 annotations range 一致）。
function Footnotes.find_footnote_spans(html)
    if type(html) ~= "string" or html == "" then
        return {}
    end

    local spans = {}
    append_link_spans(html, spans, TEXT_FOOTNOTE_LINK_SCAN_RE, function(link)
        return is_publisher_footnote_link(link)
    end)
    append_link_spans(html, spans, LOCAL_HASH_LINK_SCAN_RE, function(link)
        return is_publisher_footnote_link(link)
    end)

    local static_patterns = {
        '<p[^>]-class="fnContent[^"]*"[^>]->.-</a>',
        '<p[^>]-class="note"[^>]->.-</p>',
    }
    for _, pattern in ipairs(static_patterns) do
        append_link_spans(html, spans, pattern)
    end

    return merge_footnote_spans(spans)
end

local function extract_anchor_text(html, anchor)
    if type(html) ~= "string" or type(anchor) ~= "string" or anchor == "" then
        return nil
    end

    local escaped = escape_pattern(anchor)
    local patterns = {
        '<p[^>]-class="note"[^>]->.-id="' .. escaped .. '"[^>]->(.-)</p>',
        '<p[^>]-class="fnContent[^"]*"[^>]->.-id="' .. escaped .. '"[^>]->(.-)</p>',
        '<p[^>]-id="' .. escaped .. '"[^>]->(.-)</p>',
        '<p[^>]-class="fnContent[^"]*"[^>]->.-#' .. escaped .. '"[^>]->(.-)</p>',
        '<div[^>]-id="' .. escaped .. '"[^>]->(.-)</div>',
        '<aside[^>]-id="' .. escaped .. '"[^>]->(.-)</aside>',
        '<li[^>]-id="' .. escaped .. '"[^>]->(.-)</li>',
        'id="' .. escaped .. '"[^>]->(.-)</p>',
        'name="' .. escaped .. '"[^>]->(.-)</p>',
    }

    for _, pattern in ipairs(patterns) do
        local block = html:match(pattern)
        if block then
            local text = cleanup_footnote_text(block)
            if text ~= "" and not is_trivial_footnote_text(text) then
                return text
            end
        end
    end

    return nil
end

local function extract_fn_content_block(html, anchor)
    if type(html) ~= "string" or type(anchor) ~= "string" or anchor == "" then
        return nil
    end

    for block in html:gmatch('<p[^>]-class="fnContent[^"]*"[^>]->.-</p>') do
        if block:find('id="' .. anchor .. '"', 1, true)
            or block:find("#" .. anchor, 1, true) then
            return block
        end
    end

    return nil
end

local function extract_fn_content_body(html, anchor)
    local block = extract_fn_content_block(html, anchor)
    if not block then return nil end

    local body = block
    body = body:gsub("^%s*<p[^>]*>%s*", "")
    body = body:gsub("%s*</p>%s*$", "")

    body = body:gsub("^%s*<a[^>]->%s*<span[^>]*>%[%d+%]%</span>%s*</a>%s*", "")
    body = body:gsub("^%s*<a[^>]->%s*%[%d+%]%s*</a>%s*", "")
    body = body:gsub("^%s*<a[^>]->%s*<span[^>]*>%(%d+)%)</span>%s*</a>%s*", "")
    body = body:gsub("^%s*<a[^>]->%s*%(%d+%)%s*</a>%s*", "")

    local stripped = false
    body = body:gsub("^(%s*<a[^>]->.-</a>%s*)", function(prefix)
        if stripped then return prefix end
        local label = strip_tags(prefix)
        if label:match("^%[%d+%]$") or label:match("^%(%d+%)$") then
            stripped = true
            return ""
        end
        return prefix
    end)

    if body:match("^%s*$") then
        return nil
    end
    return body
end

local function extract_note_block(html, anchor)
    if type(html) ~= "string" or type(anchor) ~= "string" or anchor == "" then
        return nil
    end

    for block in html:gmatch('<p[^>]-class="note"[^>]->.-</p>') do
        if block:find('id="' .. anchor .. '"', 1, true) then
            return block
        end
    end

    return nil
end

local function extract_note_body(html, anchor)
    local block = extract_note_block(html, anchor)
    if not block then return nil end

    local body = block
    body = body:gsub("^%s*<p[^>]*>%s*", "")
    body = body:gsub("%s*</p>%s*$", "")
    body = body:gsub("^%s*<a[^>]->%s*</a>%s*", "")
    body = body:gsub("^%s*<a[^>]->%s*<span[^>]*>%[%d+%]%</span>%s*</a>%s*", "")
    body = body:gsub("^%s*<a[^>]->%s*%[%d+%]%s*</a>%s*", "")

    if body:match("^%s*$") then
        return nil
    end
    return body
end

local function anchor_cache_path(book_dir)
    return join_path(book_dir, "footnotes/anchors.json")
end

function Footnotes.load_anchor_cache(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then
        return {}
    end
    local path = anchor_cache_path(book_dir)
    local file = io.open(path, "r")
    if not file then return {} end
    local data = file:read("*a")
    file:close()
    local ok, parsed = pcall(JSON.decode, data or "")
    if ok and type(parsed) == "table" then
        return parsed
    end
    return {}
end

function Footnotes.save_anchor_cache(book_dir, cache)
    if type(book_dir) ~= "string" or book_dir == "" then return end
    if type(cache) ~= "table" then return end
    ensure_dir(join_path(book_dir, "footnotes"))
    local ok, encoded = pcall(JSON.encode, cache)
    if not ok then return end
    local file = io.open(anchor_cache_path(book_dir), "w")
    if not file then return end
    file:write(encoded)
    file:close()
end

function Footnotes.index_anchors(html)
    local map = {}
    if type(html) ~= "string" or html == "" then
        return map
    end

    local seen = {}
    for anchor in html:gmatch('[%s]id="([^"]+)"') do
        if not seen[anchor] and not is_disposable_marker_anchor(html, anchor) then
            seen[anchor] = true
            local text = extract_anchor_text(html, anchor)
            if text and text ~= "" then
                map[anchor] = text
            end
        end
    end

    for anchor in html:gmatch('[%s]name="([^"]+)"') do
        if not seen[anchor] and not map[anchor] and not is_disposable_marker_anchor(html, anchor) then
            seen[anchor] = true
            local text = extract_anchor_text(html, anchor)
            if text and text ~= "" then
                map[anchor] = text
            end
        end
    end

    return map
end

function Footnotes.convert_img_footnotes(html)
    if type(html) ~= "string" or html == "" then
        return html, {}
    end

    local footnotes = {}
    local fn_idx = 0

    local result = html:gsub('<img%s+[^>]-class="qqreader%-footnote"[^>]*/?>', function(match)
        local alt = match:match('alt="([^"]*)"') or ""
        if alt == "" then
            return match
        end
        fn_idx = fn_idx + 1
        footnotes[fn_idx] = alt
        return string.format(
            '<span class="fn-ref"><a epub:type="noteref" href="#wt_%d" id="wtref_%d">[%d]</a></span>',
            fn_idx, fn_idx, fn_idx
        )
    end)

    return result, footnotes
end

local function mask_protected_blocks(html)
    local blocks = {}
    local function mask_pattern(pattern)
        html = html:gsub(pattern, function(block)
            blocks[#blocks + 1] = block
            return BLOCK_PLACEHOLDER_PREFIX .. tostring(#blocks) .. BLOCK_PLACEHOLDER_SUFFIX
        end)
    end
    mask_pattern("(<p[^>]-class=\"fnContent[^\"]*\"[^>]->.-</p>)")
    mask_pattern("(<p[^>]-class=\"note\"[^>]->.-</p>)")
    return html, blocks
end

local function unmask_protected_blocks(html, blocks)
    return html:gsub(
        BLOCK_PLACEHOLDER_PREFIX .. "(%d+)" .. BLOCK_PLACEHOLDER_SUFFIX,
        function(i)
            return blocks[tonumber(i)] or ""
        end
    )
end

local function add_footnote_ref(refs, seen, anchor, num, file, full_href)
    if seen[anchor] then return end
    seen[anchor] = true
    refs[#refs + 1] = {
        anchor = anchor,
        num = tonumber(num) or (#refs + 1),
        file = file,
        href = full_href,
    }
end

local function collect_fn_content_footnote_refs(html, refs, seen)
    if type(html) ~= "string" then return end
    for block in html:gmatch('<p[^>]-class="fnContent[^"]*"[^>]->.-</p>') do
        for link in block:gmatch("<a%s+[^>]*>.-</a>") do
            local parsed = parse_footnote_definition_link(link)
            if parsed then
                add_footnote_ref(refs, seen, parsed.anchor, parsed.num, parsed.file, parsed.href)
            end
        end
    end
end

function Footnotes.collect_footnote_refs(html)
    local refs = {}
    local seen = {}
    if type(html) ~= "string" then
        return refs
    end

    local masked = mask_protected_blocks(html)

    for link in masked:gmatch(TEXT_FOOTNOTE_LINK_SCAN_RE) do
        local parsed = parse_footnote_reference_link(link)
        if parsed then
            add_footnote_ref(refs, seen, parsed.anchor, parsed.num, parsed.file, parsed.href)
        end
    end

    for link in masked:gmatch(LOCAL_HASH_LINK_SCAN_RE) do
        local parsed = is_publisher_footnote_link(link) and parse_footnote_reference_link(link)
        if parsed then
            add_footnote_ref(refs, seen, parsed.anchor, parsed.num, nil, parsed.href)
        end
    end

    collect_fn_content_footnote_refs(html, refs, seen)

    table.sort(refs, function(a, b) return a.num < b.num end)
    return refs
end

local function normalize_ref_basename(ref_file)
    if type(ref_file) ~= "string" or ref_file == "" then return nil end
    return ref_file:match("([^/]+%.[x]?html)$")
end

local function build_file_chapter_index(chapters)
    local index = {}
    if type(chapters) ~= "table" then return index end
    for _, chapter in ipairs(chapters) do
        local idx = chapter.chapterIdx
        if idx then
            local files = chapter.files
            if type(files) == "table" then
                for _, file in ipairs(files) do
                    if type(file) == "string" and file ~= "" then
                        index[file] = idx
                        local base = file:match("([^/]+%.xhtml)$")
                        if base then index[base] = idx end
                    end
                end
            end
        end
    end
    return index
end

local function find_section_start_idx(major, chapters, file_index)
    local section_file = string.format("chapter%d.xhtml", major)
    if file_index then
        for file, idx in pairs(file_index) do
            if file:match(section_file .. "$") or file:find("/" .. section_file, 1, true) then
                return idx
            end
        end
    end
    if type(chapters) ~= "table" then return nil end
    for _, chapter in ipairs(chapters) do
        if chapter.level == 1 or chapter.level == nil then
            local files = chapter.files
            if type(files) == "table" then
                for _, file in ipairs(files) do
                    if file:find(section_file, 1, true) then
                        return chapter.chapterIdx
                    end
                end
            end
        end
    end
    local cn = SECTION_CN[major]
    if cn then
        for _, chapter in ipairs(chapters) do
            local title = chapter.title or ""
            if title:find("第" .. cn .. "章", 1, true) then
                return chapter.chapterIdx
            end
        end
    end
    return nil
end

local function resolve_chapter_idx_for_ref_file(ref_file, chapters, file_index)
    local base = normalize_ref_basename(ref_file)
    if not base then return nil end
    if file_index and file_index[base] then
        return file_index[base]
    end
    if file_index then
        for file, idx in pairs(file_index) do
            if file:sub(-#base) == base then
                return idx
            end
        end
    end
    local major, minor = base:match("^chapter(%d+)_(%d+)%.xhtml$")
    if major and minor then
        major = tonumber(major)
        minor = tonumber(minor)
        local start_idx = find_section_start_idx(major, chapters, file_index)
        if start_idx then
            return start_idx + minor
        end
    end
    return nil
end

function Footnotes.fetch_missing_anchors(meta, missing, ref_by_anchor)
    if type(missing) ~= "table" or #missing == 0 then
        return {}
    end

    ref_by_anchor = ref_by_anchor or {}
    local book_dir = meta.book_dir
    local cache = Footnotes.load_anchor_cache(book_dir)
    local found = {}
    local still_missing = {}

    for _, anchor in ipairs(missing) do
        local cached = cache[anchor]
        if cached and cached ~= "" and not is_trivial_footnote_text(cached) then
            found[anchor] = cached
        else
            if cached and is_trivial_footnote_text(cached) then
                cache[anchor] = nil
            end
            still_missing[#still_missing + 1] = anchor
        end
    end

    if #still_missing == 0 then
        return found
    end

    local chapters = meta.chapters
    if type(chapters) ~= "table" or #chapters == 0 then
        if type(meta.fetch_catalog) == "function" then
            local ok, toc = pcall(meta.fetch_catalog)
            if ok and type(toc) == "table" then
                chapters = toc
            end
        end
    end

    if type(chapters) ~= "table" or #chapters == 0 then
        return found
    end

    local fetch_chapter_html = meta.fetch_chapter_html
    if type(fetch_chapter_html) ~= "function" then
        return found
    end

    local sorted = sort_chapters(chapters)
    local file_index = build_file_chapter_index(sorted)
    local scanned_uids = {}
    local max_scan = math.min(40, #sorted)
    local target_idx_set = {}

    for _, anchor in ipairs(still_missing) do
        local ref_file = ref_by_anchor[anchor]
        if ref_file then
            local idx = resolve_chapter_idx_for_ref_file(ref_file, sorted, file_index)
            if idx then
                target_idx_set[idx] = true
            end
        end
    end

    local function try_resolve_from_html(chapter_html)
        if not chapter_html then return end
        for _, anchor in ipairs(still_missing) do
            if not found[anchor] then
                local text = extract_anchor_text(chapter_html, anchor)
                if text and text ~= "" then
                    found[anchor] = text
                    cache[anchor] = text
                end
            end
        end
        for index = #still_missing, 1, -1 do
            if found[still_missing[index]] then
                table.remove(still_missing, index)
            end
        end
    end

    local function try_chapter(chapter, preloaded_html)
        if not chapter or not chapter.chapterUid then return end
        if scanned_uids[chapter.chapterUid] then return end
        scanned_uids[chapter.chapterUid] = true

        local html = preloaded_html
        if not html then
            local ok, fetched = pcall(fetch_chapter_html, chapter)
            if not ok or type(fetched) ~= "string" or fetched == "" then
                return
            end
            html = fetched
        end
        try_resolve_from_html(html)
    end

    for idx, _ in pairs(target_idx_set) do
        if #still_missing == 0 then break end
        local chapter = find_chapter_by_idx(sorted, idx)
        if chapter then
            try_chapter(chapter)
        end
    end

    local file_set = {}
    for _, anchor in ipairs(still_missing) do
        local ref_file = ref_by_anchor[anchor]
        if ref_file then
            file_set[ref_file] = true
        end
    end
    if next(file_set) then
        for _, chapter in ipairs(sorted) do
            if #still_missing == 0 then break end
            local ok, html = pcall(fetch_chapter_html, chapter)
            if ok and type(html) == "string" and html ~= "" then
                for file_name in pairs(file_set) do
                    if html:find(file_name, 1, true) then
                        try_chapter(chapter, html)
                        break
                    end
                end
            end
        end
    end

    for _, chapter in ipairs(sorted) do
        if #still_missing == 0 then break end
        local title = (chapter.title or ""):lower()
        if title:find("注释") or title:find("脚注") or title:find("尾注") or title:find("note") then
            try_chapter(chapter)
        end
    end

    local scanned = 0
    for index = #sorted, 1, -1 do
        if #still_missing == 0 or scanned >= max_scan then break end
        try_chapter(sorted[index])
        scanned = scanned + 1
    end

    if #still_missing > 0 then
        for _, chapter in ipairs(sorted) do
            if #still_missing == 0 then break end
            try_chapter(chapter)
        end
    end

    if next(cache) then
        Footnotes.save_anchor_cache(book_dir, cache)
    end

    if #still_missing > 0 then
        log_info("footnotes unresolved anchors:", #still_missing, table.concat(still_missing, ", "))
    end

    return found
end

function Footnotes.convert_footnote_refs(html, anchor_texts, fn_offset)
    if type(html) ~= "string" or html == "" then
        return html, {}
    end

    anchor_texts = anchor_texts or {}
    fn_offset = fn_offset or 0
    local footnotes = {}
    local fn_idx = fn_offset

    local function replace_footnote_link(anchor, num)
        local text = anchor_texts[anchor]
        local num_label = "[" .. num .. "]"
        if not text or text == "" or is_trivial_footnote_text(text) then
            return string.format('<sup class="fn-ref">%s</sup>', num_label)
        end
        fn_idx = fn_idx + 1
        footnotes[#footnotes + 1] = {
            num = num_label,
            text = text,
            anchor = anchor,
            fn_idx = fn_idx,
        }
        return string.format(
            '<span class="fn-ref"><a epub:type="noteref" href="#wt_%d" id="wtref_%d">%s</a></span>',
            fn_idx, fn_idx, num_label
        )
    end

    local masked, protected_blocks = mask_protected_blocks(html)
    masked = strip_empty_marker_anchors(masked)
    local result = masked:gsub(TEXT_FOOTNOTE_LINK_SCAN_RE, function(link)
        local parsed = parse_footnote_reference_link(link)
        if not parsed then return link end
        return replace_footnote_link(parsed.anchor, parsed.num)
    end)
    result = result:gsub(LOCAL_HASH_LINK_SCAN_RE, function(link)
        if link:find('epub:type="noteref"', 1, false) or link:find('href="#wt_', 1, false) then return link end
        local parsed = parse_footnote_reference_link(link)
        if not parsed then return link end
        return replace_footnote_link(parsed.anchor, parsed.num)
    end)
    result = unmask_protected_blocks(result, protected_blocks)

    return result, footnotes
end

function Footnotes.strip_consumed_footnote_blocks(html, cross_notes)
    if type(html) ~= "string" or html == "" then
        return html
    end
    if type(cross_notes) ~= "table" or #cross_notes == 0 then
        return html
    end

    local anchors = {}
    local reciprocal_map = discover_reciprocal_anchors(html)
    for _, note in ipairs(cross_notes) do
        if note.anchor then
            anchors[note.anchor] = true
            local reciprocal = reciprocal_map[note.anchor]
            if reciprocal then
                anchors[reciprocal] = true
            end
        end
    end

    local function strip_fn_content_for_anchor(body, anchor)
        local esc = escape_pattern(anchor)
        body = body:gsub("<hr%s*/>%s*<p[^>]-class=\"fnContent[^\"]*\"[^>]->.-id=\"" .. esc .. "\".-</p>%s*", "")
        body = body:gsub("<p[^>]-class=\"fnContent[^\"]*\"[^>]->.-id=\"" .. esc .. "\".-</p>%s*", "")
        body = body:gsub("<hr%s*/>%s*<p[^>]-class=\"fnContent[^\"]*\"[^>]->.-#" .. esc .. "\".-</p>%s*", "")
        body = body:gsub("<p[^>]-class=\"fnContent[^\"]*\"[^>]->.-#" .. esc .. "\".-</p>%s*", "")
        body = body:gsub("<p[^>]-class=\"note\"[^>]->.-id=\"" .. esc .. "\".-</p>%s*", "")
        body = body:gsub("<p[^>]-class=\"note\"[^>]->.-#" .. esc .. "\".-</p>%s*", "")
        return body
    end

    for anchor in pairs(anchors) do
        html = strip_fn_content_for_anchor(html, anchor)
    end

    html = html:gsub("<hr%s*/>%s*(<section[^>]-epub:type=\"footnotes\")", "%1")
    html = html:gsub("<hr%s*/>%s*(<div%s+class=\"footnotes\")", "%1")
    html = html:gsub("<hr%s*/>%s*(</body>)", "%1")

    return html
end

local function build_footnote_section(html, img_notes, cross_notes)
    local total = #(img_notes or {}) + #(cross_notes or {})
    if total == 0 then
        return ""
    end

    local parts = { '\n<div class="footnotes">\n<hr/>\n' }
    local idx = 0

    for _, text in ipairs(img_notes or {}) do
        idx = idx + 1
        parts[#parts + 1] = string.format(
            '<aside epub:type="footnote" id="wt_%d" class="footnote weread-book-footnote"><p><a href="#wtref_%d" class="fn-num">[%d]</a> %s</p></aside>\n',
            idx, idx, idx, xml_escape(text)
        )
    end

    for _, note in ipairs(cross_notes or {}) do
        local note_idx = note.fn_idx
        local body_html = extract_fn_content_body(html, note.anchor)
            or extract_note_body(html, note.anchor)
        if not body_html or body_html == "" then
            body_html = xml_escape(note.text or "")
        end
        parts[#parts + 1] = string.format(
            '<aside epub:type="footnote" id="wt_%d" class="footnote weread-book-footnote"><p><a href="#wtref_%d" class="fn-num">%s</a> %s</p></aside>\n',
            note_idx, note_idx, note.num, body_html
        )
    end

    parts[#parts + 1] = "</div>\n"
    return table.concat(parts)
end

function Footnotes.process(html, meta)
    if type(html) ~= "string" or html == "" then
        return html, ""
    end
    if meta and meta.is_txt then
        return html, ""
    end

    local local_index = Footnotes.index_anchors(html)
    local refs = Footnotes.collect_footnote_refs(html)
    local html1, img_notes = Footnotes.convert_img_footnotes(html)

    if #refs == 0 then
        local section = build_footnote_section(html1, img_notes, {})
        return html1, section
    end

    local missing = {}
    local ref_by_anchor = {}
    for _, ref in ipairs(refs) do
        if not local_index[ref.anchor] then
            missing[#missing + 1] = ref.anchor
            if ref.file then
                ref_by_anchor[ref.anchor] = ref.file
            end
        end
    end

    if meta and meta.book_dir and next(local_index) then
        local anchor_cache = Footnotes.load_anchor_cache(meta.book_dir)
        local cache_updated = false
        for anchor, text in pairs(local_index) do
            if text and text ~= "" and not is_trivial_footnote_text(text)
                and (not anchor_cache[anchor] or is_trivial_footnote_text(anchor_cache[anchor])) then
                anchor_cache[anchor] = text
                cache_updated = true
            end
        end
        if cache_updated then
            Footnotes.save_anchor_cache(meta.book_dir, anchor_cache)
        end
    end

    local remote = Footnotes.fetch_missing_anchors(meta, missing, ref_by_anchor)
    local anchor_texts = {}
    for _, ref in ipairs(refs) do
        anchor_texts[ref.anchor] = local_index[ref.anchor] or remote[ref.anchor]
    end

    local html2, cross_notes = Footnotes.convert_footnote_refs(html1, anchor_texts, #img_notes)

    local converted_anchors = {}
    for _, note in ipairs(cross_notes) do
        if note.anchor then
            converted_anchors[note.anchor] = true
        end
    end
    local next_fn_idx = #img_notes + #cross_notes
    for _, ref in ipairs(refs) do
        if not converted_anchors[ref.anchor] then
            local text = anchor_texts[ref.anchor]
            if text and text ~= "" and not is_trivial_footnote_text(text) then
                next_fn_idx = next_fn_idx + 1
                cross_notes[#cross_notes + 1] = {
                    num = "[" .. ref.num .. "]",
                    text = text,
                    anchor = ref.anchor,
                    fn_idx = next_fn_idx,
                }
            end
        end
    end

    local section = build_footnote_section(html2, img_notes, cross_notes)
    html2 = Footnotes.strip_consumed_footnote_blocks(html2, cross_notes)

    if section ~= "" then
        log_info("footnotes converted:", #img_notes + #cross_notes, "notes")
    elseif #refs > 0 then
        log_info("footnotes refs found but content missing:", #refs)
    end
    return html2, section
end

return Footnotes
