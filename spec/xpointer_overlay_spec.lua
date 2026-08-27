package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Overlay = require("weread.ui.xpointer_overlay")

local box_calls = 0
local positions = {
    before0 = -100, before1 = -80,
    visible0 = 120, visible1 = 160,
    after0 = 900, after1 = 950,
}
local document = {
    getCurrentPos = function() return 100 end,
    getCurrentPage = function() return 4 end,
    getVisiblePageCount = function() return 1 end,
    getPosFromXPointer = function(_self, xp) return positions[xp] end,
    getScreenBoxesFromPositions = function(_self, pos0)
        box_calls = box_calls + 1
        return { { x = 10, y = 20, w = pos0 == "visible0" and 80 or 1, h = 14 } }
    end,
}
local draw_calls = 0
local view = {
    view_mode = "page",
    drawHighlightRect = function(_self, _bb, _x, _y, rect, drawer)
        draw_calls = draw_calls + 1
        expect(rect.w == 80, "renderer drew a non-visible record")
        expect(drawer == "underscore", "prototype did not use underline style")
    end,
}
local tick = 0
local overlay = Overlay:new{
    records = {
        { id = "before", pos0 = "before0", pos1 = "before1" },
        { id = "visible", pos0 = "visible0", pos1 = "visible1" },
        { id = "after", pos0 = "after0", pos1 = "after1" },
    },
    clock = function() tick = tick + 0.001; return tick end,
}
overlay.ui = { document = document, dimen = { h = 300 } }
overlay.view = view

overlay:paintTo({}, 0, 0)
expect(box_calls == 1, "only the visible candidate should request screen boxes")
expect(draw_calls == 1, "visible underline was not drawn")
expect(overlay.last_metrics.candidates == 1 and overlay.last_metrics.boxes == 1,
    "paint metrics do not describe the visible page")
expect(overlay.last_metrics.cache_hit == false, "first paint unexpectedly hit cache")

local hit = overlay:hitTest({ x = 20, y = 25 })
expect(hit and hit.id == "visible", "tap did not resolve the visible overlay record")
expect(overlay:hitTest({ x = 200, y = 200 }) == nil,
    "tap outside the underline unexpectedly hit")

overlay:paintTo({}, 0, 0)
expect(box_calls == 1, "page cache did not avoid repeated XPointer projection")
expect(overlay.last_metrics.cache_hit == true, "second paint did not report cache hit")

overlay:resetLayout()
overlay:paintTo({}, 0, 0)
expect(box_calls == 2, "layout reset did not invalidate screen box cache")

