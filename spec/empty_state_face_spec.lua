-- Regression coverage for full-screen views whose empty states use TextWidget.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Widget = {}
Widget.__index = Widget

function Widget:extend(defaults)
    defaults = defaults or {}
    defaults.__index = defaults
    return setmetatable(defaults, { __index = self })
end

function Widget:new(values)
    values = values or {}
    setmetatable(values, { __index = self })
    if values.init then values:init() end
    return values
end

function Widget:getSize()
    local dimen = self.dimen or {}
    return { w = self.width or dimen.w or 100, h = self.height or dimen.h or 20 }
end

function Widget:getHeight()
    return self:getSize().h
end

local function widget_module()
    return Widget:extend{}
end

local shown = {}
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY = 2 }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["device"] = function()
    return {
        input = { group = { Back = "back" } },
        hasKeys = function() return false end,
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_self, value) return value end,
        },
    }
end
package.preload["ui/font"] = function()
    return { getFace = function(_self, name, size) return { name = name, size = size } end }
end
package.preload["ui/geometry"] = function()
    return {
        new = function(_self, values)
            values.copy = function(source)
                local copy = {}
                for key, value in pairs(source) do copy[key] = value end
                return copy
            end
            return values
        end,
    }
end
package.preload["ui/size"] = function()
    return {
        border = { thin = 1 },
        padding = { small = 2, default = 4, large = 8 },
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(widget) shown[#shown + 1] = widget end,
        close = function() end,
        setDirty = function() end,
    }
end
package.preload["ui/widget/textwidget"] = function()
    local TextWidget = widget_module()
    function TextWidget:new(values)
        expect(values.face ~= nil, "TextWidget empty state must provide a font face")
        return Widget.new(self, values)
    end
    return TextWidget
end
package.preload["ui/widget/focusmanager"] = function()
    local FocusManager = widget_module()
    FocusManager.FOCUS_ONLY_ON_NT = 0
    FocusManager.NOT_UNFOCUS = 1
    function FocusManager:moveFocusTo() return true end
    function FocusManager.onFocusMove() return true end
    return FocusManager
end

for _, name in ipairs({
    "ui/gesturerange",
    "ui/widget/button",
    "ui/widget/container/framecontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/container/scrollablecontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/linewidget",
    "ui/widget/titlebar",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}) do
    package.preload[name] = widget_module
end

package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.book_reviews"] = function()
    return {
        format_date = function() return "" end,
        format_rating = tostring,
        preview = function(text) return text end,
    }
end

local LibraryView = require("weread.ui.library_view")
local ok, error_message = pcall(function()
    LibraryView.show({ mode = "books", books = {}, accounts = {} }, {})
end)
expect(ok, "empty bookshelf failed to build: " .. tostring(error_message))

local books = {}
for index = 1, 25 do
    books[index] = { bookId = tostring(index), title = "Book " .. tostring(index) }
end
local changed_page
local paged_view = LibraryView.show({
    mode = "books", books = books, accounts = {},
    paged = true, page = 2, page_size = 10,
}, {
    on_page_changed = function(page) changed_page = page end,
})
expect(paged_view.page == 2 and paged_view.page_count == 3,
    "bookshelf page metadata was wrong")
expect(#paged_view._item_rows == 10,
    "paged bookshelf created rows outside the current page")
expect(#paged_view._page_buttons == 3,
    "paged bookshelf did not create navigation controls")
paged_view._page_buttons[3].callback()
expect(changed_page == 3, "next-page button returned the wrong page")

local clamped_view = LibraryView.show({
    mode = "books", books = books, accounts = {},
    paged = true, page = 99, page_size = 10,
}, {})
expect(clamped_view.page == 3 and #clamped_view._item_rows == 5,
    "last bookshelf page was not clamped and sliced correctly")

local large_shelf = {}
for index = 1, 1000 do
    large_shelf[index] = { bookId = tostring(index), title = "Book " .. tostring(index) }
end
local large_view = LibraryView.show({
    mode = "books", books = large_shelf, accounts = {},
    paged = true, page = 50, page_size = 10,
}, {})
expect(large_view.page_count == 100 and #large_view._item_rows == 10,
    "large bookshelf created more than one page of row widgets")

local BookReviewsView = require("weread.ui.book_reviews_view")
ok, error_message = pcall(function()
    BookReviewsView.show({
        book_title = "Book",
        mode = "recommended",
        result = { items = {} },
    }, {})
end)
expect(ok, "empty review list failed to build: " .. tostring(error_message))
expect(#shown == 5, "all bookshelf and empty-state views should be shown")

print(("empty_state_face_spec: %d checks"):format(checks))
