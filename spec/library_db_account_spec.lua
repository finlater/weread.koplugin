package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local LibraryDB = require("weread.lib.library_db")
local current_account = { user_vid = "10001", login_method = "qr" }
local settings = {
    data_dir = "/tmp/weread-account-test",
    get = function(_self, key, default)
        if key == "account" then return current_account end
        return default
    end,
}

local db = LibraryDB:new(settings)
local first_path = db:databasePath()
expect(type(first_path) == "string", "identified account has no database path")
expect(not first_path:find("10001", 1, true), "database filename leaked the user VID")

current_account = { user_vid = "20002", login_method = "qr" }
local second_path = db:databasePath()
expect(first_path ~= second_path, "different accounts shared a database path")

current_account = { user_vid = "10001", login_method = "qr" }
expect(db:databasePath() == first_path, "switching back did not restore the account database")

current_account = { user_vid = "", login_method = "" }
expect(db:databasePath() == nil, "logged-out state retained an account database")

print(("library_db_account_spec: %d checks"):format(checks))
