-- Real SQLite transactions under LuaJIT, with a deterministic table codec in
-- place of KOReader's JSON dependency. No network or account data is involved.
-- Keep the system SQLite FFI bridge interpreted on macOS ARM.
require("jit").off()
local ffi = require("ffi")
ffi.cdef[[
typedef struct sqlite3 sqlite3; typedef struct sqlite3_stmt sqlite3_stmt;
int sqlite3_open(const char*, sqlite3**); int sqlite3_close(sqlite3*);
int sqlite3_exec(sqlite3*,const char*,void*,void*,char**);
const char *sqlite3_errmsg(sqlite3*);
int sqlite3_prepare_v2(sqlite3*,const char*,int,sqlite3_stmt**,const char**);
int sqlite3_bind_text(sqlite3_stmt*,int,const char*,int,void*);
int sqlite3_step(sqlite3_stmt*); int sqlite3_reset(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt*); int sqlite3_column_count(sqlite3_stmt*);
const unsigned char *sqlite3_column_text(sqlite3_stmt*,int);
]]
local loaded, sql = pcall(ffi.load, "sqlite3")
if not loaded then sql = ffi.load("libsqlite3.so.0") end
local function encode(value)
    if type(value) == "table" then
        local keys, out = {}, {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do out[#out + 1] = "[" .. encode(key) .. "]=" .. encode(value[key]) end
        return "{" .. table.concat(out, ",") .. "}"
    elseif type(value) == "string" then return string.format("%q", value)
    else return tostring(value) end
end
package.preload["json"] = function()
    return { encode = encode, decode = function(value) return assert(loadstring("return " .. value))() end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
local paths, legacy_entries, legacy_checkpoints = {}, {}, {}
local function connect(path)
    local ptr = ffi.new("sqlite3 *[1]")
    assert(sql.sqlite3_open(path, ptr) == 0)
    local db = { ptr = ptr[0] }
    local function check(rc)
        if rc ~= 0 and rc ~= 100 and rc ~= 101 then error(ffi.string(sql.sqlite3_errmsg(db.ptr))) end
        return rc
    end
    function db:exec(query) check(sql.sqlite3_exec(self.ptr, query, nil, nil, nil)) end
    function db:close() check(sql.sqlite3_close(self.ptr)) end
    function db.prepare(connection, query)
        local statement = ffi.new("sqlite3_stmt *[1]")
        check(sql.sqlite3_prepare_v2(connection.ptr, query, -1, statement, nil))
        local stmt = { ptr = statement[0], values = {} }
        function stmt:reset() check(sql.sqlite3_reset(self.ptr)); return self end
        function stmt:bind(...)
            self.values = { ... }
            for index, value in ipairs(self.values) do
                self.values[index] = tostring(value)
                check(sql.sqlite3_bind_text(self.ptr, index, self.values[index], -1,
                    ffi.cast("void*", -1)))
            end
            return self
        end
        function stmt:step()
            if check(sql.sqlite3_step(self.ptr)) ~= 100 then return nil end
            local row = {}
            for index = 0, sql.sqlite3_column_count(self.ptr) - 1 do
                local value = sql.sqlite3_column_text(self.ptr, index)
                row[index + 1] = value ~= nil and ffi.string(value) or nil
            end
            return row
        end
        function stmt:close() sql.sqlite3_finalize(self.ptr) end
        return stmt
    end
    return db
end
local legacy = {}
function legacy:open(book, create)
    if not paths[book] then
        if not create then return nil end
        paths[book] = os.tmpname()
    end
    return connect(paths[book])
end
function legacy:getDocument(path) return legacy_entries[path] end
function legacy:getSyncCheckpoint(path) return legacy_checkpoints[path] end
package.preload["weread.lib.external_annotations_db"] = function()
    return { new = function() return legacy end }
end
local Store = require("weread.lib.annotation_store")
return {
    new = function() return Store:new({}) end,
    legacy_entries = legacy_entries, legacy_checkpoints = legacy_checkpoints,
    cleanup = function()
        for _, path in pairs(paths) do
            os.remove(path); os.remove(path .. "-wal"); os.remove(path .. "-shm")
        end
    end,
}
