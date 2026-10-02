-- love-iap's example: every product as a button, its price from the store,
-- and a restore button. On desktop it runs against the mock store, so the
-- whole flow can be clicked through without a phone. From the repo root:
--
--   cp iap.lua example/ && love example
--
-- The product ids are placeholders: create products with these ids in Play
-- Console / App Store Connect (or change them here) to see real prices.

local iap = require "iap"

local PRODUCTS = {
    { id = "coins_100", consumable = true },
    { id = "full_game" },
}

local coins = 0
local log = {}
local buttons = {}

local function say(text)
    table.insert(log, 1, text)
    log[9] = nil
end

function love.load()
    if love.filesystem.getInfo("coins.txt") then
        coins = tonumber(love.filesystem.read("coins.txt")) or 0
    end

    iap.init {
        products = PRODUCTS,
        mock = love.system.getOS() ~= "Android" and love.system.getOS() ~= "iOS",
        onPurchase = function(id, purchase)
            if id == "coins_100" then
                coins = coins + 100 * purchase.quantity
                love.filesystem.write("coins.txt", tostring(coins))  -- saved before returning
            end
            say((purchase.restored and "restored " or "bought ") .. id)
        end,
        onRevoke = function(id) say("revoked " .. id) end,
        onFail = function(id, reason) say("failed " .. id .. ": " .. reason) end,
        onPending = function(id) say("pending " .. id) end,
        onError = function(what, reason) say("error " .. what .. ": " .. reason) end,
    }
end

function love.update()
    iap.update()
end

local function layout()
    local w = love.graphics.getWidth()
    local bw, bh, y = math.min(w - 40, 420), 56, 120
    buttons = {}
    for _, p in ipairs(PRODUCTS) do
        buttons[#buttons + 1] = { x = 20, y = y, w = bw, h = bh, id = p.id }
        y = y + bh + 12
    end
    buttons[#buttons + 1] = { x = 20, y = y, w = bw, h = bh, restore = true }
    return y + bh + 20
end

function love.draw()
    local status, reason = iap.status()
    love.graphics.print("store: " .. status .. (reason and (" (" .. reason .. ")") or ""), 20, 20)
    love.graphics.print("coins: " .. coins .. "    full game: " .. (iap.owns("full_game") and "owned" or "no"), 20, 50)

    local y = layout()
    for _, b in ipairs(buttons) do
        love.graphics.rectangle("line", b.x, b.y, b.w, b.h)
        local label
        if b.restore then
            label = "Restore purchases"
        else
            label = b.id .. "    " .. (iap.price(b.id) or "...")
            if iap.owns(b.id) then label = label .. "    (owned)" end
        end
        love.graphics.print(label, b.x + 12, b.y + b.h / 2 - 7)
    end

    for i, line in ipairs(log) do
        love.graphics.print(line, 20, y + (i - 1) * 20)
    end
end

local function press(x, y)
    for _, b in ipairs(buttons) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            if b.restore then iap.restore() else iap.buy(b.id) end
        end
    end
end

function love.mousepressed(x, y, button, istouch)
    if not istouch then press(x, y) end
end

function love.touchpressed(id, x, y)
    press(x, y)
end
