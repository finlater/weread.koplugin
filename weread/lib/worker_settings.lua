local M = {}

local function auth_fingerprint(settings)
    if not settings or type(settings.get) ~= "function" then return "" end
    local cookies = settings:get("cookies", {}) or {}
    local keys = {}
    for key in pairs(cookies) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. tostring(cookies[key])
    end
    parts[#parts + 1] = "ticket=" .. tostring(settings:get("wr_ticket", ""))
    parts[#parts + 1] = "wrpa=" .. tostring(settings:get("wr_wrpa", ""))
    return table.concat(parts, ";")
end

function M.capture(settings)
    local changed = false
    settings.flush = function() end
    local update_auth = settings.update_auth
    if type(update_auth) == "function" then
        settings.update_auth = function(object, credentials, options)
            changed = true
            options = options or {}
            options.flush = false
            return update_auth(object, credentials, options)
        end
    end
    return function()
        if not changed or type(settings.get) ~= "function" then return nil end
        return {
            cookies = settings:get("cookies", {}),
            wr_ticket = settings:get("wr_ticket", ""),
            wr_wrpa = settings:get("wr_wrpa", ""),
        }
    end
end

function M.fingerprint(settings)
    return auth_fingerprint(settings)
end

function M.merge(settings, expected_fingerprint, auth)
    if type(auth) ~= "table" then return false end
    if not settings or type(settings.update_auth) ~= "function" then return false end
    if auth_fingerprint(settings) ~= expected_fingerprint then return false end
    settings:update_auth(auth, { replace_cookies = true })
    return true
end

return M
