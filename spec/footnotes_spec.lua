package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

-- Plain-find occurrence counter: keeps literal data out of Lua patterns.
local function count_occurrences(haystack, needle)
    local count, pos = 0, 1
    while true do
        local at = haystack:find(needle, pos, true)
        if not at then return count end
        count = count + 1
        pos = at + #needle
    end
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end

local Footnotes = require("weread.lib.footnotes")

expect(Footnotes.FOOTNOTES_CSS:find(
    "aside.wr%-book%-footnote{%-cr%-hint:footnote%-inpage") ~= nil,
    "generated footnotes must use KOReader's default in-page flow")
expect(not Footnotes.FOOTNOTES_CSS:find("visibility:hidden", 1, true),
    "generated in-page footnotes must remain visible to CREngine")
expect(Footnotes.FOOTNOTES_CSS:find(
    "wr%-fn%-ref a{%-cr%-hint:noteref") ~= nil,
    "generated references must be explicit KOReader noterefs")
expect(Footnotes.FOOTNOTES_CSS:find(
    "div.wr%-footnotes>hr{display:none") ~= nil,
    "the generated footnote container must not leave a visible separator")
expect(Footnotes.get_css(false) == Footnotes.IN_PAGE_CSS,
    "in-page footnotes should remain the default")
expect(Footnotes.get_css(true) == Footnotes.POPUP_CSS
        and Footnotes.POPUP_CSS:find(
            "aside.wr%-book%-footnote{%-cr%-hint:footnote;", 1) ~= nil
        and Footnotes.POPUP_CSS:find("visibility:hidden", 1, true) ~= nil,
    "popup footnotes should use the previous hidden footnote flow")

