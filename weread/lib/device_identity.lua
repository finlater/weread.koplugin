-- Per-device, non-secret identity for the WeRead weblogin chain.
--
-- The server keeps web sessions separate per device fingerprint: two sessions
-- logged in through the weblogin chain with different `fp` values coexist,
-- while sessions created without device identity replace each other (upstream
-- issue #158). The fingerprint is a client-generated SHA-256 of a random seed;
-- the seed is persisted in settings and survives account resets so a device
-- keeps its identity across accounts (mirrors the official per-device identity
-- persistence).
--
-- The seed is random device metadata, not a credential: it is never derived
-- from user data and it reveals nothing about the account.

local Crypto = require("weread.lib.crypto")

local M = {}

local SEED_BYTES = 16

local function random_seed()
    local handle = io.open("/dev/urandom", "rb")
    if handle then
        local bytes = handle:read(SEED_BYTES)
        handle:close()
        if bytes and #bytes == SEED_BYTES then
            return (bytes:gsub(".", function(ch)
                return string.format("%02x", ch:byte())
            end))
        end
    end
    -- Fallback for platforms without /dev/urandom: combine time sources so a
    -- fresh install still gets a distinct seed.
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    local parts = {}
    for i = 1, SEED_BYTES do
        parts[i] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(parts)
end

function M.ensure(settings)
    local seed = settings:get("device_seed", "")
    if type(seed) ~= "string" or seed == "" then
        seed = random_seed()
        settings:set("device_seed", seed)
        settings:flush()
    end
    return {
        fp = Crypto.sha256_hex(seed),
    }
end

return M
