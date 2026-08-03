-- Unit tests for the weread.ui.thought_popup entry module: the pooling
-- contract between the public `pages` argument and the widget's `items` field.
-- Run from the repo root with:
--   lua spec/thought_popup_entry_spec.lua

package.path = "./?.lua;" .. package.path

local created_widgets = {}
local reopen_log = {}

package.preload["weread.ui.thought_popup.face_factory"] = function()
    return { init = function() end }
end
package.preload["weread.ui.thought_popup.widget"] = function()
    return {
        new = function(_self, fields)
            local w = {
                items = fields.items,
                _reopen = function(_w, opts)
                    reopen_log[#reopen_log + 1] = {
                        items = opts.items,
                        pages = opts.pages,
                    }
                    _w.items = opts.items or {}
                end,
                clear = function() end,
                _freeContentCaches = function() end,
            }
            created_widgets[#created_widgets + 1] = w
            return w
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
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

test("first show constructs the widget with the pages as items", function()
    local popup = M.show({ pages = pages1 })
    eq(#created_widgets, 1, "one widget created")
    eq(popup, created_widgets[1], "returned widget is the created one")
    eq(popup.items, pages1, "widget receives pages as items")
end)

test("reopen forwards the same normalized items to the pooled widget", function()
    local popup = M.show({ pages = pages2 })
    eq(#created_widgets, 1, "no second widget created")
    eq(popup.items, pages2, "reopened widget content updated")
    eq(#reopen_log, 1, "reopen called once")
    eq(reopen_log[1].items, pages2, "reopen receives the items")
    eq(reopen_log[1].pages, pages2, "pages key preserved")
end)

test("empty pages are rejected", function()
    local ok = pcall(M.show, { pages = {} })
    eq(ok, false, "empty pages rejected")
    ok = pcall(M.show, {})
    eq(ok, false, "missing pages rejected")
end)

test("lifecycle helpers release the pool", function()
    eq(M.isShowing(), true, "isShowing after show")
    M.closeVisible()
    M.cleanup()
    eq(M.getPoolStats().has_active, false, "cleanup releases the pool")
end)

print(string.format("thought_popup_entry_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
