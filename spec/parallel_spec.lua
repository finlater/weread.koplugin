package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local subprocess_supported = true
local android = false
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_self, _delay, callback) callback() end }
end
package.preload["ffi/util"] = function()
    return setmetatable({
        isSubProcessDone = function() return true end,
        terminateSubProcess = function() end,
    }, {
        __index = function(_table, key)
            if key == "runInSubProcess" and subprocess_supported then
                return function() return 1 end
            end
        end,
    })
end
package.preload["device"] = function()
    return { isAndroid = function() return android end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {}
end

local Parallel = require("weread.lib.parallel")

local low = Parallel.recommended(256)
expect(low.chapters == 1 and low.comments == 1 and low.images == 1,
    "256 MB preset should remain serial")
local medium = Parallel.recommended(1024)
expect(medium.chapters == 1 and medium.comments == 3 and medium.images == 3,
    "1 GB preset was wrong")
local high = Parallel.recommended(4096)
expect(high.chapters == 1 and high.comments == 6 and high.images == 6,
    "high-memory preset was wrong")

Parallel.detect_memory_mb = function() return 2048 end
local automatic = Parallel.config({
    get = function()
        return {
            concurrency_auto = true,
            chapter_concurrency = 8,
            comment_concurrency = 8,
            image_concurrency = 8,
        }
    end,
})
expect(automatic.automatic and automatic.chapters == 1
        and automatic.comments == 4 and automatic.images == 4,
    "automatic config did not use the memory preset")

local manual = Parallel.config({
    get = function()
        return {
            concurrency_auto = false,
            chapter_concurrency = 0,
            comment_concurrency = 5.9,
            image_concurrency = 99,
        }
    end,
})
expect(not manual.automatic and manual.chapters == 1
        and manual.comments == 5 and manual.images == 8,
    "manual config was not clamped to 1-8")

Parallel.detect_memory_mb = function() return nil end
local unknown_memory = Parallel.config({ get = function() return {} end })
expect(unknown_memory.supported and unknown_memory.chapters == 1
        and unknown_memory.comments == 1 and unknown_memory.images == 1,
    "unknown memory should use the conservative serial preset")

android = true
local android_config = Parallel.config({
    get = function()
        return {
            concurrency_auto = false,
            chapter_concurrency = 8,
            comment_concurrency = 8,
            image_concurrency = 8,
        }
    end,
})
expect(not android_config.supported and android_config.chapters == 1
        and android_config.comments == 1 and android_config.images == 1,
    "Android should not fork network workers that may enter ART/JNI")
android = false

subprocess_supported = false
local unsupported = Parallel.config({ get = function() return {} end })
expect(not unsupported.supported and unsupported.chapters == 1
        and unsupported.comments == 1 and unsupported.images == 1,
    "unsupported platforms should fall back to serial requests")

print(("parallel_spec: %d checks"):format(checks))
