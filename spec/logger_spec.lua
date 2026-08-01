package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

local calls = {}
package.preload["logger"] = function()
    local function capture(level, ...)
        calls[#calls + 1] = {
            level = level,
            args = { ... },
        }
    end
    return {
        dbg = function(...) capture("dbg", ...) end,
        info = function(...) capture("info", ...) end,
        warn = function(...) capture("warn", ...) end,
        err = function(...) capture("err", ...) end,
    }
end

local logger = require("weread.lib.logger")
logger.info("default message", "value")
logger.scoped("HTTP").err("scoped message")

expect(#calls == 2, "logger did not forward both calls")
expect(calls[1].level == "info", "default logger changed the level")
expect(calls[1].args[1] == "[WeRead]", "default logger omitted the prefix")
expect(calls[1].args[2] == "default message"
    and calls[1].args[3] == "value", "default logger changed arguments")
expect(calls[2].level == "err", "scoped logger changed the level")
expect(calls[2].args[1] == "[WeRead][HTTP]",
    "scoped logger omitted the scoped prefix")
expect(calls[2].args[2] == "scoped message",
    "scoped logger changed arguments")

print(("logger_spec: %d checks"):format(checks))