overlay:setEnabled(false)
overlay:paintTo({}, 0, 0)
expect(#overlay.visible == 0, "disabled overlay retained stale hit boxes")
expect(box_calls == 2, "disabled overlay performed document work")

local input_options, listed_items, saved_document, confirm_options, shown_popup
package.preload["ui/uimanager"] = function()
    return {
        close = function() end,
        setDirty = function() end,
        show = function(_self, widget) confirm_options = widget end,
    }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_self, options)
        input_options = options
        options.getInputText = function() return "测试书" end
        return options
    end }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            scaleBySize = function(_, value) return value end,
        },
    }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.external_annotations"] = function()
    return {
        normalize_search = function()
            return { { book_id = "book-1", title = "测试书", author = "作者" } }
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.ui.thought_popup"] = function()
    return { show = function(options) shown_popup = options end }
end
local Controller = require("weread.ui.xpointer_overlay_controller")
local invalidations = 0
local host = {
    _xpointer_overlay = {
        invalidate = function() invalidations = invalidations + 1 end,
    },
}
for name, method in pairs(Controller) do
    host[name] = method
end
Controller.onUpdatePos(host)
expect(invalidations == 1,
    "UpdatePos did not invalidate cached boxes after typography reflow")
Controller.onDocumentRerendered(host)
expect(invalidations == 2,
    "DocumentRerendered did not retain the layout invalidation fallback")

local popup_host = {
    ui = {
        font = { font_face = "Book Font" },
        document = {
            configurable = { font_size = 24 },
            getPageMargins = function()
                return { left = 11, right = 12, top = 13, bottom = 14 }
            end,
        },
    },
    settings = {
        get = function(_self, key)
            if key == "cache" then
                return { ignore_edge_thought_taps = false }
            end
            return {
                height_ratio = 0.75,
                position = "bottom",
                width_ratio = 0.9,
                contrast = 3,
                tap_to_page = true,
                font_size_relative = -2,
            }
        end,
    },
    _xpointer_overlay = {
        enabled = true,
        hitTest = function()
            return {
                items = {
                    { abstract = "quote", author = "alice", content = "body" },
                },
            }
        end,
    },
}
for name, method in pairs(Controller) do popup_host[name] = method end
expect(popup_host:_onXPointerOverlayTap({ pos = { x = 100, y = 100 } }) == true,
    "local-book thought tap was not consumed")
expect(shown_popup and shown_popup.position == "bottom"
        and shown_popup.height_ratio == 0.75
        and shown_popup.width_ratio == 0.9
        and shown_popup.contrast == 3
        and shown_popup.tap_to_page == true,
    "local-book popup did not reuse the configured popup options")
expect(shown_popup.doc_font_name == "Book Font"
        and shown_popup.doc_margins.left == 11,
    "local-book popup did not reuse the document typography")

local bind_host = {
    ui = { document = { file = "/books/test.epub" } },
    settings = {},
    external_annotations_db = {
        getDocument = function() return saved_document end,
        saveDocument = function(_self, _path, value)
            saved_document = value
            return true
        end,
        clearSyncCheckpoint = function() return true end,
        clearDocument = function()
            saved_document = nil
            return true
        end,
    },
    client = { gateway = function() return {} end },
    requireLogin = function() return true end,
    showInputDialog = function() end,
    runOnlineTask = function(_self, _label, callback) callback() end,
    showList = function(_self, _title, items) listed_items = items end,
    showTransientInfo = function() end,
}
for name, method in pairs(Controller) do bind_host[name] = method end
local sync_calls = 0
bind_host.syncExternalAnnotations = function() sync_calls = sync_calls + 1 end
bind_host:bindExternalAnnotationsBook()
input_options.buttons[1][2].callback()
listed_items[1].callback()
expect(saved_document and saved_document.binding.book_id == "book-1",
    "selecting a search result did not persist its binding")
expect(confirm_options and confirm_options.title == "Local book matched",
    "selecting a search result did not ask whether to sync immediately")
expect(confirm_options and confirm_options.text:find("resumed automatically", 1, true),
    "match confirmation did not explain resumable sync")
expect(sync_calls == 0,
    "annotation sync started before the user confirmed")
confirm_options.ok_callback()
expect(sync_calls == 1,
    "confirming the match did not start annotation sync")
local local_book_items = bind_host:getXPointerOverlayPrototypeMenuItems()
expect(#local_book_items == 3,
    "local-book menu retained duplicate visibility or diagnostic items")
expect(local_book_items[2].text_func() == "Sync underlines and thoughts"
        and local_book_items[3].text
            == "Clear data",
    "local-book menu actions did not use unified terminology")
saved_document.stats = { located = 242, total = 379 }
expect(bind_host:getXPointerOverlayPrototypeMenuItems()[2].text_func()
        == "Sync underlines and thoughts · 242 matched",
    "local-book sync menu did not show the last matched count")
local menu_updates = 0
local_book_items[3].callback({
    updateItems = function() menu_updates = menu_updates + 1 end,
})
expect(saved_document == nil and menu_updates == 1,
    "clearing local-book data did not refresh the open menu immediately")

print(("xpointer_overlay_spec: %d checks"):format(checks))
