-- Regression coverage for KOReader's transient nil visible_boxes cache.

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        display_error = tostring,
        file_exists = function() return false end,
        log_error = tostring,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local calls = 0
local original = function(self, arg, ges)
    calls = calls + 1
    return self.view.highlight.visible_boxes, arg, ges
end
local reader_highlight = {
    view = { highlight = {} },
    onTap = original,
}
local host = { ui = { highlight = reader_highlight } }
for key, value in pairs(Lifecycle) do host[key] = value end

expect(host:_installReaderHighlightTapGuard(), "guard installs on ReaderHighlight")
expect(reader_highlight.onTap ~= original, "native tap handler is wrapped")

local boxes, arg, ges = reader_highlight:onTap("arg", { pos = { x = 1, y = 2 } })
expect(type(boxes) == "table" and #boxes == 0,
    "tap initializes a missing visible box cache")
expect(calls == 1 and arg == "arg" and ges.pos.x == 1,
    "guard delegates to the native handler unchanged")

local existing = { { index = 1 } }
reader_highlight.view.highlight.visible_boxes = existing
boxes = reader_highlight:onTap(nil, { pos = { x = 3, y = 4 } })
expect(boxes == existing, "an initialized visible box cache is preserved")

expect(host:_installReaderHighlightTapGuard(), "reinstall is idempotent")
host:_removeReaderHighlightTapGuard()
expect(reader_highlight.onTap == original, "document close restores native handler")

host.ui.highlight = nil
expect(not host:_installReaderHighlightTapGuard(),
    "missing ReaderHighlight module degrades safely")

print(string.format(
    "reader_lifecycle_highlight_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
