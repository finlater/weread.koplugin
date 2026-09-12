-- Transient catalog selection. Only the picker owns this model; no persistence
-- and no document/network work is performed while selecting or expanding.
local Chapters = require("weread.lib.annotation_chapters")
local Selection = {}
Selection.__index = Selection

function Selection:new(chapters, ranges, toc, current_index, is_matched)
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
    local candidates, stack = {}, {}
    local function add(title, depth, chapter)
        depth = math.max(1, tonumber(depth) or 1)
        while #stack > 0 and stack[#stack].source_depth >= depth do table.remove(stack) end
        local parent = stack[#stack]
        local node = { title = title, chapter = chapter, parent = parent,
            source_depth = depth, depth = parent and parent.depth + 1 or 0,
            total = chapter and 1 or 0, count = 0 }
        candidates[#candidates + 1] = node
        stack[#stack + 1] = node
        if chapter then model.by_uid[Chapters.uid(chapter)] = node end
    end
    if next(by_toc) then
        for index, entry in ipairs(toc) do add(entry.title, entry.depth, by_toc[index]) end
        -- Keep local headings with selectable descendants, even if the heading
        -- itself has no corresponding remote chapter.
        for index = #candidates, 1, -1 do
            local node = candidates[index]
            if node.parent then node.parent.total = node.parent.total + node.total end
        end
        for _, node in ipairs(candidates) do
            if node.total > 0 then model.nodes[#model.nodes + 1] = node end
        end
        -- A download manifest may contain chapters with no usable TOC anchor.
        -- Keep them selectable without inventing a parent in the local book.
        for _, chapter in ipairs(chapters) do
            if not model.by_uid[Chapters.uid(chapter)] then
                local node = { title = chapter.title, chapter = chapter, depth = 0, total = 1, count = 0 }
                model.nodes[#model.nodes + 1] = node
                model.by_uid[Chapters.uid(chapter)] = node
            end
        end
    else
        for _, chapter in ipairs(chapters) do add(chapter.title, chapter.level, chapter) end
        model.nodes = candidates
        for index = #candidates, 1, -1 do
            local node = candidates[index]
            if node.parent then node.parent.total = node.parent.total + node.total end
        end
    end
    -- Keep completed chapters in the catalog, but count only unfinished targets
    -- for selection. Snapshot the small status map once when opening the picker.
    for index, node in ipairs(model.nodes) do
        node.index, node.last = index, index
        node.matched = node.chapter and is_matched and is_matched(node.chapter) or false
        node.selectable = node.chapter ~= nil and not node.matched
        node.total = node.selectable and 1 or 0
    end
    for index = #model.nodes, 1, -1 do
        local node = model.nodes[index]
        if node.parent then
            node.parent.last = math.max(node.parent.last, node.last)
            node.parent.total = node.parent.total + node.total
        end
    end
    local current = chapters[current_index or 1]
    model.current = current and model.by_uid[Chapters.uid(current)]
    local parent = model.current and model.current.parent
    while parent do parent.expanded = true; parent = parent.parent end
    return model
end

function Selection:visible()
    if not self.visible_nodes then
        local result, index = {}, 1
        while index <= #self.nodes do
            local node = self.nodes[index]
            result[#result + 1] = node
            index = node.expanded and index + 1 or node.last + 1
        end
        self.visible_nodes = result
    end
    return self.visible_nodes
end

function Selection:expand(node)
    node.expanded = not node.expanded
    self.visible_nodes = nil
end

function Selection:toggle(node)
    if node.total == 0 then return end
    local selected = node.count < node.total
    local delta = (selected and node.total or 0) - node.count
    for index = node.index, node.last do
        local child = self.nodes[index]
        child.selected = selected and child.selectable
        child.count = selected and child.total or 0
    end
    local parent = node.parent
    while parent do parent.count = parent.count + delta; parent = parent.parent end
    self.count = self.count + delta
end

function Selection:clear()
    for _, node in ipairs(self.nodes) do node.selected, node.count = false, 0 end
    self.count = 0
end

function Selection:selection()
    local result = {}
    for _, chapter in ipairs(self.chapters) do
        local node = self.by_uid[Chapters.uid(chapter)]
        if node.selectable and node.selected then result[#result + 1] = chapter end
    end
    return result
end

return Selection
