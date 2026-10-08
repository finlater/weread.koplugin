-- Full local TOC and transient per-row download selection. Mapping is saved
-- by the controller; toggling a row never performs network or database work.
local Chapters = require("weread.lib.annotation_chapters")
local Selection = {}
Selection.__index = Selection

function Selection:new(chapters, ranges, toc, current_index, state_of)
    local model = setmetatable({ chapters = chapters, nodes = {}, by_uid = {}, count = 0 }, self)
    local by_toc, by_point = {}, {}
    for index, entry in ipairs(toc or {}) do
        if entry.xpointer and not by_point[entry.xpointer] then by_point[entry.xpointer] = index end
    end
    for _, chapter in ipairs(chapters) do
        local range = ranges and ranges[Chapters.uid(chapter)]
        local index = range and (range.toc_index or by_point[range.start_xpointer])
        if index then by_toc[index] = chapter end
    end
    local stack = {}
    local function add(title, depth, chapter, index, point)
        depth = math.max(1, tonumber(depth) or 1)
        while #stack > 0 and stack[#stack].source_depth >= depth do table.remove(stack) end
        local parent = stack[#stack]
        local node = { title = title or "", chapter = chapter,
            depth = parent and parent.depth + 1 or 0, source_depth = depth,
            toc_index = index, xpointer = point, index = #model.nodes + 1,
            selectable = chapter ~= nil,
            state = chapter and state_of and state_of(chapter)
                or chapter and "ready_to_fetch" or "unlinked" }
        if parent then parent.branch = true end
        stack[#stack + 1], model.nodes[#model.nodes + 1] = node, node
        if chapter then model.by_uid[Chapters.uid(chapter)] = node end
    end
    if toc and #toc > 0 then
        for index, entry in ipairs(toc) do
            add(entry.title, entry.depth, by_toc[index], index,
                by_point[entry.xpointer] == index and entry.xpointer or nil)
        end
    else
        for _, chapter in ipairs(chapters) do add(chapter.title, chapter.level, chapter) end
    end
    local current = chapters[current_index or 1]
    model.current = current and model.by_uid[Chapters.uid(current)]
    return model
end

function Selection:visible()
    return self.nodes
end

function Selection:toggle(node)
    if not node.selectable then return end
    node.selected = not node.selected
    self.count = self.count + (node.selected and 1 or -1)
end

function Selection:clear()
    for _, node in ipairs(self.nodes) do node.selected = false end
    self.count = 0
end

function Selection:selection()
    local result = {}
    for _, chapter in ipairs(self.chapters) do
        local node = self.by_uid[Chapters.uid(chapter)]
        if node and node.selected then result[#result + 1] = chapter end
    end
    return result
end

return Selection
