-- Process-local knowledge that the current WeRead session has been invalidated.
--
-- A replaced or expired server session cannot live in settings: the cookies
-- still exist locally, so every static "is a cookie configured" gate keeps
-- passing and the failure only surfaces mid-flight. This module carries the
-- knowledge for the lifetime of the process so the UI can ask the user to scan
-- again instead of failing with a generic error.
--
-- Intentionally in-memory and I/O free: any successful cookie renewal or QR
-- login clears it, and a restart starts from a clean slate.

local M = {}

local state = {
    invalid = false,
    reason = nil,
    notified = false,
}

-- Remember that the server rejected this session. `reason` is a classification
-- name (for example "session_replaced"), never a credential.
function M.mark_invalid(reason)
    state.invalid = true
    if type(reason) == "string" and reason ~= "" then
        state.reason = reason
    end
end

function M.clear()
    state.invalid = false
    state.reason = nil
    state.notified = false
end

function M.is_invalid()
    return state.invalid
end

function M.reason()
    return state.reason
end

-- At most one notification per invalid session, so background tasks cannot
-- repeatedly interrupt the user with the same login prompt.
function M.should_notify()
    return state.invalid and not state.notified
end

function M.mark_notified()
    state.notified = true
end

return M
