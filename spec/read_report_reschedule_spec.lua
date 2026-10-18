-- An interval change must not interrupt a report that is already in flight.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            local noop = function() end
            return { dbg = noop, info = noop, warn = noop, err = noop }
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local function make_report(opts)
    opts = opts or {}
    local report = setmetatable({}, ReadReport)
    report.settings = {
        get = function(_self, key)
            if key == "read_report" then
                return { enabled = true, interval_seconds = opts.interval or 30 }
            end
        end,
    }
    report.scheduled = {}
    report.unscheduled = {}
    report.scheduler = {
        scheduleIn = function(_self, delay, fn)
            table.insert(report.scheduled, { delay = delay, fn = fn })
        end,
        unschedule = function(_self, fn)
            table.insert(report.unscheduled, fn)
        end,
    }
    report.task = opts.task
    report.job = opts.job
    report.generation = 1
    return report
end

-- Not running: there is nothing to re-arm.
local idle = make_report()
expect(idle:reschedule("interval_changed") == false,
    "an idle report should not reschedule")
expect(#idle.scheduled == 0 and #idle.unscheduled == 0,
    "an idle report touched the scheduler")

-- A job is in flight: leave it alone so it can write its result (and any
-- renewed credentials) back; the poller picks the new interval afterwards.
local task = function() end
local busy = make_report({ task = task, job = { pid = 4242 }, interval = 60 })
expect(busy:reschedule("interval_changed") == false,
    "an in-flight job must not be rescheduled")
expect(#busy.unscheduled == 0, "an in-flight job was unscheduled (would abandon it)")
expect(#busy.scheduled == 0, "an in-flight job was re-armed too early")

-- Only waiting: re-arm the pending tick with the new interval.
local waiting = make_report({ task = task, interval = 60 })
expect(waiting:reschedule("interval_changed") == true,
    "a waiting report should be rescheduled")
expect(#waiting.unscheduled == 1 and waiting.unscheduled[1] == task,
    "the pending tick was not unscheduled")
expect(#waiting.scheduled == 1, "the pending tick was not re-armed")
expect(waiting.scheduled[1].delay == 60, "the tick was not re-armed with the new interval")
expect(waiting.scheduled[1].fn == task, "the tick was re-armed with a different task")

-- The lower bound still applies.
local clamped = make_report({ task = task, interval = 5 })
clamped:reschedule("interval_changed")
expect(clamped.scheduled[1].delay == 10, "the interval lower bound was not applied")

print(("read_report_reschedule_spec: %d checks"):format(checks))
