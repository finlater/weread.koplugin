package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local SessionState = require("weread.lib.session_state")

expect(SessionState.is_invalid() == false, "a fresh session must be valid")
expect(SessionState.reason() == nil, "a fresh session must not have a reason")
expect(SessionState.should_notify() == false,
    "a valid session must not notify")

SessionState.mark_invalid("session_replaced")
expect(SessionState.is_invalid() == true, "mark_invalid did not invalidate")
expect(SessionState.reason() == "session_replaced",
    "mark_invalid did not record the reason")
expect(SessionState.should_notify() == true,
    "an invalid session should notify once")

SessionState.mark_notified()
expect(SessionState.should_notify() == false,
    "should_notify fired more than once")
expect(SessionState.is_invalid() == true,
    "mark_notified must not clear the invalid state")

SessionState.mark_invalid("login_timeout")
expect(SessionState.reason() == "login_timeout",
    "mark_invalid did not update the reason")
expect(SessionState.should_notify() == false,
    "re-marking must not re-arm the notification")

SessionState.clear()
expect(SessionState.is_invalid() == false, "clear did not restore validity")
expect(SessionState.reason() == nil, "clear did not reset the reason")
expect(SessionState.should_notify() == false,
    "clear re-armed the notification")

SessionState.mark_invalid()
expect(SessionState.is_invalid() == true,
    "mark_invalid without a reason failed")
expect(SessionState.reason() == nil, "a missing reason must stay nil")

print(("session_state_spec: %d checks"):format(checks))
