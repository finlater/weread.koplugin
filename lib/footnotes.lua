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

local function is_trivial_footnote_text(text)
    if type(text) ~= "string" or text == "" then
        return true
    end
    return text:match("^%[%d+%]$") ~= nil
end

local function cleanup_footnote_text(text)
    text = strip_tags(text)
    if text == "" then return "" end
    text = text:gsub("^%[%d+%]%s*", "")
    text = text:gsub("^%*%s*", "")
    return text:match("^%s*(.-)%s*$") or ""
end

local function extract_anchor_text(html, anchor)
    if type(html) ~= "string" or type(anchor) ~= "string" or anchor == "" then
        return nil
    end

    local escaped = anchor:gsub("([%.%-%+%[%]%(%)%$%^%%%?%*])", "%%%1")
    local patterns = {
        '<p[^>]-id="' .. escaped .. '"[^>]->(.-)</p>',
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

local function anchor_cache_path(book_dir)
    return join_path(book_dir, "footnotes/anchors.json")
end

function Footnotes.load_anchor_cache(book_dir)
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
        if not seen[anchor] then
            seen[anchor] = true
            local text = extract_anchor_text(html, anchor)
            if text and text ~= "" then
                map[anchor] = text
            end
        end
    end

    for anchor in html:gmatch('[%s]name="([^"]+)"') do
        if not seen[anchor] and not map[anchor] then
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

local cross_link_re = '<a%s+href="([^"]*/Text/([^"]+%.xhtml))#([^"]+)"[^>]*>%s*<span[^>]*>%[(%d+)%]</span>%s*</a>'

function Footnotes.collect_cross_file_refs(html)
    local refs = {}
    local seen = {}
    if type(html) ~= "string" then
        return refs
    end

    for full_href, file, anchor, num in html:gmatch(cross_link_re) do
        if not seen[anchor] then
            seen[anchor] = true
            refs[#refs + 1] = {
                anchor = anchor,
                num = tonumber(num) or (#refs + 1),
                file = file,
                href = full_href,
            }
        end
    end

    table.sort(refs, function(a, b) return a.num < b.num end)
    return refs
end

function Footnotes.fetch_missing_anchors(meta, missing, ref_files)
    if type(missing) ~= "table" or #missing == 0 then
        return {}
    end

    ref_files = ref_files or {}
    local file_set = {}
    for _, file_name in ipairs(ref_files) do
        if type(file_name) == "string" and file_name ~= "" then
            file_set[file_name] = true
        end
    end

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
    local scanned_uids = {}
    local max_scan = math.min(40, #sorted)

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

        for _, anchor in ipairs(still_missing) do
            if not found[anchor] then
                local text = extract_anchor_text(html, anchor)
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

    return found
end

function Footnotes.convert_cross_file_footnotes(html, anchor_texts, fn_offset)
    if type(html) ~= "string" or html == "" then
        return html, {}
    end

    anchor_texts = anchor_texts or {}
    fn_offset = fn_offset or 0
    local footnotes = {}
    local fn_idx = fn_offset

    local result = html:gsub(cross_link_re, function(_full_href, _file, anchor, num)
        local text = anchor_texts[anchor]
        if not text or text == "" or is_trivial_footnote_text(text) then
            return string.format('<sup class="fn-ref">[%s]</sup>', num)
        end
        fn_idx = fn_idx + 1
        footnotes[#footnotes + 1] = { num = num, text = text, anchor = anchor, fn_idx = fn_idx }
        return string.format(
            '<span class="fn-ref"><a epub:type="noteref" href="#wt_%d" id="wtref_%d">[%s]</a></span>',
            fn_idx, fn_idx, num
        )
    end)

    return result, footnotes
end

local function build_footnote_section(img_notes, cross_notes)
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
        parts[#parts + 1] = string.format(
            '<aside epub:type="footnote" id="wt_%d" class="footnote weread-book-footnote"><p><a href="#wtref_%d" class="fn-num">[%s]</a> %s</p></aside>\n',
            note_idx, note_idx, note.num, xml_escape(note.text)
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
    local refs = Footnotes.collect_cross_file_refs(html)
    if #refs == 0 then
        local converted, img_notes = Footnotes.convert_img_footnotes(html)
        local section = build_footnote_section(img_notes, {})
        return converted, section
    end

    local missing = {}
    local ref_files = {}
    local file_seen = {}
    for _, ref in ipairs(refs) do
        if not local_index[ref.anchor] then
            missing[#missing + 1] = ref.anchor
        end
        if ref.file and not file_seen[ref.file] then
            file_seen[ref.file] = true
            ref_files[#ref_files + 1] = ref.file
        end
    end

    local remote = Footnotes.fetch_missing_anchors(meta, missing, ref_files)
    local anchor_texts = {}
    for _, ref in ipairs(refs) do
        anchor_texts[ref.anchor] = local_index[ref.anchor] or remote[ref.anchor]
    end

    local html1, img_notes = Footnotes.convert_img_footnotes(html)
    local html2, cross_notes = Footnotes.convert_cross_file_footnotes(html1, anchor_texts, #img_notes)
    local section = build_footnote_section(img_notes, cross_notes)

    if section ~= "" then
        if logger then logger.info(LOG_MODULE, "footnotes converted:", #img_notes + #cross_notes, "notes") end
    elseif #refs > 0 then
        if logger then logger.info(LOG_MODULE, "footnotes refs found but content missing:", #refs) end
    end
    return html2, section
end

return Footnotes
