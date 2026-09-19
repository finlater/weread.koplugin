-- Regression coverage for KOReader's transient nil visible_boxes cache.

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end,
    }
end
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

scheduled = {}
local notices = {}
local ready_host = {
    ui = { highlight = { onTap = function() end } },
    settings = { get = function(_self, key)
        if key == "cache" then return { show_annotations = false } end
        if key == "read_report" then return { enabled = false } end
    end },
    progress_sync = { on_reader_ready = function() end },
    downloader = { cancelPrefetch = function() end },
    read_report = { on_reader_ready = function() return false end },
    detectWeReadBook = function() return "book" end,
    _teardownThoughtInterception = function() end,
    _setupThoughtInterception = function() end,
    _setupXPointerOverlayPrototype = function() end,
    maybePrefetchNextChapter = function() end,
    showTransientInfo = function(_self, text, timeout)
        notices[#notices + 1] = { text = text, timeout = timeout }
    end,
}
for key, value in pairs(Lifecycle) do ready_host[key] = value end
ready_host.detectWeReadBook = function() return "book" end
ready_host.maybePrefetchNextChapter = function() end
ready_host:onReaderReady()
expect(#scheduled == 2 and scheduled[1].delay == 0.15,
    "WeRead book preparation is scheduled after the initial paint")
scheduled[1].callback()
expect(#notices == 1 and notices[1].text == "Preparing WeRead book…"
    and notices[1].timeout == 1.5,
    "WeRead book preparation status is shown for the active reader session")

print(string.format(
    "reader_lifecycle_highlight_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
