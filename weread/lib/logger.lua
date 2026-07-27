local ok, base_logger = pcall(require, "logger")
if not ok then
    base_logger = nil
end

local LEVELS = { "dbg", "info", "warn", "err" }

local function build(prefix)
    local wrapped = {}
    for _, level in ipairs(LEVELS) do
        local method = level
        wrapped[method] = function(...)
            if base_logger and type(base_logger[method]) == "function" then
                base_logger[method](prefix, ...)
            end
        end
    end
    return wrapped
end

local Logger = build("[WeRead]")

function Logger.scoped(scope)
    assert(type(scope) == "string" and scope ~= "", "logger scope is required")
    return build("[WeRead][" .. scope .. "]")
end

return Logger
