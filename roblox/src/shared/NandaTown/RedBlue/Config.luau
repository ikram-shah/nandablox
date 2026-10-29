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
-- Loyal buyers buy from the newest card under their favourite's name; the
-- others hunt the cheapest listing (Policy.luau). Both are what a spoofed
-- card preys on.
Config.BUYER_FAVORITE = { ["buyer-1"] = "seller-a", ["buyer-2"] = "seller-b" }

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

--------------------------------------------------------------- model-driven agents

-- The external LLM harness (harness/, see roblox/README.md). Default off:
-- nothing here runs until someone presses L, so the published place is
-- unchanged for anyone who joins.
--
-- The hosted harness (Railway, harness/Dockerfile) is what a *published*
-- server can reach: a live Roblox server cannot see localhost. For a local
-- harness in Studio, set RB_LlmUrl on the server to http://127.0.0.1:8790 (or
-- edit this line in a branch) — everything else is the same.
Config.LLM_URL = "https://nanda-harness-production.up.railway.app" -- no key or secret in it
Config.LLM_PATH = "/v1/tick"
-- The shared secret the hosted harness requires, as
-- `Authorization: Bearer …`. Never a literal here, and never in the repo.
-- RedBlueServer looks for it in two places, in this order:
--   1. the experience's secrets store, HttpService:GetSecret(LLM_SECRET)
--      (Creator Dashboard > the experience > Secrets); the real answer
--   2. ServerStorage.NandaSecrets.LlmToken, a gitignored module written into
--      the *built place* by roblox/tools/secret.sh from $NANDA_HARNESS_TOKEN.
--      Server-only, so no player can read it, but anyone who can edit the
--      place can: demo-grade.
-- With neither, the harness answers 401 and the town stays scripted.
Config.LLM_SECRET = "nanda_harness_token"
Config.LLM_POLL_SECONDS = 2.5 -- 24 requests/min: HttpService allows 500/min
Config.LLM_MAX_PER_MINUTE = 40 -- hard ceiling, whatever else goes wrong
Config.LLM_TTL = 20 -- a stance older than this is dropped: scripted again
Config.LLM_BACKOFF = { 3, 30 } -- after a failed request: double from 3 s to 30 s
Config.LLM_TICKER = 6 -- recent town events sent as context
Config.LLM_MODEL = "gemini-2.5-flash" -- expected; the nameplate shows what the harness reports
-- Which roles may be model-driven, and what L cycles through.
Config.LLM_AGENT_ROLE = { ["seller-b"] = "seller", ["buyer-3"] = "buyer" }
Config.LLM_PRESETS = { {}, { "seller-b" }, { "seller-b", "buyer-3" } }

------------------------------------------------------------------------ server

Config.TICK_SECONDS = 0.1
Config.TELEMETRY_PREFIX = "FLOWBENCH "

return Config
