-- Unit tests for the weread.ui.thought_popup entry module: the pooling
-- contract between the public `pages` argument and the widget's `items`
-- field, and the per-position dispatch (bottom vs centered popups).
-- Run from the repo root with:
--   lua spec/thought_popup_entry_spec.lua

package.path = "./?.lua;" .. package.path

local created_widgets = {}   -- bottom pool creations
local created_centers = {}   -- center pool creations
local reopen_log = {}
local freed_content_log = {}
local closed_log = {}

local function widget_mock(created_list)
    return {
        new = function(_self, fields)
            local w = {
                items = fields.items,
                width_ratio = fields.width_ratio,
                contrast = fields.contrast,
                _reopen = function(w, opts)
                    reopen_log[#reopen_log + 1] = {
                        items = opts.items,
                        pages = opts.pages,
                        position = opts.position,
                        width_ratio = opts.width_ratio,
                        contrast = opts.contrast,
                    }
                    w.items = opts.items or {}
                    w.width_ratio = opts.width_ratio
                    w.contrast = opts.contrast
                end,
                clear = function() end,
                _freeContentCaches = function(w)
                    freed_content_log[#freed_content_log + 1] = w
                end,
            }
            created_list[#created_list + 1] = w
            return w
        end,
    }
end

package.preload["weread.ui.thought_popup.face_factory"] = function()
    return { init = function() end }
end
package.preload["weread.ui.thought_popup.widget"] = function()
    return widget_mock(created_widgets)
end
package.preload["weread.ui.thought_popup.center_widget"] = function()
    return widget_mock(created_centers)
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function(_self, widget)
            if widget then closed_log[#closed_log + 1] = widget end
        end,
        isWidgetShown = function() return true end,
    }
end

local M = require("weread.ui.thought_popup")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

local pages1 = {
    { abstract = "a", author = "x", content = "c", likes_count = 0 },
}
local pages2 = {
    { abstract = "b", author = "y", content = "d", likes_count = 1 },
}

-- Reset module state between groups of tests.
local function reset()
    M.cleanup()
    created_widgets = {}
    created_centers = {}
    reopen_log = {}
    freed_content_log = {}
    closed_log = {}
end

test("default position constructs the bottom widget with pages as items", function()
    reset()
    local popup = M.show({ pages = pages1, width_ratio = 0.8, contrast = 2 })
    eq(#created_widgets, 1, "one bottom widget created")
    eq(#created_centers, 0, "no centered widget created")
    eq(popup, created_widgets[1], "returned widget is the created one")
    eq(popup.items, pages1, "widget receives pages as items")
    eq(popup.width_ratio, 0.8, "widget receives the width ratio")
    eq(popup.contrast, 2, "widget receives the contrast")
end)

test("explicit bottom position reuses the bottom pool", function()
    local popup = M.show({ pages = pages2, position = "bottom" })
    eq(#created_widgets, 1, "no second bottom widget created")
    eq(popup, created_widgets[1], "same pooled widget reused")
    eq(popup.items, pages2, "reopened widget content updated")
    eq(#reopen_log, 1, "reopen called once")
    eq(reopen_log[1].items, pages2, "reopen receives the items")
    eq(reopen_log[1].pages, pages2, "pages key preserved")
    eq(reopen_log[1].position, "bottom", "position forwarded")
    eq(reopen_log[1].width_ratio, nil, "width ratio not forwarded when unset")
end)

test("center position constructs the centered widget and drops the bottom pool", function()
    local popup = M.show({ pages = pages1, position = "center" })
    eq(#created_centers, 1, "one centered widget created")
    eq(popup, created_centers[1], "returned widget is the centered one")
    eq(popup.items, pages1, "centered widget receives pages as items")
    eq(#freed_content_log, 1, "bottom pool content caches freed on switch")
    eq(freed_content_log[1], created_widgets[1], "bottom widget was freed")
end)

test("reopening the centered position reuses its pool", function()
    local popup = M.show({ pages = pages2, position = "center" })
    eq(#created_centers, 1, "no second centered widget created")
    eq(popup, created_centers[1], "same centered widget reused")
    eq(popup.items, pages2, "reopened centered content updated")
end)

test("switching back to bottom frees the centered pool", function()
    M.show({ pages = pages1, position = "bottom" })
    eq(#created_widgets, 2, "bottom pool rebuilt after switch")
    eq(#freed_content_log, 2, "centered pool content caches freed")
    eq(freed_content_log[2], created_centers[1], "centered widget was freed")
end)

test("empty pages are rejected", function()
    local ok = pcall(M.show, { pages = {} })
    eq(ok, false, "empty pages rejected")
    ok = pcall(M.show, {})
    eq(ok, false, "missing pages rejected")
end)

test("lifecycle helpers release the pools", function()
    reset()
    M.show({ pages = pages1, position = "center" })
    eq(M.isShowing(), true, "isShowing after show")
    M.closeVisible()
    eq(#closed_log, 1, "closeVisible closes the pooled widget")
    M.cleanup()
    eq(M.getPoolStats().has_active, false, "cleanup releases the pool")
    eq(M.getPoolStats().pool_size, 0, "pool size is zero after cleanup")
end)

print(string.format("thought_popup_entry_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
