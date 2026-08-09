package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
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

print(("footnotes_spec: %d checks"):format(checks))
