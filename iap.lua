-- love-iap: in-app purchases for LÖVE on Google Play and the App Store.
--
-- The one file a game requires. Everything platform-specific lives in a
-- native bridge (android/love-iap on Android, ios/LoveIap.swift on iOS and
-- macOS) that exports the same six C functions, reached here through LuaJIT's
-- FFI. Where there is no bridge -- desktop, a build without it, a symbol that
-- would not resolve -- every call is a no-op and iap.status() says why, so a
-- game can call this unconditionally on every platform.
--
-- **Nothing calls back into Lua from another thread.** The stores answer on
-- their own threads; the bridge turns every answer into one line on a queue,
-- and iap.update() (once a frame, from love.update) drains it and runs your
-- callbacks on the game thread.
--
-- **A purchase is finished only after the game has granted it.** onPurchase
-- runs first; only when it returns does this module acknowledge (Play) or
-- finish (StoreKit) the transaction. Until then the store keeps handing it
-- back on every launch, so a crash between "paid" and "granted" loses
-- nothing. The flip side is a crash after granting and before finishing can
-- grant a consumable twice; the token on `purchase.token` is there for a game
-- that wants to keep its own ledger and make that exactly-once.
--
-- **A game that grants on its own server** returns false from onPurchase,
-- sends purchase.token to the server, and calls iap.finish(id, token) once
-- the server has granted it. Until then the purchase stays unfinished and
-- comes back at the next launch, so the server's own record of tokens is
-- what keeps it from being granted twice.
--
-- **Non-consumables are remembered here**, in a small file in the save
-- directory, so iap.owns() answers offline and on the first frame. Each full
-- sync with the store (every launch on Android, iap.restore() on iOS) makes
-- that list match the store's, which is how a refund takes an item back.
--
--   local iap = require "iap"
--
--   iap.init{
--       products = {
--           { id = "coins_100", consumable = true },
--           { id = "full_game" },
--       },
--       onPurchase = function(id, purchase) ... end,  -- grant it, save it
--       onFail = function(id, reason) ... end,        -- optional
--   }
--
--   function love.update(dt) iap.update() ... end
--
-- See README.md for the whole API and the event protocol.

local iap = {}

local CDEF = [[
    int liap_start(const char *ids);
    void liap_buy(const char *id);
    void liap_finish(const char *token, int consume);
    void liap_restore(void);
    const char *liap_poll(void);
    const char *liap_error(void);
]]

local ffi, native
local cfg = {}
local defs = {}        -- id -> { id, consumable }
local products = {}    -- id -> what the store says about it (price, title, ...)
local saved = { owned = {}, granted = {} }
local finishing = {}   -- tokens sent to finish this session, awaiting "finished"
local seen = nil       -- ids reported inside an open sync; nil outside one
local mockQueue = {}
local mockCount = 0
local mocking = false   -- iap.init chose the mock store

local state, reason = "off", "iap.init has not been called"

-- --- Persistence ------------------------------------------------------------
--
-- One fact per line: "owned <product id>" for a non-consumable, "granted
-- <token>" for a consumable granted but not yet confirmed finished. Plain text
-- because it is tiny and because being able to read it is worth more than
-- hiding it -- a determined player can edit any local save anyway.

local function readSaved()
    saved = { owned = {}, granted = {} }
    if not cfg.file or not love.filesystem.getInfo(cfg.file) then return end
    for line in love.filesystem.lines(cfg.file) do
        local kind, value = line:match("^(%S+) (.+)$")
        if kind and saved[kind] then saved[kind][value] = true end
    end
end

