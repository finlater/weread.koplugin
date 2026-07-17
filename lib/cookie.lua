local Cookie = {}

function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        table.insert(parts, key .. "=" .. value)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function Cookie.merge(cookies, updates)
    local merged = {}
    for key, value in pairs(cookies or {}) do
        merged[key] = value
    end
    for key, value in pairs(updates or {}) do
        merged[key] = value
    end
    return merged
end

function Cookie.merge_set_cookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then
        return cookies
    end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            Cookie.merge_set_cookie(cookies, value)
        end
        return cookies
    end
    local allowed = {
        ptcz = true,
        RK = true,
        pgv_pvid = true,
    }
    for name, value in set_cookie:gmatch("([%w_]+)=([^;,\r\n]*)") do
        if name:match("^wr_") or allowed[name] then
            if value == "" then
                cookies[name] = nil
            else
                cookies[name] = value
            end
        end
    end
    return cookies
end

function Cookie.has_login_cookie(cookies)
    -- Modern WeRead uses wr_gid instead of wr_skey; fall back to wr_gid as the login credential.
    if cookies and type(cookies.wr_skey) == "string" and #cookies.wr_skey >= 8 then
        return true
    end
    return cookies and type(cookies.wr_gid) == "string" and #cookies.wr_gid >= 5
end

return Cookie
