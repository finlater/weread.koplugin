package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0

local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

local Mixin = require("weread.lib.mixin")

local inherited = { inherited_method = function() return "inherited" end }
local target = setmetatable({}, { __index = inherited })
Mixin.apply(target, {
    { first = function() return 1 end },
    { second = function() return 2 end },
})

expect(target.first() == 1, "first mixin method was not installed")
expect(target.second() == 2, "second mixin method was not installed")
expect(target.inherited_method() == "inherited",
    "mixin composition broke inherited methods")

local duplicate_ok = pcall(function()
    Mixin.apply(target, {
        { first = function() return "replacement" end },
    })
end)
expect(not duplicate_ok, "duplicate direct methods must be rejected")

local saved_catalogs = 0
package.loaded["weread.lib.content"] = {
    save_catalog_cache = function(_client, _settings, _book, chapters)
        saved_catalogs = saved_catalogs + 1
        return #chapters > 0
    end,
}
package.loaded.logger = {
    info = function() end,
    err = function() end,
}
package.loaded["weread.lib.plugin_util"] = {
    log_error = tostring,
}

local Migrations = require("weread.lib.migrations")
local books = {
    ["123"] = { title = "Book", chapters = { { chapterUid = 1 } } },
}
local writes = 0
local settings = {
    get = function() return books end,
    has_legacy_book_records = function() return false end,
    set = function(_self, key, value)
        expect(key == "books" and value == books,
            "migration wrote an unexpected settings value")
        writes = writes + 1
    end,
    flush = function() writes = writes + 1 end,
}

Migrations.run(settings, {})
expect(saved_catalogs == 1, "legacy catalog was not persisted")
expect(books["123"].chapters == nil,
    "legacy in-record chapter list was not removed")
expect(writes == 2, "migrated settings were not saved and flushed")

local function stub(name, value)
    package.preload[name] = function() return value or {} end
end
stub("ui/bidi", { dirpath = function(path) return path end })
stub("dispatcher", { registerAction = function() end })
stub("ffi/util", { template = function(text) return text end })
local widget = { new = function(_self, fields) return fields end }
stub("ui/widget/buttondialog", widget)
stub("ui/widget/confirmbox", widget)
stub("ui/widget/infomessage", widget)
stub("ui/uimanager", {})
stub("weread.lib.logger", { info = function() end })
stub("weread.ui.thought_popup", {})
stub("weread.lib.protocol", {})
stub("weread.lib.plugin_util", {
    tr = function(text) return text end,
    T = function(text) return text end,
})
stub("weread.lib.updater", {
    new = function() return {} end,
    proxy_label = function() return "" end,
})
package.loaded["weread.ui.menu"] = nil
package.loaded["weread.ui.update"] = nil
local Menu = require("weread.ui.menu")
local Update = require("weread.ui.update")
local composed = {}
local composed_ok, composed_err = pcall(function()
    Mixin.apply(composed, { Menu, Update })
end)
expect(composed_ok, "menu and update mixins must not collide: " .. tostring(composed_err))
expect(type(composed.getUpdateMenuItems) == "function",
    "fork updater menu items were not installed")
expect(composed.getUpdateMenuItems ~= Menu.getUpdateMenuItems,
    "upstream leftover updater menu must not replace the fork updater")

print(("plugin_composition_spec: %d checks"):format(checks))
