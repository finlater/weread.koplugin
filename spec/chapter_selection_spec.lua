package.path = "./?.lua;" .. package.path
local Selection = require("weread.lib.chapter_selection")
local chapters = {
    { chapterUid = "a", title = "Remote A", level = 1 },
    { chapterUid = "b", title = "Remote B", level = 1 },
    { chapterUid = "c", title = "Remote C", level = 1 },
}
local toc = {
    { title = "Part I", depth = 1, xpointer = "p" },
    { title = "Local A", depth = 2, xpointer = "a" },
    { title = "Section", depth = 2, xpointer = "s" },
    { title = "Local B", depth = 3, xpointer = "b" },
    { title = "Unused", depth = 1, xpointer = "u" },
    { title = "Local C", depth = 1, xpointer = "c" },
}
local ranges = { a = { toc_index = 2 }, b = { toc_index = 4 }, c = { toc_index = 6 } }
local model = Selection:new(chapters, ranges, toc, 2, function(chapter)
    if chapter.chapterUid == "a" then return "matched" end
    if chapter.chapterUid == "b" then return "ready_to_match" end
    return "ready_to_fetch"
end)
assert(#model.nodes == #toc and #model:visible() == #toc and model.count == 0)
assert(model.current == model.by_uid.b and model.by_uid.b.depth == 2
    and model.by_uid.b.title == "Local B", "local hierarchy/current chapter lost")
model:toggle(model.nodes[1]); assert(model.count == 0, "unmatched parent was selected")
assert(model.by_uid.a.state == "matched"
    and model.by_uid.b.state == "ready_to_match"
    and model.by_uid.c.state == "ready_to_fetch"
    and model.nodes[1].state == "unlinked"
    and model.by_uid.a.selectable and not model.by_uid.a.selected)
model:toggle(model.by_uid.b); model:toggle(model.by_uid.a)
local selected = model:selection()
assert(#selected == 2 and selected[1] == chapters[1] and selected[2] == chapters[2])
model:toggle(model.by_uid.b); assert(model.count == 1 and model.by_uid.a.selected)
model:clear(); assert(model.count == 0)
local empty = Selection:new({}, {}, toc)
assert(#empty.nodes == #toc and empty.nodes[1].xpointer == "p",
    "zero automatic matches must still allow manual chapter selection")
local duplicates = Selection:new({}, {}, { toc[1], toc[1], { title = "No anchor" } })
assert(duplicates.nodes[1].xpointer and not duplicates.nodes[2].xpointer and not duplicates.nodes[3].xpointer)
local large = {}
for index = 1, 10000 do large[index] = { chapterUid = tostring(index), level = index == 1 and 1 or 2 } end
local many = Selection:new(large, {}, nil, 1, function() return "matched" end)
assert(#many:visible() == 10000 and many.count == 0)
many:toggle(many.nodes[1]); assert(many.count == 1, "parent checkbox selected descendants")
many:toggle(many.nodes[5000]); assert(many.count == 2 and #many:selection() == 2)
print("chapter_selection_spec: full TOC, independent selection, refetch and 10000 chapters passed")
