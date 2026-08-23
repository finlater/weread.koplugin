local I18n = require("weread.lib.i18n")
local logger = require("weread.lib.logger")
local ok_time, time = pcall(require, "ui/time")
if not ok_time then
    time = { now = function() return 0 end }
end
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(text) return text end

local PluginUtil = {
    T = T,
    unpack_args = unpack or table.unpack,
    perf_enabled = false,
}

function PluginUtil.tr(text)
    return I18n.tr(text)
end

function PluginUtil.log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

function PluginUtil.display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

function PluginUtil.file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

function PluginUtil.set_perf_enabled(enabled)
    PluginUtil.perf_enabled = enabled == true
end

function PluginUtil.perf(stage, started, ...)
    if not PluginUtil.perf_enabled then
        return
    end
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info("[Perf]", "stage=", stage,
        "ms=", string.format("%.1f", elapsed), ...)
end

function PluginUtil.thought_perf(stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.dbg("thought_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed), ...)
end

return PluginUtil
