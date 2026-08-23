-- Performance instrumentation emits a stable INFO log with elapsed milliseconds.

package.path = "./?.lua;" .. package.path

local messages = {}
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.logger"] = function()
    return {
        info = function(...)
            messages[#messages + 1] = { ... }
        end,
        dbg = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 2500 end }
end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end

local PluginUtil = require("weread.lib.plugin_util")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

PluginUtil.perf("reader_ready.total", 1250, "book=", "855706")
expect(messages[1] == nil, "performance log is disabled by default")

PluginUtil.set_perf_enabled(true)
PluginUtil.perf("reader_ready.total", 1250, "book=", "855706")
local message = messages[1]
expect(message ~= nil, "enabled performance log is emitted")
expect(message and message[1] == "[Perf]",
    "performance log has a stable marker")
expect(message and message[2] == "stage="
    and message[3] == "reader_ready.total",
    "performance log contains the stage")
expect(message and message[4] == "ms="
    and message[5] == "1250.0",
    "performance log contains elapsed milliseconds")

print(string.format(
    "plugin_util_perf_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
