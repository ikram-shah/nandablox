-- Red vs. Blue (live): every tunable number in one place. Pure data, no Roblox
-- services, so the headless tests (roblox/tests/, run with Lune) read the same
-- constants the server plays with.

local Config = {}

------------------------------------------------------------------------ scoring

Config.ESCAPE_POINTS = 10 -- red, per attack that pays out
Config.CATCH_POINTS = 1 -- blue, per threat flagged before it pays out
Config.FALSE_ALARM_POINTS = -1 -- blue, per honest envelope or card flagged

------------------------------------------------------------------------ rounds

Config.ROUND_SECONDS = 180
Config.INTERMISSION_SECONDS = 12 -- results on screen, then the next round
Config.TOKENS_PER_ROUND = 4 -- red's attacks per round, shared by the team
Config.ATTACK_COOLDOWN = 4 -- seconds between two red attacks (anti-mash)

------------------------------------------------------------------------ the town

-- NANDA Town's defaults: forging is blocked, card spoofing works.
Config.DEFAULT_LAYERS = { auth = "hmac.v1", registry = "index.v1", transport = "memory.v1" }
Config.LAYER_OPTIONS = {
	auth = { "hmac.v1", "plain.v1" },
	registry = { "index.v1", "index.owned.v1" },
}
-- Layers persist across rounds (the council governs the town, not one round).
Config.RESET_LAYERS_EACH_ROUND = false

Config.SELLERS = { "seller-a", "seller-b" }
Config.BUYERS = { "buyer-1", "buyer-2", "buyer-3" }
Config.ATTACKER = "red-team" -- red's account; payouts land here
Config.BUYER_BALANCE = 30000 -- cents per buyer per round
Config.LIST_PRICE = { ["seller-a"] = 1995, ["seller-b"] = 2095 } -- cents per widget
Config.QUANTITY = 2

-- Transport: one hop is one courier trip on the road.
Config.HOP_SECONDS = 1.6
Config.THINK_SECONDS = 0.6 -- an agent's reply delay after a delivery
-- The trade-off the council weighs: stronger layers cost throughput.
Config.HMAC_HOP_EXTRA = 1.1 -- signature check per hop under hmac.v1
Config.OWNED_LOOKUP_EXTRA = 4.0 -- ownership check per registry lookup under index.owned.v1
Config.BUYER_REST = { 10, 18 } -- seconds a buyer rests between deals (uniform)
Config.BUYER_FIRST_DEAL = { 2, 9 } -- first deal start per buyer (uniform)
-- Honest transport faults, so not everything odd on the road is an attack.
Config.DUPLICATE_DELIVERY_RATE = 0.15 -- a delivery crate arrives twice
Config.DROP_QUOTE_RATE = 0.08 -- a quote request is dropped; the buyer retries
Config.RETRY_SECONDS = 2.0

------------------------------------------------------------------------ attacks

Config.FORGE_WINDOW = 12 -- seconds from a forged invoice to its payout
Config.FORGE_CENTS = 3000 -- what a forged invoice asks for
Config.SPOOF_UNDERCUT = 0.8 -- a spoofed card lists at this fraction of the cheapest price
-- Payee aliases on forged invoices: none of them is on the notice board.
Config.PAYEE_ALIASES = { "seller-a.billing", "se11er-b", "seller-a-payments", "sellr-b" }
Config.FALSE_ALARM_STALL = 4 -- seconds an honest envelope or card is held after a false alarm

------------------------------------------------------------------------ bots

-- "auto": on whenever that team has no humans; "on" / "off" force it.
Config.RED_BOT = "auto"
Config.BLUE_BOT = "auto"
Config.RED_BOT_FIRST = 14 -- seconds into the round
Config.RED_BOT_INTERVAL = { 28, 40 }
Config.RED_BOT_SMART = true -- prefer an attack the current layers let through
Config.BLUE_BOT_REACTION = 3.5 -- seconds before it can notice a threat
Config.BLUE_BOT_DETECT_PER_SECOND = 0.06
Config.BLUE_BOT_FALSE_ALARM_PER_SECOND = 0.006

------------------------------------------------------------------------ server

Config.TICK_SECONDS = 0.1
Config.TELEMETRY_PREFIX = "FLOWBENCH "

return Config
