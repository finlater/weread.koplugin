-- Opening a WeRead document must not synchronously initialize the thought DB.

package.path = "./?.lua;" .. package.path

local scheduled = {}
local thought_db_opens = 0

package.preload["weread.lib.content"] = function()
    return {}
end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return {}
end
local thought_popup_cleanup = 0
package.preload["weread.ui.thought_popup"] = function()
    return {
        closeVisible = function() end,
        cleanup = function()
            thought_popup_cleanup = thought_popup_cleanup + 1
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
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

local host = {
    ui = {
        document = { file = "/books/book.epub" },
        status = {},
    },
    settings = {
        get = function(_self, key)
            if key == "cache" then
                return { show_annotations = true }
            end
            return {}
        end,
    },
    progress_sync = {
        on_reader_ready = function() end,
    },
    read_report = {
        on_reader_ready = function() end,
    },
    detectWeReadBook = function() return "book" end,
    _teardownThoughtInterception = function() end,
    _installReaderHighlightTapGuard = function() end,
    _setupThoughtInterception = function() end,
    _setupXPointerOverlayPrototype = function() end,
    maybePrefetchNextChapter = function() end,
    _ensureThoughtDB = function()
        thought_db_opens = thought_db_opens + 1
    end,
}

for key, value in pairs(Lifecycle) do
    host[key] = value
end
host.detectWeReadBook = function() return "book" end
host.maybePrefetchNextChapter = function() end

host:onReaderReady()
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end

expect(thought_db_opens == 0,
    "reader ready does not initialize the thought database")

host.progress_sync.on_close_document = function() end
host.downloader = { cancelPrefetch = function() end }
host._teardownXPointerOverlayPrototype = function() end
host._removeReaderHighlightTapGuard = function() end
host.read_report.on_close_document = function() end
host:onCloseDocument()
expect(thought_popup_cleanup == 1,
    "closing a document must release pooled thought popup caches")

print(string.format(
    "reader_lifecycle_annotation_db_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
