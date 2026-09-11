-- Exercise real lifecycle handlers and overlay caches together, not just a
-- direct controller refresh. Large catalogs must stay off the page-turn path.
package.path = "./?.lua;" .. package.path
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function() return { tr = function(s) return s end } end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
local Controller = require("weread.ui.annotation_sync_controller")
local Lifecycle = require("weread.lib.reader_lifecycle")
local Overlay = require("weread.ui.xpointer_overlay")
local page, reads, comparisons, updates = 11, 0, 0, 0
local context = { book_id = "fixture", document_key = "fixture", binding = {}, chapters = {}, ranges = {} }
for index = 1, 5000 do
    local uid = tostring(index)
    context.chapters[index] = { chapterUid = uid }
    context.ranges[uid] = { start_xpointer = index * 10 }
end
context.store = {
    projectionKey = function(_, _, uid) return uid end,
    get = function(_, _, _, uid)
        reads = reads + 1
        return { records = { { chapter_uid = uid, pos0 = tonumber(uid) * 10, pos1 = tonumber(uid) * 10 + 1 } } }
    end,
}
local host = { _annotation_context = context, _xpointer_overlay = Overlay:new(),
    progress_sync = { on_page_update = function() updates = updates + 1 end },
    ui = { document = {
        getXPointer = function() return page end,
        getCurrentPage = function() return page end,
        getPageCount = function() return 50010 end,
        getPageXPointer = function(_, value) return value end,
        compareXPointers = function(_, a, b)
            comparisons = comparisons + 1
            return a == b and 0 or a < b and 1 or -1
        end,
    } },
}
for _, module in ipairs({ Controller, Lifecycle }) do for key, value in pairs(module) do host[key] = value end end
local function loaded()
    local ids = {}
    for _, record in ipairs(host._xpointer_overlay.records) do ids[#ids + 1] = record.chapter_uid end
    return table.concat(ids, ",")
end
host:_refreshAnnotationOverlay(); assert(loaded() == "1,2")
page = 51; host:onPageUpdate(); assert(loaded() == "4,5,6" and updates == 1)
page = 21; host:onPageUpdate(); assert(loaded() == "1,2,3")
page = 40001; comparisons = 0; host:onPosUpdate()
assert(loaded() == "3999,4000,4001" and comparisons < 25, "jump lookup must be logarithmic")
local before = reads
local overlay = host._xpointer_overlay
local generation = overlay.generation
overlay.cache.marker = true
comparisons = 0
for index = 1, 100 do page = 40002 + index % 2; host:onPageUpdate() end
assert(comparisons <= 400 and reads == before, "same-chapter turns must not scan catalog or reread SQLite")
assert(overlay.generation == generation and overlay.cache.marker, "ordinary turns discarded page caches")
overlay.enabled = false; page = 101; comparisons = 0; host:onPageUpdate()
assert(reads == before and comparisons == 0, "hidden overlay performed unnecessary work")
overlay.enabled = true; host:_refreshAnnotationOverlay(); assert(loaded() == "9,10,11")
page = 201
host.ui.document.getPageXPointer = function() return nil end
before = reads
host:onPageUpdate()
assert(loaded() == "19,20,21" and reads == before + 3,
    "missing page anchor caused an unbounded annotation load")
print("annotation_page_events_spec: page/scroll/jump/cache and 5000-chapter CPU bounds passed")
