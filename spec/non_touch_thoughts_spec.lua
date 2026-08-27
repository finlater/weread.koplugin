-- Regression coverage for opening WeRead thought links on non-touch readers.

package.path = "./?.lua;" .. package.path

local closed_widget
local device_touch = false

package.preload["device"] = function()
    return {
        isTouchDevice = function() return device_touch end,
        screen = { getWidth = function() return 600 end },
    }
end
package.preload["weread.lib.annotations"] = function() return {} end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["ui/event"] = function() return { new = function() return {} end } end
package.preload["weread.lib.logger"] = function()
    return { warn = function() end }
end
package.preload["weread.lib.thought_db"] = function()
    return { close = function() end }
end
package.preload["weread.ui.thought_popup"] = function()
    return { cleanup = function() end, isShowing = function() return false end }
end
package.preload["weread.ui.thought_popup.popup_config"] = function() return {} end
package.preload["ui/time"] = function() return { now = function() return 100 end } end
package.preload["ui/uimanager"] = function()
    return {
        close = function(_self, widget) closed_widget = widget end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end,
        log_error = tostring,
        display_error = tostring,
        thought_perf = function() end,
    }
end

local Controller = require("weread.ui.annotations_controller")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local original_calls = 0
local opened_link
local reader_link = {
    onGotoLink = function(_self, link)
        original_calls = original_calls + 1
        return link.original_result
    end,
    isXpointerCoherent = function(_self, xpointer)
        return xpointer ~= "bad"
    end,
}
local original_on_goto = reader_link.onGotoLink
local host = {
    ui = { link = reader_link },
    settings = {
        get = function(_self, key)
            if key == "cache" then return { show_annotations = true } end
            return {}
        end,
    },
}
for key, value in pairs(Controller) do host[key] = value end
host._openThoughtLink = function(_self, link)
    opened_link = link
    return true
end

host:_setupThoughtInterception()
expect(host._thought_interception_setup == true,
    "non-touch reader installs thought interception")
expect(reader_link.onGotoLink ~= original_on_goto,
    "ReaderLink follow method is wrapped")

local thought_link = { xpointer = "#wrthought-book-chapter-1-2" }
expect(reader_link:onGotoLink(thought_link) == true and opened_link == thought_link,
    "selected thought link opens the native thought path")
expect(original_calls == 0, "thought link does not reach native anchor navigation")

local normal_link = { xpointer = "#footnote", original_result = "native" }
expect(reader_link:onGotoLink(normal_link) == "native" and original_calls == 1,
    "normal links still use ReaderLink")

host:_teardownThoughtInterception()
expect(reader_link.onGotoLink == original_on_goto,
    "document teardown restores ReaderLink")

host.ui.document = {
    getPageLinks = function()
        return {
            {
                section = "#wrthought-book-chapter-10-20",
                a_xpointer = "source-1",
                end_y = 20,
            },
            {
                section = "#wrthought-book-chapter-10-20",
                a_xpointer = "source-1-duplicate",
                end_y = 21,
            },
            { section = "#ordinary-link", a_xpointer = "source-2" },
            {
                section = "#wrthought-book-chapter-30-40",
                a_xpointer = "bad",
                segments = { { y1 = 42 } },
            },
        }
    end,
}
local page_links = host:_currentPageThoughtLinks()
expect(#page_links == 2, "current-page lookup filters and deduplicates thought links")
expect(page_links[1].link.from_xpointer == "source-1",
    "coherent source xpointer is kept for popup highlighting")
expect(page_links[2].link.from_xpointer == nil and page_links[2].link.link_y == 42,
    "incoherent source is dropped while segment position is preserved")

local shown_items
local shown_menu = { kind = "thought-list" }
local opened_from_menu
host._current_weread_book_id = "book"
host._buildThoughtPagesFromHref = function(_self, href)
    return { { abstract = href:find("10%-20") and "第一条划线" or "第二条划线" } }
end
host.showList = function(_self, title, items)
    expect(title == "Thoughts on this page", "current-page list has a descriptive title")
    shown_items = items
    return shown_menu
end
host._openThoughtLink = function(_self, link)
    opened_from_menu = link
    return true
end

expect(host:showCurrentPageThoughts() == true and #shown_items == 2,
    "current-page action exposes each visible thought")
shown_items[1].callback()
expect(closed_widget == shown_menu, "thought list closes before popup opens")
expect(opened_from_menu.xpointer == "#wrthought-book-chapter-10-20",
    "selected list item opens the corresponding thought")

print(string.format(
    "non_touch_thoughts_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
