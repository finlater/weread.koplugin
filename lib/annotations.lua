--[[--
微信读书划线标注处理

将微信读书的划线数据注入到章节 HTML 中。
划线 range 格式：如 "383-415"，表示 HTML 字符串的 rune 索引（包含所有标签）。
--]] --

local logger = require("logger")

local Annotations = {}

-- 下划线 CSS 样式
Annotations.UNDERLINE_CSS = [[
.wr-underline {
    border-bottom: 2px dashed #ff6b35;
    padding-bottom: 2px;
}
]]

-- 想法标记（星号）CSS 样式 — 浅色、右上角、小字号
Annotations.THOUGHT_CSS = [[
.wr-thought-link{text-decoration:none;color:inherit;}
.wr-star{font-size:0.6em;vertical-align:super;line-height:0;color:#aaa;margin-left:1px;}
.weread-thought{display:none;}
]]

--- 去除字符串开头的 UTF-8 BOM（\ufeff）。
-- WeRead 的部分章节会携带 BOM，而下划线 range 索引通常不包含这个字符。
local function stripLeadingBOM(s)
    if type(s) ~= "string" then return s end
    -- UTF-8 BOM: EF BB BF
    if s:sub(1, 3) == "\xef\xbb\xbf" then
        return s:sub(4)
    end
    return s
end

--- 将 UTF-8 字符串转换为 rune 数组。
local function toRunes(str)
    local runes = {}
    local i = 1
    local len = #str
    while i <= len do
        local byte = string.byte(str, i)
        local rune_len
        if byte < 0x80 then
            rune_len = 1
        elseif byte < 0xE0 then
            rune_len = 2
        elseif byte < 0xF0 then
            rune_len = 3
        else
            rune_len = 4
        end
        runes[#runes + 1] = str:sub(i, i + rune_len - 1)
        i = i + rune_len
    end
    return runes
end

--- 按 rune 数量截断字符串，避免 UTF-8 多字节字符被切半。
local function truncateRunes(str, max_runes)
    if type(str) ~= "string" or max_runes <= 0 then return "" end
    local runes = toRunes(str)
    if #runes <= max_runes then
        return str
    end
    local parts = {}
    for i = 1, max_runes do
        parts[#parts + 1] = runes[i]
    end
    return table.concat(parts) .. "…"
end

--- 解析 range 字符串（如 "383-415"）为起止位置。
-- 注意：微信读书 API 返回的 range 是 0 索引（JavaScript 惯例），
-- 但 Lua 使用 1 索引。需要加 1 转换。
local function parseRange(range_str)
    if type(range_str) ~= "string" or range_str == "" then
        return nil, nil
    end
    local start_str, end_str = range_str:match("^(%d+)%-(%d+)$")
    if not start_str or not end_str then
        return nil, nil
    end
    -- 加 1 转换为 Lua 1 索引
    local start = tonumber(start_str) + 1
    local end_pos = tonumber(end_str) + 1
    if not start or not end_pos or start >= end_pos then
        return nil, nil
    end
    return start, end_pos
end

--- snapEndToSafeBoundary 将 end 位置向前（回退）调整，使其不落在 HTML 标签或实体内部。
local function snapEndToSafeBoundary(runes, start, end_pos)
    local n = #runes
    if end_pos <= start or end_pos > n then
        return end_pos
    end
    -- 检查是否在 HTML 标签内部：从 end-1 向前扫描
    for i = end_pos - 1, start, -1 do
        if runes[i] == '>' then
            break -- 遇到 >，说明不在标签内部
        end
        if runes[i] == '<' then
            return i -- 在标签内部，回退到 < 之前
        end
    end
    -- 检查是否在 HTML 实体内部：从 end-1 向前扫描（实体最长约 10 字符）
    for i = end_pos - 1, start, -1 do
        if i < end_pos - 12 then break end
        local r = runes[i]
        if r == ';' or r == '<' or r == '>' then
            break -- 遇到分隔符，说明不在实体内部
        end
        if r == '&' then
            return i -- 在实体内部，回退到 & 之前
        end
    end
    return end_pos
end

--- snapStartToSafeBoundary 将 start 位置向后（前进）调整，使其不落在 HTML 标签或实体内部。
local function snapStartToSafeBoundary(runes, start, end_pos)
    local n = #runes
    if start < 0 or start >= end_pos or start >= n then
        return start
    end
    -- 检查是否在 HTML 标签内部：从 start-1 向前扫描
    for i = start - 1, 0, -1 do
        if i < start - 200 then break end
        if runes[i] == '>' then
            break -- 不在标签内部
        end
        if runes[i] == '<' then
            -- 在标签内部，向前找到闭合 >
            for j = start, n do
                if runes[j] == '>' then
                    return j + 1
                end
            end
            break
        end
    end
    -- 检查是否在 HTML 实体内部：从 start-1 向前扫描
    for i = start - 1, 0, -1 do
        if i < start - 12 then break end
        local r = runes[i]
        if r == ';' or r == '<' or r == '>' then
            break
        end
        if r == '&' then
            -- 在实体内部，向前找到闭合 ;
            for j = start, n do
                if j >= start + 12 then break end
                if runes[j] == ';' then
                    return j + 1
                end
            end
            break
        end
    end
    return start
end

--- wrapTextSegments 将 rune 切片中的每个文本段（非标签部分）分别用 <span> 包裹。
-- 遇到 HTML 标签时自动关闭/重开 span，确保不跨越标签边界。
local function wrapTextSegments(runes, className)
    local openTag = '<span class="' .. className .. '">'
    local closeTag = '</span>'

    local result = {}
    local inTag = false
    local textBuf = {}

    -- 包裹一个文本段
    local function wrapSegment(seg)
        if #seg == 0 then return end
        -- 检查是否纯空白
        local hasContent = false
        for _, r in ipairs(seg) do
            if not r:match("^%s$") then
                hasContent = true
                break
            end
        end
        if hasContent then
            result[#result + 1] = openTag
            for _, r in ipairs(seg) do
                result[#result + 1] = r
            end
            result[#result + 1] = closeTag
        else
            for _, r in ipairs(seg) do
                result[#result + 1] = r
            end
        end
    end

    -- 刷新文本缓冲区
    local function flushTextBuf()
        if #textBuf == 0 then return end
        wrapSegment(textBuf)
        textBuf = {}
    end

    for _, r in ipairs(runes) do
        if r == '<' then
            flushTextBuf()
            inTag = true
            result[#result + 1] = r
        elseif r == '>' then
            inTag = false
            result[#result + 1] = r
        elseif inTag then
            result[#result + 1] = r
        else
            -- 文本字符：缓冲到 textBuf
            textBuf[#textBuf + 1] = r
        end
    end
    flushTextBuf()

    return result
end

--- HTML 转义
local function htmlEscape(text)
    text = tostring(text or "")
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    text = text:gsub('"', "&quot;")
    return text
end

--- 构建想法内容 aside 块（EPUB 标准脚注）。
-- @return string  aside HTML
function Annotations.buildThoughtAsides(thought_reviews, chapter_uid)
    if type(thought_reviews) ~= "table" then return "" end
    if not chapter_uid then return "" end

    local parts = { '<section epub:type="footnotes">' }

    for _, rv in ipairs(thought_reviews) do
        if rv.pageReviews and #rv.pageReviews > 0 then
            local range_str = rv.range or "0-0"
            local id = "thought_" .. tostring(chapter_uid) .. "_" .. range_str:gsub("-", "_")
            parts[#parts + 1] = '<aside epub:type="footnote" id="' .. id .. '" class="footnote weread-thought">'

            -- 引用原文（截断）
            local abstract = nil
            local first_pr = rv.pageReviews[1]
            if first_pr and first_pr.review then
                abstract = first_pr.review.abstract or first_pr.review.contextAbstract
            end

            for i, pr in ipairs(rv.pageReviews) do
                local review = pr.review or {}
                local author = review.author or {}
                local name = author.nick or author.name or "匿名"
                local content = review.content or ""
                local likes = pr.likesCount or 0

                parts[#parts + 1] = '<p style="white-space:pre-line">'

                -- 第一条想法附带引用原文
                if i == 1 and abstract then
                    local q = truncateRunes(abstract, 50)
                    parts[#parts + 1] = '<span style="color:#666;font-style:italic">「' ..
                    htmlEscape(q) .. '」</span><br/>'
                end

                -- 作者 + 点赞
                local meta = "▸ " .. htmlEscape(name)
                if likes > 0 then meta = meta .. " · ♥ " .. likes end
                parts[#parts + 1] = '<span style="color:#999;font-size:0.85em">' .. meta .. '</span><br/>'

                -- 正文
                parts[#parts + 1] = '<span>' .. htmlEscape(content) .. '</span>'
                parts[#parts + 1] = '</p>'
            end

            parts[#parts + 1] = '</aside>'
        end
    end

    parts[#parts + 1] = '</section>'
    return table.concat(parts, "\n")
end

--- 在 HTML 中注入下划线标记。
-- @string html  完整的原始 HTML（包含 body 标签）
-- @table  underlines  划线列表
-- @table  thought_reviews  想法数据 map
-- @return processed_html
function Annotations.injectUnderlines(html, underlines, thought_reviews, chapter_uid)
    if type(html) ~= "string" or html == "" then
        return html
    end
    if type(underlines) ~= "table" or #underlines == 0 then
        return html
    end

    -- 去除 BOM，避免下划线位置偏移
    local original_html = html
    html = stripLeadingBOM(html)
    if html ~= original_html then
        logger.info("weread annotations: stripped BOM")
    end

    -- 解析所有 range
    local ranges = {}
    for _, ul in ipairs(underlines) do
        local range_str = ul.range
        if range_str then
            local start_pos, end_pos = parseRange(range_str)
            if start_pos and end_pos and start_pos < end_pos then
                ranges[#ranges + 1] = {
                    range_str = range_str,
                    start = start_pos,
                    end_pos = end_pos,
                }
            end
        end
    end

    if #ranges == 0 then
        return html
    end

    -- 按起始位置排序
    table.sort(ranges, function(a, b) return a.start < b.start end)

    -- 转换为 rune 数组
    local runes = toRunes(html)
    local n = #runes

    logger.info("weread annotations: html runes=", n, "underlines=", #ranges)

    -- 预计算所有替换片段
    local replacements = {}
    local prevEnd = 0

    for _, ul in ipairs(ranges) do
        local start_pos = ul.start
        local end_pos = ul.end_pos

        -- 边界检查
        if start_pos < 0 or end_pos > n or start_pos >= end_pos then
            goto continue
        end

        -- 校正边界：确保 start 和 end 不落在 HTML 标签或实体内部
        end_pos = snapEndToSafeBoundary(runes, start_pos, end_pos)
        start_pos = snapStartToSafeBoundary(runes, start_pos, end_pos)

        -- 确保不重叠
        if start_pos >= end_pos or start_pos < prevEnd then
            goto continue
        end

        -- 提取范围内的内容并包裹下划线标签
        local inner = {}
        for j = start_pos, end_pos - 1 do
            inner[#inner + 1] = runes[j]
        end

        -- 使用 wrapTextSegments 处理跨标签边界
        local wrapped = wrapTextSegments(inner, "wr-underline")

        -- 如果有想法数据，每个 wr-underline span 单独包裹 <a>（跨段可点击）
        if thought_reviews and thought_reviews[ul.range_str] then
            local underline_open = '<span class="wr-underline">'
            local underline_close = '</span>'
            local underline_close_with_ref = '<span class="wr-star">*</span></span>'

            -- 星号注入到最后一个 underline span 末尾
            local last_idx = #wrapped
            if wrapped[last_idx] == underline_close then
                wrapped[last_idx] = underline_close_with_ref
            end

            local href = "#thought_" .. tostring(chapter_uid) .. "_" .. ul.range_str:gsub("-", "_")
            local open_a = '<a epub:type="noteref" class="wr-thought-link" href="' .. href .. '">'

            -- wrapTextSegments 为每个文本段生成独立的 underline span；
            -- 逐 span 包裹 <a> 可避免 </h1><p>、</p><p> 等块级边界导致 MuPDF 截断链接。
            local with_links = {}
            for _, item in ipairs(wrapped) do
                if item == underline_open then
                    with_links[#with_links + 1] = open_a
                    with_links[#with_links + 1] = item
                elseif item == underline_close or item == underline_close_with_ref then
                    with_links[#with_links + 1] = item
                    with_links[#with_links + 1] = '</a>'
                else
                    with_links[#with_links + 1] = item
                end
            end
            wrapped = with_links
        end

        replacements[#replacements + 1] = {
            start = start_pos,
            end_pos = end_pos,
            content = wrapped,
        }
        prevEnd = end_pos

        ::continue::
    end

    if #replacements == 0 then
        return html
    end

    -- 单遍拼接：依次输出未修改段和替换片段
    local result = {}
    local prev = 1

    for _, rep in ipairs(replacements) do
        -- 输出未修改段
        for j = prev, rep.start - 1 do
            result[#result + 1] = runes[j]
        end
        -- 输出替换片段
        for _, r in ipairs(rep.content) do
            result[#result + 1] = r
        end
        prev = rep.end_pos
    end

    -- 输出剩余部分
    for j = prev, n do
        result[#result + 1] = runes[j]
    end

    return table.concat(result)
end

--- 处理章节数据中的划线标注。
-- @string html  原始 HTML 内容
-- @table  chapter_underlines  章节划线数据（来自 API）
-- @table  thought_reviews  想法数据 map（可选），keyed by range string
-- @return processed_html, css  处理后的 HTML 和额外的 CSS
function Annotations.process(html, chapter_underlines, thought_reviews)
    if type(html) ~= "string" or html == "" then
        return html, ""
    end

    if type(chapter_underlines) ~= "table" then
        return html, ""
    end

    local underlines = chapter_underlines.underlines
    if type(underlines) ~= "table" or #underlines == 0 then
        return html, ""
    end

    -- 构建 thought range 快速查找表
    local thought_map = nil
    if type(thought_reviews) == "table" then
        thought_map = {}
        for _, rv in ipairs(thought_reviews) do
            if rv.range and rv.pageReviews and #rv.pageReviews > 0 then
                thought_map[rv.range] = true
            end
        end
        if not next(thought_map) then
            thought_map = nil
        end
    end

    logger.info("weread annotations: processing", #underlines, "underlines",
        thought_map and ("thoughts on " .. #underlines) or "")

    local processed = Annotations.injectUnderlines(html, underlines, thought_map, chapter_underlines.chapterUid)

    -- 构建想法 aside 块并注入到 body 末尾
    if thought_map and processed ~= html then
        local chapter_uid = chapter_underlines.chapterUid
        if chapter_uid and thought_reviews then
            local aside_html = Annotations.buildThoughtAsides(thought_reviews, chapter_uid)
            if aside_html ~= "" then
                local last_body = processed:find("</body>", 1, true)
                if last_body then
                    processed = processed:sub(1, last_body - 1) .. aside_html .. processed:sub(last_body)
                else
                    processed = processed .. aside_html
                end
            end
        end
    end

    if processed ~= html then
        local css = Annotations.UNDERLINE_CSS
        if thought_map then
            css = css .. "\n" .. Annotations.THOUGHT_CSS
        end
        return processed, css
    end

    return html, ""
end

return Annotations
