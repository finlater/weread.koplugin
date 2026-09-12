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
local model = Selection:new(chapters, {
    a = { toc_index = 2 }, b = { toc_index = 4 }, c = { toc_index = 6 },
}, toc, 2)
assert(#model.nodes == 5 and model.nodes[1].title == "Part I")
assert(model.by_uid.b.depth == 2 and model.by_uid.b.title == "Local B",
    "local TOC hierarchy/titles must take precedence over remote levels")
assert(model.nodes[1].expanded and model.nodes[3].expanded,
    "ancestors of the current chapter must open automatically")
local parent, a, b = model.nodes[1], model.by_uid.a, model.by_uid.b
model:toggle(parent)
assert(model.count == 2 and a.selected and b.selected and not model.by_uid.c.selected)
model:toggle(b)
assert(parent.count == 1 and parent.total == 2 and a.selected and not b.selected)
model:toggle(parent)
assert(parent.count == 2, "tapping a mixed parent must select the whole subtree")
model:toggle(parent)
assert(model.count == 0 and not a.selected and not b.selected,
    "unchecking the parent must also uncheck collapsed descendants")
model:toggle(b); model:expand(parent)
assert(#model:visible() == 2 and model.count == 1)
model:expand(parent)
assert(b.selected and #model:visible() == 5, "folding must retain selection")
model:toggle(model.by_uid.c); model:toggle(a)
local selected = model:selection()
assert(#selected == 3 and selected[1] == chapters[1] and selected[2] == chapters[2])
model:clear(); assert(model.count == 0 and parent.count == 0)

-- When a parent also has its own source chapter, its data is included exactly
-- once. Selecting children alone leaves that parent partly selected.
local fallback = Selection:new({
    { chapterUid = "p", level = 1 }, { chapterUid = "a", level = 2 },
    { chapterUid = "b", level = 4 }, { chapterUid = "q", level = 1 },
}, {}, nil, 3)
fallback:toggle(fallback.by_uid.a)
assert(fallback.count == 2 and fallback.by_uid.p.count == 2 and fallback.by_uid.p.total == 3)
fallback:toggle(fallback.by_uid.p)
assert(fallback.count == 3 and #fallback:selection() == 3)
fallback:toggle(fallback.by_uid.p)
assert(fallback.count == 0 and fallback.by_uid.b.count == 0)

local large = {}
for index = 1, 10000 do large[index] = { chapterUid = tostring(index), level = index == 1 and 1 or 2 } end
local many = Selection:new(large, {}, nil, 1)
assert(#many:visible() == 1, "closed subtrees must not create visible rows")
many:toggle(many.nodes[1]); assert(many.count == 10000)
many:toggle(many.nodes[5000]); assert(many.count == 9999 and many.nodes[1].count == 9999)
assert(#many:visible() == 1)

-- Completed source chapters remain visible but cannot be selected directly or
-- through a parent. Counts and partial state include only unfinished targets.
local mixed = Selection:new(chapters, {
    a = { toc_index = 2 }, b = { toc_index = 4 }, c = { toc_index = 6 },
}, toc, 1, function(chapter) return chapter.chapterUid == "a" end)
assert(#mixed.nodes == 5 and mixed.by_uid.a.total == 0 and not mixed.by_uid.a.selectable)
mixed:toggle(mixed.by_uid.a); assert(mixed.count == 0)
mixed:toggle(mixed.nodes[1])
assert(mixed.count == 1 and mixed.nodes[1].count == mixed.nodes[1].total)
assert(not mixed.by_uid.a.selected and mixed:selection()[1] == chapters[2])
mixed:toggle(mixed.nodes[1]); assert(mixed.count == 0)
local complete = Selection:new(chapters, { a = { toc_index = 2 }, b = { toc_index = 4 },
    c = { toc_index = 6 } }, toc, 1, function() return true end)
assert(#complete.nodes == 5 and complete.nodes[1].total == 0)
complete:toggle(complete.nodes[1]); assert(complete.count == 0 and #complete:selection() == 0)
local own_done = Selection:new({ { chapterUid = "parent", level = 1 },
    { chapterUid = "child", level = 2 } }, {}, nil, 1,
    function(chapter) return chapter.chapterUid == "parent" end)
own_done:toggle(own_done.nodes[1])
assert(own_done.count == 1 and own_done:selection()[1].chapterUid == "child",
    "a completed parent's unfinished children must remain selectable as a group")
print("chapter_selection_spec: local hierarchy, tri-state selection, folding and 10000 chapters passed")
