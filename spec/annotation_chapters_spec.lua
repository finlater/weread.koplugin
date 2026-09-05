package.path = "./?.lua;" .. package.path
local Chapters = require("weread.lib.annotation_chapters")
local toc = {
    { title = "第一章 开始", xpointer = "0", depth = 1 },
    { title = "子节", xpointer = "3", depth = 2 },
    { title = "第二章 继续", xpointer = "10", depth = 1 },
    { title = "第三章 结束", xpointer = "20", depth = 1 },
}
local doc = { getToc = function() return toc end }
local catalog = {
    { chapterUid = "9", title = "第一章 开始（第一更求票）" },
    { chapterUid = "12", title = "第二章 继续" },
    { chapterUid = "15", title = "第三章 结束" },
}
local selected, ranges = Chapters.map(doc, catalog)
assert(#selected == 3 and ranges["9"].end_xpointer == "10", "child TOC truncated parent chapter")
assert(Chapters.normalize("第二十四章 序列2") == "序列2")
assert(Chapters.normalize("第一章 标题（上）") == "标题（上）", "meaningful suffix lost")
local partial_doc = { getToc = function() return { toc[1], toc[4] } end }
local descriptor = { chapters = { catalog[1], catalog[3] } }
selected, ranges = Chapters.map(partial_doc, catalog, descriptor)
assert(#selected == 2 and not ranges["12"] and ranges["9"].end_xpointer == "20")
local book = { chapters = catalog, annotation_documents = { ["selection.epub"] = descriptor },
    cached_chapters = { ["12"] = "chapter.epub" } }
assert(Chapters.descriptor(book, "selection.epub") == descriptor)
assert(#Chapters.descriptor(book, "chapter.epub").chapters == 1)
assert(not Chapters.descriptor(book, "legacy-full.epub"), "legacy partial file was assumed to be complete")
local _, sparse = Chapters.map(doc, { catalog[1], catalog[3] })
assert(sparse["9"].end_xpointer == "10", "an unmatched sibling leaked into the previous chapter")
print("annotation_chapters_spec: nested TOC, UTF-8 titles and noncontiguous selections passed")
