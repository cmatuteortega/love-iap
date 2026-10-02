-- Tests for iap.lua, run with plain LuaJIT (no LÖVE):
--
--   cc -shared -fPIC -o test/libliap.so test/fake_liap.c
--   LD_LIBRARY_PATH=test luajit test/run.lua
--
-- iap.lua goes through its real FFI path: `love.system.getOS` claims Android,
-- so it ffi.load()s "liap", which finds test/libliap.so -- a fake store whose
-- events the tests script with fake_push and whose calls they read back with
-- fake_calls. `love.filesystem` is an in-memory table.

package.path = "./?.lua;" .. package.path

local ffi = require "ffi"

local files = {}
local os_name = "Android"
love = {
    system = { getOS = function() return os_name end },
    filesystem = {
        getInfo = function(name) return files[name] and { type = "file" } or nil end,
        lines = function(name) return files[name]:gmatch("([^\n]*)\n") end,
        write = function(name, data) files[name] = data return true end,
    },
}

local iap = require "iap"
local fake = ffi.load("liap")
ffi.cdef [[
    void fake_push(const char *line);
    const char *fake_calls(void);
    void fake_reset(void);
]]

local function push(...) fake.fake_push(table.concat({ ... }, "\t")) end
local function calls()
    local s = ffi.string(fake.fake_calls())
    fake.fake_reset()
    return s
end

local passed, failed = 0, 0
local function check(name, cond)
    if cond then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name) end
end

local log
local function start(extra)
    log = {}
    local config = {
        products = { { id = "coins", consumable = true }, { id = "full" } },
        onPurchase = function(id, p) log[#log + 1] = "grant " .. id .. " " .. p.token .. (p.restored and " restored" or "") end,
        onRevoke = function(id) log[#log + 1] = "revoke " .. id end,
        onFail = function(id, why) log[#log + 1] = "fail " .. id .. " " .. why end,
        onPending = function(id) log[#log + 1] = "pending " .. id end,
    }
    for k, v in pairs(extra or {}) do config[k] = v end
    iap.init(config)
end
local function said() local s = table.concat(log, "\n") log = {} return s end

-- Start-up
start()
check("start passes the ids", calls() == "start coins,full\n")
check("starting before ready", iap.status() == "starting")
push("ready")
push("product", "coins", "€1,09", "Coins", "A bag", "EUR", "1090000")
push("missing", "full")
iap.update()
check("ready", iap.available())
check("price", iap.price("coins") == "€1,09" and iap.product("coins").micros == 1090000)
check("missing product reported", said() == "fail full unknown_product")

-- A consumable: granted, recorded, consumed, then forgotten once confirmed
iap.buy("coins")
check("buy reaches native", calls() == "buy coins\n")
push("purchase", "coins", "tok1", "purchased", "0", "1", "GPA.1")
iap.update()
check("consumable granted", said() == "grant coins tok1")
check("consumable consumed", calls() == "finish tok1 1\n")
check("ledger holds it until finished", files["iap.txt"]:find("granted tok1"))
push("purchase", "coins", "tok1", "purchased", "0", "1", "GPA.1")
iap.update()
check("no second grant, no second finish in flight", said() == "" and calls() == "")
push("finished", "tok1", "ok")
iap.update()
check("ledger cleared", not files["iap.txt"]:find("tok1"))

-- Crash between grant and finish: next launch the store hands it back
push("purchase", "coins", "tok2", "purchased", "0", "1", "")
iap.update()
said() calls()
start()
calls()
push("syncing") push("purchase", "coins", "tok2", "purchased", "0", "1", "") push("synced")
iap.update()
check("not granted twice across launches", said() == "")
check("but finished again", calls() == "finish tok2 1\n")

-- A non-consumable: owned and acknowledged; already-acknowledged is left alone
push("purchase", "full", "tokF", "purchased", "0", "1", "")
iap.update()
check("non-consumable granted", said() == "grant full tokF" and iap.owns("full"))
check("non-consumable acknowledged", calls() == "finish tokF 0\n")
push("syncing") push("purchase", "full", "tokF", "purchased", "1", "1", "") push("synced")
iap.update()
check("owned stays owned, no regrant", said() == "" and calls() == "" and iap.owns("full"))

-- Persisted across launches, revoked by a sync that no longer lists it
start()
calls()
check("ownership persisted", iap.owns("full"))
push("syncing") push("synced")
iap.update()
check("refund revokes", said() == "revoke full" and not iap.owns("full"))

-- Restored on a new install
files = {}
start()
calls()
push("syncing") push("purchase", "full", "tokF", "purchased", "1", "1", "") push("synced")
iap.update()
check("restore grants, flagged restored", said() == "grant full tokF restored" and iap.owns("full"))

-- revoke = false keeps it
start { revoke = false }
calls()
push("syncing") push("synced")
iap.update()
check("revoke=false keeps ownership", iap.owns("full"))

-- onPurchase returning false leaves the purchase unfinished, for iap.finish
files = {}
start { onPurchase = function() return false end }
calls()
push("purchase", "coins", "tok3", "purchased", "0", "1", "")
iap.update()
check("refused grant is not finished", calls() == "" and not (files["iap.txt"] or ""):find("tok3"))
iap.finish("coins", "tok3")
check("finish consumes a refused consumable", calls() == "finish tok3 1\n" and not (files["iap.txt"] or ""):find("tok3"))
push("purchase", "full", "tokG", "purchased", "0", "1", "")
iap.update()
check("refused non-consumable not owned yet", calls() == "" and not iap.owns("full"))
iap.finish("full", "tokG")
check("finish acknowledges and owns", calls() == "finish tokG 0\n" and iap.owns("full"))
iap.finish("nope", "tokN")
iap.finish("coins", "")
check("finish ignores unknown ids and empty tokens", calls() == "")

-- Pending, failures, strangers
start()
calls()
push("purchase", "coins", "", "pending", "0", "1", "")
push("failed", "coins", "cancelled")
push("purchase", "someone_else", "tokX", "purchased", "0", "1", "")
iap.update()
check("pending and fail reported", said() == "pending coins\nfail coins cancelled")
check("unknown product left alone", calls() == "")
iap.buy("nope")
check("buying an undeclared id fails locally", said() == "fail nope unknown_product" and calls() == "")

-- Desktop: no store, or a mock one
os_name = "Linux"
files = {}
start()
check("desktop is unavailable", iap.status() == "unavailable" and not iap.available())
iap.buy("coins")
check("buying on desktop fails", said() == "fail coins unavailable")
start { mock = true }
iap.update()
check("mock is available with prices", iap.available() and iap.price("full") == "$0.99")
iap.buy("full")
iap.update()
iap.update()
local s = said() check("mock purchase grants", s:match("^grant full mock%-%d+%-1$") and iap.owns("full"))
check("mock status survives ready", iap.status() == "mock")
iap.restore()
iap.update()
check("mock restore keeps what is owned", said() == "" and iap.owns("full"))
files["iap.txt"] = nil
start { mock = true }
iap.update()
check("mock without save owns nothing", not iap.owns("full"))

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
