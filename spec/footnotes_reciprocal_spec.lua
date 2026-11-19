-- Reciprocal footnote pairs: the citation end and the note end point at each
-- other and both look like references, so the scanner used to classify every
-- citation target as a backlink and convert nothing. WeRead writes them as
--
--   <a href="#n1" id="r1"><span class="text-sup">[1]</span></a>    citation
--   <a href="#r1" id="n1"><span>[1]</span></a>                     note
--
-- and sometimes puts the superscript styling on the parent instead:
--
--   <span class="super"><a href="#n3" id="r3">[3]</a></span>
--
-- All fixtures are synthetic; no book content is involved.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"), 2)
    end
end

local function count_occurrences(haystack, needle)
    local count, pos = 0, 1
    while true do
        local at = haystack:find(needle, pos, true)
        if not at then return count end
        count = count + 1
        pos = at + #needle
    end
end

package.preload["weread.lib.logger"] = function()
    local stub = {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
    return { scoped = function() return stub end }
end

local Footnotes = require("weread.lib.footnotes")

local chapter = {
    chapterUid = "101",
    chapterIdx = 1,
    files = { "Text/chapter1.xhtml" },
}

local function transform(html)
    local scan = Footnotes.scan_chapter(html, chapter)
    local index = Footnotes.build_book_index({ ["101"] = scan }, { chapter })
    local out, stats = Footnotes.transform_chapter(html, scan, index)
    return scan, out, stats
end

local RECIPROCAL = [[
<p class="content">甲段正文<a href="#n1" id="r1"><span class="text-sup">[1]</span></a>，继续。</p>
<p class="content">乙段正文<a href="#n2" id="r2"><span class="text-sup">[2]</span></a>，继续。</p>
<p class="content"><a href="#r1" id="n1"><span>[1]</span></a>　注文一。</p>
<p class="content"><a href="#r2" id="n2"><span>[2]</span></a>　注文二。</p>
]]

local scan, out, stats = transform(RECIPROCAL)

-- Both ends are collected as references; that part is the input, not a bug.
expect(#scan.refs == 4, "both ends of each pair should be scanned as references")

-- The fix: note anchors must not enter forward_ref_ids, or every citation
-- target looks like a backlink.
expect(scan.forward_ref_ids["r1"] and scan.forward_ref_ids["r2"],
    "citation anchors belong to forward_ref_ids")
expect(not scan.forward_ref_ids["n1"] and not scan.forward_ref_ids["n2"],
    "note anchors must stay out of forward_ref_ids")
expect(scan.note_end_ids["n1"] and scan.note_end_ids["n2"],
    "note ends should be recorded")
expect(scan.refs[3].note_end == true, "note-side reference should be flagged")

expect(stats.candidates == 4, "every marker link is a candidate")
expect(stats.converted == 2, "both citations should convert")
expect(stats.backlinks == 2, "both note ends should count as backlinks")
expect(stats.removed_note_blocks == 2, "both note paragraphs should be removed")
expect(stats.unresolved == 0, "nothing should be left unresolved")

expect(count_occurrences(out, 'epub:type="noteref"') == 2,
    "each citation needs epub:type=noteref for KOReader to show a note")
expect(count_occurrences(out, 'class="wr-book-footnote"') == 2,
    "each note should land in the generated footnote section")
expect(count_occurrences(out, "注文一。") == 1 and count_occurrences(out, "注文二。") == 1,
    "note text must appear exactly once, not twice")
expect(out:find('id="n1"', 1, true) == nil and out:find('id="n2"', 1, true) == nil,
    "the original note paragraphs must be gone")
expect(Footnotes.validate(out) == true, "generated markup must validate")

-- The generated note must not start with the U+2003 WeRead puts between the
-- marker and the text. Trimming it byte-wise would also eat the first byte of a
-- kana or CJK punctuation codepoint, so check the text survives intact.
for text in out:gmatch('class="wr%-fn%-num">[^<]*</a> (.-)</p></aside>') do
    expect(text:sub(1, 3) ~= "\227\128\128", "note text must not start with U+2003")
    expect(text:sub(1, 2) ~= "\194\160", "note text must not start with a NBSP")
    expect(text:sub(1, 1) ~= " ", "note text must not start with an ASCII space")
end

-- Superscript styling on the parent element is a real WeRead variant; missing
-- it leaves whole books unconverted.
local PARENT_SUP = [[
<p class="content">正文<span class="super"><a href="#n3" id="r3">[3]</a></span>，继。</p>
<p class="content"><a href="#r3" id="n3"><span>[3]</span></a>　注文三。</p>
]]
local parent_scan, parent_out, parent_stats = transform(PARENT_SUP)
expect(parent_scan.note_end_ids["n3"] ~= nil,
    "styling on the parent element must still mark the citation end")
expect(parent_stats.converted == 1 and parent_stats.removed_note_blocks == 1,
    "parent-superscript layout should convert like the inline variant")
expect(Footnotes.validate(parent_out) == true, "parent-superscript output must validate")

-- A note may cite another note. The paragraph must not survive next to the
-- generated aside, or the note text shows up twice; its content moves into the
-- generated block and the nested citation stays converted there.
local NESTED = [[
<p class="content">正文<a href="#n4" id="r4"><span class="text-sup">[4]</span></a>，续。</p>
<p class="content"><a href="#r4" id="n4"><span>[4]</span></a>　注文四，另见<a href="#n5" id="r5"><span class="text-sup">[5]</span></a>。</p>
<p class="content"><a href="#r5" id="n5"><span>[5]</span></a>　注文五。</p>
]]
local nested_scan, nested_out, nested_stats = transform(NESTED)
expect(nested_stats.converted == 2, "nested citation should convert")
expect(nested_stats.removed_note_blocks == 2,
    "both note paragraphs are consumed, the nested one included")
expect(nested_out:find('id="n4"', 1, true) == nil,
    "the original note paragraph must not survive next to the generated aside")
expect(count_occurrences(nested_out, "注文四") == 1,
    "note text must appear exactly once after being re-homed")
expect(nested_out:find('class="wr-fn-ref"', 1, true) ~= nil,
    "the nested citation stays converted in its new home")
expect(Footnotes.validate(nested_out) == true, "nested output must validate")
expect(nested_scan.note_end_ids["n4"] ~= nil and nested_scan.note_end_ids["n5"] ~= nil,
    "both note ends should be recognised in the nested case")

-- Block position, not styling, separates the two ends: WeRead opens the note
-- paragraph with its marker while the citation sits inline in running prose.
-- A book whose superscript lives in its CSS has no `sup` on the tag, so a
-- styling-only rule leaves it at zero conversions; this fixture pins that case.
local NO_STYLE = [[
<p class="content">正文<a href="#n6" id="r6"><span>[6]</span></a>，续。</p>
<p class="content"><a href="#r6" id="n6"><span>[6]</span></a>　注文六。</p>
]]
local plain_scan, plain_out, plain_stats = transform(NO_STYLE)
expect(plain_stats.converted == 1, "block position alone should identify the pair")
expect(plain_stats.removed_note_blocks == 1, "the note paragraph is consumed")
expect(count_occurrences(plain_out, "注文六") == 1, "note text appears exactly once")
expect(plain_out:find('epub:type="noteref"', 1, true) ~= nil, "citation is converted")
expect(Footnotes.validate(plain_out) == true, "no-styling output must validate")
expect(plain_scan.note_end_ids["n6"] ~= nil,
    "the block-leading anchor is the note end even without styling")

print(("footnotes_reciprocal_spec: %d checks"):format(checks))