local source = [[
<p>正文<a epub:type="noteref" href="#note-1"><sup>[1]</sup></a></p>
<aside id="note-1"><p>[1] 同章脚注内容</p></aside>
]]
local chapter = { chapterUid = "101", chapterIdx = 1, files = { "Text/chapter1.xhtml" } }
local scan = Footnotes.scan_chapter(source, chapter)
expect(#scan.refs == 1, "standard EPUB noteref was not detected")
expect(scan.definitions["note-1"]
    and scan.definitions["note-1"].text == "同章脚注内容",
    "same-chapter footnote definition was not indexed")

-- Simulate range-based user annotation changing the reference's inner markup
-- after the pristine source was scanned. Resolution must still use href/anchor.
local annotated = source:gsub("<sup>%[1%]</sup>",
    '<span class="wr-underline"><sup>[1]</sup></span>')
local local_index = Footnotes.build_book_index({ ["101"] = scan }, { chapter })
local transformed, local_stats = Footnotes.transform_chapter(annotated, scan, local_index)
expect(local_stats.converted == 1 and local_stats.unresolved == 0,
    "same-chapter footnote was not converted")
expect(transformed:find('epub:type="footnote"', 1, true)
    and transformed:find("同章脚注内容", 1, true),
    "converted same-chapter note was not embedded")
expect(Footnotes.validate(transformed) == true,
    "valid generated footnote markup failed validation")

local multi_body_html = [[
<html><body><p><a class="noteref" href="#multi-note">[1]</a></p>
<p id="multi-note">[1] 多文档脚注</p></body></html>
<html><body><h2 id="later-body">后续正文</h2></body></html>
]]
local multi_body_scan = Footnotes.scan_chapter(multi_body_html, chapter)
local multi_body_result = Footnotes.transform_chapter(
    multi_body_html, multi_body_scan,
    Footnotes.build_book_index({ ["101"] = multi_body_scan }, { chapter }))
local later_body_pos = multi_body_result:find('id="later-body"', 1, true)
local footnotes_pos = multi_body_result:find('class="wr-footnotes"', 1, true)
expect(later_body_pos and footnotes_pos and later_body_pos < footnotes_pos,
    "footnotes were inserted before a later concatenated XHTML body")

local source_chapter = {
    chapterUid = "201", chapterIdx = 1, files = { "Text/chapter1.xhtml" },
}
local target_chapter = {
    chapterUid = "202", chapterIdx = 2, files = { "Text/chapter2.xhtml" },
}
local source_html = [[<p>正文<a href="../Text/chapter2.xhtml#target-x"><span>[2]</span></a></p>]]
local target_html = [[<section><p id="target-x">[2] 跨章尾注内容</p></section>]]
local source_scan = Footnotes.scan_chapter(source_html, source_chapter)
local target_scan = Footnotes.scan_chapter(target_html, target_chapter)
local book_index = Footnotes.build_book_index({
    ["201"] = source_scan,
    ["202"] = target_scan,
}, { source_chapter, target_chapter })
local cross_body, cross_stats = Footnotes.transform_chapter(
    source_html, source_scan, book_index)
expect(cross_stats.converted == 1 and cross_stats.unresolved == 0,
    "cross-chapter footnote was not resolved through the book index")
expect(cross_body:find("跨章尾注内容", 1, true),
    "cross-chapter footnote text was not embedded")

local adjacent_html = [[<a id="adjacent-note"></a><p>[3] 空锚点后的脚注内容</p>]]
local adjacent_scan = Footnotes.scan_chapter(adjacent_html, target_chapter)
expect(adjacent_scan.definitions["adjacent-note"]
    and adjacent_scan.definitions["adjacent-note"].text == "空锚点后的脚注内容",
    "empty anchor followed by a note paragraph was not indexed")

local image_html = [[<p>正文<img class="cover qqreader-footnote icon" alt="图片脚注说明" src="note.png"/></p>]]
local image_scan = Footnotes.scan_chapter(image_html, chapter)
local image_body, image_stats = Footnotes.transform_chapter(
    image_html, image_scan,
    Footnotes.build_book_index({ ["101"] = image_scan }, { chapter }))
expect(image_stats.image_notes == 1 and image_body:find("图片脚注说明", 1, true),
    "qqreader image footnote was not converted")
expect(not image_body:find("qqreader%-footnote"),
    "converted image footnote marker remained in the chapter")

local missing_html = [[<p><a class="noteref" href="Text/missing.xhtml#fn404">[9]</a></p>]]
local missing_scan = Footnotes.scan_chapter(missing_html, chapter)
local missing_body, missing_stats = Footnotes.transform_chapter(
    missing_html, missing_scan,
    Footnotes.build_book_index({ ["101"] = missing_scan }, { chapter }))
expect(missing_stats.unresolved == 1 and missing_stats.converted == 0,
    "unresolved footnote was not reported")
expect(missing_body:find('href="Text/missing.xhtml#fn404"', 1, true),
    "unresolved footnote did not preserve its original link")

local thought_html = [[<p><a class="wr-thought-link" href="#wrthought-book-chapter-1-2">*</a></p>]]
local thought_scan = Footnotes.scan_chapter(thought_html, chapter)
expect(#thought_scan.refs == 0,
    "user thought link was incorrectly classified as a book footnote")

local backlink_html = [[<a href="../Text/chapter1.xhtml#w1">[1]</a><span id="w1"></span>]]
local backlink_scan = Footnotes.scan_chapter(backlink_html, chapter)
local backlink_body, backlink_stats = Footnotes.transform_chapter(
    backlink_html, backlink_scan,
    Footnotes.build_book_index({ ["101"] = backlink_scan }, { chapter }))
expect(backlink_stats.backlinks == 1 and backlink_stats.unresolved == 0,
    "same-chapter return link was counted as an unresolved footnote")
expect(backlink_body:find('href="#w1"', 1, true),
    "same-chapter return link was not normalized to a local anchor")

local reciprocal_html = [[
<p><span id="source-1"><a href="#note-1">[1]</a></span></p>
<p class="note"><a id="note-1"></a>正文脚注<a href="#source-1">[1]</a></p>
]]
local reciprocal_scan = Footnotes.scan_chapter(reciprocal_html, chapter)
local reciprocal_body, reciprocal_stats = Footnotes.transform_chapter(
    reciprocal_html, reciprocal_scan,
    Footnotes.build_book_index({ ["101"] = reciprocal_scan }, { chapter }))
expect(reciprocal_stats.converted == 1 and reciprocal_stats.backlinks == 1,
    "reciprocal note link was converted as a second footnote")
expect(reciprocal_stats.removed_note_blocks == 1
    and not reciprocal_body:find('class="note"', 1, true),
    "consumed inline note block was not removed")
local _, reciprocal_asides = reciprocal_body:gsub('epub:type="footnote"', "")
expect(reciprocal_asides == 1,
    "reciprocal note pair did not produce exactly one end footnote")
expect(not reciprocal_body:find('role="doc%-endnotes"'),
    "endnote container role would let popup extraction select all notes")

local duplicate_source = [[<p><a class="noteref" href="#shared">[1]</a></p>]]
local duplicate_scan = Footnotes.scan_chapter(duplicate_source, source_chapter)
local duplicate_a = Footnotes.scan_chapter(
    [[<p id="shared">[1] 第一处</p>]], target_chapter)
local duplicate_chapter_b = { chapterUid = "203", chapterIdx = 3 }
local duplicate_b = Footnotes.scan_chapter(
    [[<p id="shared">[1] 第二处</p>]], duplicate_chapter_b)
local duplicate_index = Footnotes.build_book_index({
    ["201"] = duplicate_scan,
    ["202"] = duplicate_a,
    ["203"] = duplicate_b,
}, { source_chapter, target_chapter, duplicate_chapter_b })
local _, duplicate_stats = Footnotes.transform_chapter(
    duplicate_source, duplicate_scan, duplicate_index)
expect(duplicate_stats.unresolved == 1,
    "ambiguous global anchor should not resolve to an arbitrary chapter")

local invalid = transformed:gsub('id="wrfn%-101%-1"', 'id="removed"')
local valid, validation_error = Footnotes.validate(invalid)
expect(valid == false and tostring(validation_error):find("missing", 1, true),
    "missing generated target was not rejected")

-- Regression: a chapter-root wrapper block spanning nearly the whole chapter
-- used to index every descendant anchor with the entire flattened chapter
-- (both dual-language variants concatenated) as the note text.
local padding_unit = "這是用來模擬整章長度的填充正文段落。"
local padding = padding_unit:rep(260)
local poisoned_html = [[
<html><body><div id="root">
<h2 class="wr-traditional">第一章</h2><h2 class="wr-simplified">第一章</h2>
<p class="wr-traditional">這是正文內容。<a href="#fn_1">1</a></p>
<p class="wr-simplified">这是正文内容。</p>
<p class="wr-traditional">]] .. padding .. [[</p>
<a id="fn_1"></a><p>譯註：這是真正的注釋。</p>
</div></body></html>
]]
local poisoned_scan = Footnotes.scan_chapter(poisoned_html, chapter)
expect(poisoned_scan.definitions["fn_1"] ~= nil,
    "real footnote definition was lost to root-block poisoning")
expect(poisoned_scan.definitions["fn_1"].text == "譯註：這是真正的注釋。",
    "chapter-root wrapper poisoned the footnote definition text")
local poisoned_body, poisoned_stats = Footnotes.transform_chapter(
    poisoned_html, poisoned_scan,
    Footnotes.build_book_index({ ["101"] = poisoned_scan }, { chapter }))
expect(poisoned_stats.converted == 1 and poisoned_stats.unresolved == 0,
    "poisoned-chapter footnote was not converted")
expect(select(2, poisoned_body:gsub('class="wr%-book%-footnote"', "")) == 1,
    "root-block poisoning generated spurious footnote asides")
local poisoned_notes = poisoned_body:match('<div class="wr%-footnotes">.*')
expect(poisoned_notes and poisoned_notes:find("譯註：這是真正的注釋。", 1, true),
    "converted note did not embed the true footnote text")
expect(poisoned_notes and not poisoned_notes:find(padding_unit, 1, true),
    "generated footnote embedded flattened chapter padding")
expect(count_occurrences(poisoned_body, padding) == 1,
    "generated footnotes duplicated chapter body padding")

-- Shortest-wins: when an oversized-but-legitimate ancestor capture is recorded
-- first, the smaller direct capture must replace it.
local filler = "補充背景說明文字。"
local wrapped_html = "<aside>"
    .. filler:rep(30) .. '<p id="short-note">真注釋</p>' .. filler:rep(30)
    .. "</aside>"
local wrapped_scan = Footnotes.scan_chapter(wrapped_html, chapter)
expect(wrapped_scan.definitions["short-note"] ~= nil,
    "wrapped short note definition was not indexed")
expect(wrapped_scan.definitions["short-note"].text == "真注釋",
    "larger ancestor capture was not replaced by the shorter direct capture")

-- A long but legitimate note below the size cap must survive intact.
local long_text = string.rep("這是一條很長但完全真實的注釋內容。", 100)
local long_scan = Footnotes.scan_chapter(
    '<p id="long-note">' .. long_text .. "</p>", chapter)
expect(long_scan.definitions["long-note"] ~= nil,
    "long legitimate note definition was dropped")
expect(long_scan.definitions["long-note"].text == long_text,
    "long legitimate note text was truncated or altered")

-- Regression: a backlink arrow inside an element sharing the note target's id
-- used to poison the definition, since shortest-wins favored its 3-byte glyph.
local arrow_html = [[<li id="fn_9">這是完整的注釋正文內容。<a id="fn_9" href="#ref_9">↩</a></li>]]
local arrow_doc = [[<p>正文<a class="noteref" href="#fn_9"><sup>[9]</sup></a></p>]] .. arrow_html
local arrow_scan = Footnotes.scan_chapter(arrow_doc, chapter)
expect(arrow_scan.definitions["fn_9"] ~= nil,
    "backlink arrow eliminated the footnote definition entirely")
-- The stored text is the enclosing li capture; strip_tags leaves the trailing
-- return glyph in place, but the definition must never collapse to it.
expect(arrow_scan.definitions["fn_9"].text == "這是完整的注釋正文內容。 ↩",
    "backlink arrow was stored as the footnote definition text")
local arrow_body, arrow_stats = Footnotes.transform_chapter(
    arrow_doc, arrow_scan,
    Footnotes.build_book_index({ ["101"] = arrow_scan }, { chapter }))
expect(arrow_stats.converted == 1 and arrow_stats.unresolved == 0,
    "note sharing its id with a backlink arrow was not converted")
expect(Footnotes.validate(arrow_body) == true,
    "arrow-poisoned chapter generated invalid footnote markup")
local arrow_aside = arrow_body:match(
    'class="wr%-book%-footnote".-<a href="#wrfnref%-101%-1"[^>]*>%[9%]</a>(.-)</p>')
expect(arrow_aside and arrow_aside:find("這是完整的注釋正文內容。", 1, true),
    "generated aside did not embed the full footnote text")
expect(arrow_aside and arrow_aside:match("^%s*↩%s*$") == nil,
    "generated aside collapsed to the bare backlink arrow")

-- Regression: notes written only in kana, hangul, Cyrillic or astral-plane CJK
-- were treated as pure symbols, since the old check only knew %w and the CJK
-- UTF-8 lead bytes 0xE4-0xE9. Any real text codepoint must keep the candidate.
local scripts_html = '<p id="kana-note">これは日本語の脚注です。</p>'
    .. '<p id="hangul-note">한국어 각주입니다.</p>'
    .. '<p id="cyrillic-note">Это сноска на русском языке.</p>'
    .. '<p id="extb-note">𠀀𠀁 rare CJK extension footnote.</p>'
    .. '<p id="mixed-note">①これは注釈本体。</p>'
local scripts_scan = Footnotes.scan_chapter(scripts_html, chapter)
for _, anchor in ipairs({ "kana-note", "hangul-note", "cyrillic-note",
    "extb-note", "mixed-note" }) do
    expect(scripts_scan.definitions[anchor] ~= nil,
        "non-ASCII script footnote was mistaken for a pure symbol: " .. anchor)
end
expect(scripts_scan.definitions["kana-note"].text == "これは日本語の脚注です。",
    "kana-only footnote text was not stored verbatim")
expect(scripts_scan.definitions["mixed-note"].text == "①これは注釈本体。",
    "marker-plus-text footnote text was not stored verbatim")

-- Symbol-only candidates (backlink arrows and their variation selectors,
-- enclosed numbers, CJK/Latin-1 punctuation) must still be rejected outright.
local glyph_html = '<p id="glyph-arrow">↩</p><p id="glyph-arrow-vs">↩️</p>'
    .. '<p id="glyph-left">←</p><p id="glyph-hook">⤴</p>'
    .. '<p id="glyph-enclosed">①</p><p id="glyph-cjk-punct">。</p>'
    .. '<p id="glyph-latin1">«»</p><p id="glyph-dash">……</p>'
local glyph_scan = Footnotes.scan_chapter(glyph_html, chapter)
for _, anchor in ipairs({ "glyph-arrow", "glyph-arrow-vs", "glyph-left",
    "glyph-hook", "glyph-enclosed", "glyph-cjk-punct", "glyph-latin1",
    "glyph-dash" }) do
    expect(glyph_scan.definitions[anchor] == nil,
        "symbol-only candidate was stored as note text: " .. anchor)
end

print(("footnotes_spec: %d checks"):format(checks))