local function writeSaved()
    if not cfg.file then return end
    local out = {}
    for kind, set in pairs(saved) do
        for value in pairs(set) do out[#out + 1] = kind .. " " .. value end
    end
    table.sort(out)
    love.filesystem.write(cfg.file, table.concat(out, "\n") .. "\n")
end

-- --- Native bridge ----------------------------------------------------------

local function connect()
    local ok, mod = pcall(require, "ffi")
    if not ok then return nil, "no FFI (not LuaJIT)" end

    local os = love.system.getOS()
    local lib
    if os == "Android" then
        local loaded, l = pcall(mod.load, "liap")
        if not loaded then return nil, "libliap.so not in the APK: " .. tostring(l) end
        lib = l
    elseif os == "iOS" or os == "OS X" then
        lib = mod.C
    else
        return nil, "no store on " .. os
    end

    -- pcall: a second iap.lua (or a reload) declaring the same functions again
    -- must not take the game down.
    pcall(mod.cdef, CDEF)

    -- Proved once here so nothing below needs its own pcall. On iOS this is
    -- where a missing LoveIap.swift (or a stripped symbol, see README) lands.
    if not pcall(function() return lib.liap_poll, lib.liap_error end) then
        return nil, "the liap_* functions are not linked into this build"
    end

    return lib, mod
end

local function split(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    return fields
end

local function call(name, ...)
    local fn = cfg[name]
    if fn then return fn(...) end
end

local function finish(token, consume)
    if token == "" or finishing[token] then return end
    finishing[token] = true
    if native then
        native.liap_finish(token, consume and 1 or 0)
    else
        mockQueue[#mockQueue + 1] = { "finished", token, "ok" }
    end
end

local function revoke(id)
    if not saved.owned[id] then return end
    saved.owned[id] = nil
    writeSaved()
    call("onRevoke", id)
end

-- --- Events -----------------------------------------------------------------

local function onPurchase(f)
    local id, token, status = f[2], f[3], f[4]
    if status == "pending" then
        -- Paid by a slow method (cash, bank transfer). Nothing is granted yet;
        -- the same purchase comes back as "purchased" when it clears.
        call("onPending", id)
        return
    end

    if seen then seen[id] = true end

    local def = defs[id]
    if not def then
        -- Not in iap.init's list: left alone, unfinished, for whichever build
        -- does know it. (Play refunds an unacknowledged purchase after three days.)
        return
    end

    local purchase = {
        id = id,
        token = token,
        quantity = tonumber(f[6]) or 1,
        order = f[7] ~= "" and f[7] or nil,
        restored = seen ~= nil,
    }

    if def.consumable then
        if not saved.granted[token] then
            if call("onPurchase", id, purchase) == false then return end
            saved.granted[token] = true
            writeSaved()
        end
        finish(token, true)
    else
        if not saved.owned[id] then
            if call("onPurchase", id, purchase) == false then return end
            saved.owned[id] = true
            writeSaved()
        end
        if f[5] ~= "1" then finish(token, false) end
    end
end

local handlers = {
    ready = function()
        state, reason = mocking and "mock" or "ready", nil
        call("onReady")
    end,

    unavailable = function(f)
        state, reason = "unavailable", f[2]
        call("onUnavailable", f[2])
    end,

    product = function(f)
        local id = f[2]
        if not defs[id] then return end
        products[id] = {
            id = id,
            consumable = defs[id].consumable,
            price = f[3],
            title = f[4],
            description = f[5],
            currency = f[6],
            micros = tonumber(f[7]) or 0,
        }
        call("onProduct", id, products[id])
    end,

    missing = function(f)
        -- The store has never heard of this id: a typo, a product not yet
        -- active in the console, or a build whose app id does not match.
        call("onFail", f[2], "unknown_product")
    end,

    purchase = onPurchase,

    failed = function(f)
        call("onFail", f[2], f[3])
    end,

    finished = function(f)
        local token, result = f[2], f[3]
        finishing[token] = nil
        -- Once the store confirms, it will never hand this token back, so the
        -- ledger entry that guarded against a second grant can go.
        if result == "ok" and saved.granted[token] then
            saved.granted[token] = nil
            writeSaved()
        end
    end,

    revoked = function(f)
        revoke(f[2])
    end,

    syncing = function()
        seen = {}
    end,

    synced = function()
        if seen and cfg.revoke ~= false then
            for id in pairs(saved.owned) do
                if defs[id] and not seen[id] then revoke(id) end
            end
        end
        seen = nil
        call("onSync")
    end,

    error = function(f)
        call("onError", f[2], f[3])
    end,
}

local function dispatch(f)
    local handler = handlers[f[1]]
    if handler then handler(f) end
end

-- --- Public API -------------------------------------------------------------

--- Start the store. Call once, from love.load.
--  config.products   list of { id = "...", consumable = true|nil }
--  config.onPurchase (id, purchase) grant it; return false to leave it
--                    unfinished and have it delivered again later
--  config.onRevoke   (id) a non-consumable was refunded or is no longer owned
--  config.onFail     (id, reason) a purchase did not happen
--  config.onPending  (id) a purchase is awaiting payment
--  config.onProduct  (id, product) a price/title arrived from the store
--  config.onReady, config.onUnavailable(reason), config.onSync,
--  config.onError(what, reason)
--  config.file       save file name, or false to keep nothing (default "iap.txt")
--  config.revoke     false to never take a non-consumable back (default true)
--  config.mock       true to fake a store where there is none (desktop testing)
function iap.init(config)
    cfg = config or {}
    if cfg.file == nil then cfg.file = "iap.txt" end

    defs, products, finishing, seen = {}, {}, {}, nil
    local ids = {}
    for _, p in ipairs(cfg.products or {}) do
        assert(type(p.id) == "string" and not p.id:find("[,%s]"), "iap: bad product id " .. tostring(p.id))
        defs[p.id] = { id = p.id, consumable = p.consumable and true or false }
        ids[#ids + 1] = p.id
    end

    readSaved()

    local lib, second = connect()
    local why
    if lib then
        native, ffi = lib, second
    else
        native, why = nil, second
    end
    mockQueue, mockCount, mocking = {}, 0, false

    if native then
        if native.liap_start(table.concat(ids, ",")) == 1 then
            state, reason = "starting", nil
        else
            state, reason = "unavailable", ffi.string(native.liap_error())
            native = nil
        end
    elseif cfg.mock then
        mocking = true
        state, reason = "mock", why
        for _, id in ipairs(ids) do
            mockQueue[#mockQueue + 1] = { "product", id, "$0.99", id, "Mock product", "USD", "990000" }
        end
        mockQueue[#mockQueue + 1] = { "ready" }
    else
        state, reason = "unavailable", why
    end
end

--- Drain the store's answers and run callbacks. Call every frame.
function iap.update()
    if native then
        while true do
            local line = native.liap_poll()
            if line == nil then break end
            dispatch(split(ffi.string(line)))
        end
    end
    if #mockQueue > 0 then
        local queue = mockQueue
        mockQueue = {}
        for _, f in ipairs(queue) do dispatch(f) end
    end
end

--- Open the store's purchase sheet. The answer arrives later, through
--  onPurchase, onPending or onFail.
function iap.buy(id)
    if not defs[id] then
        call("onFail", id, "unknown_product")
    elseif native then
        native.liap_buy(id)
    elseif mocking then
        mockCount = mockCount + 1
        -- Unique across launches too, so a server that keeps a ledger of
        -- tokens does not mistake the next session's mock-1 for a replay.
        local token = ("mock-%d-%d"):format(os.time(), mockCount)
        mockQueue[#mockQueue + 1] = { "purchase", id, token, "purchased", "0", "1", "" }
    else
        call("onFail", id, "unavailable")
    end
end

--- Finish a purchase that onPurchase left unfinished (by returning false),
--  once the game has granted it some other way -- typically on its server.
--  Consumables are consumed; non-consumables are recorded as owned and
--  acknowledged. Nothing is granted here and onPurchase does not run again.
function iap.finish(id, token)
    local def = defs[id]
    if not def or not token or token == "" then return end
    if not def.consumable and not saved.owned[id] then
        saved.owned[id] = true
        writeSaved()
    end
    finish(token, def.consumable)
end

--- Ask the store for everything this account owns. Required on iOS behind a
--  visible "Restore purchases" button (it may ask for an Apple ID password);
--  on Android it is what happens at every launch anyway.
function iap.restore()
    if native then
        native.liap_restore()
    elseif mocking then
        mockQueue[#mockQueue + 1] = { "syncing" }
        for id in pairs(saved.owned) do
            mockQueue[#mockQueue + 1] = { "purchase", id, "", "purchased", "1", "1", "" }
        end
        mockQueue[#mockQueue + 1] = { "synced" }
    end
end

--- Whether a non-consumable is owned. Answers from the save file, so it is
--  right offline and before the store has said anything.
function iap.owns(id)
    return saved.owned[id] == true
end

--- What the store said about a product: { id, consumable, price (formatted,
--  in the player's currency), title, description, currency, micros }, or nil
--  until it has said it. Show `price` verbatim; never hard-code one.
function iap.product(id)
    return products[id]
end

function iap.price(id)
    return products[id] and products[id].price
end

--- "off" | "starting" | "ready" | "unavailable" | "mock", and a reason when
--  it is not ready.
function iap.status()
    return state, reason
end

function iap.available()
    return state == "ready" or state == "mock"
end

return iap
