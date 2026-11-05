-- NANDA Market: every number in one place (docs/market-design.md).
--
-- Prices are integer cents. Times are seconds of simulated time. Rates "per
-- minute" are per simulated minute.

local Config = {}

-- The four goods and their base values (cents). Sellers start near the base
-- and nudge toward what sells; the market price is the median of real sales.
Config.GOODS = {
	{ id = "bread", label = "bread", base = 300 },
	{ id = "cloth", label = "cloth", base = 1200 },
	{ id = "lamp", label = "lamps", base = 2400 },
	{ id = "spice", label = "spice", base = 800 },
}

-- Market size: N traders, of whom this share run stalls (the rest shop).
Config.SIZES = { 5, 50, 300, 1000 }
Config.SELLER_SHARE = 0.3
Config.MIN_SELLERS = 3 -- five traders: three stalls and two shoppers, close together

-- One watcher's budget: 12 judgment calls a minute (one every 5 s). An
-- assumption, stated; measuring the real number is FlowBench's job.
Config.BUDGET = 12

-- A listing (a stall opening for business) is a case. Its deadline is the
-- first buyer reaching the stall: the stall is setting up for this long.
Config.CASE_WINDOW = { 12, 18 }

-- Stalls.
Config.STOCK = 8 -- units per opening; selling out means restocking and reopening (a new listing)
Config.RESTOCK_S = { 5, 9 }
Config.DEAL_S = 2.0 -- walk up, coin, hand over
Config.BOARDED_S = 25 -- a blocked or shuttered stall stays visible this long, then the slot frees
-- Turnover: each honest seller retires at this rate (per minute) and a
-- newcomer takes the slot. Newcomers' listings, with the frauds, are the cases.
Config.TURNOVER_PER_MIN = 0.4
Config.NEWCOMER_DELAY = { 3, 12 }

-- Buyers.
Config.BROWSE_S = { 2, 6 }
Config.WALK_SPEED = { 7, 9.5 } -- studs per second
Config.PRICE_DISTANCE = 600 -- a buyer weighs price * (1 + distance / this)

-- Prices: sellers nudge toward what sells.
Config.NUDGE_EVERY = 8
Config.NUDGE_UP = 0.03
Config.NUDGE_DOWN = 0.04
Config.NUDGE_TO_MARKET = 0.08
Config.PRICE_CLAMP = { 0.6, 1.8 } -- times base
Config.MARKET_WINDOW = 60 -- the market price is the median of this many seconds of sales

-- Honest newcomers: most open at the going rate, some undercut to win their
-- first customers, a few undercut deeply (and look like scams).
Config.NEWCOMER_PRICE = {
	{ p = 0.7, lo = 0.88, hi = 1.08 },
	{ p = 0.2, lo = 0.6, hi = 0.84 },
	{ p = 0.1, lo = 0.4, hi = 0.5 },
}

-- The two frauds, injected by the scripted fraud agents at a steady rate that
-- scales with N.
Config.FRAUD_PER_TRADER_MIN = 0.04
Config.FRAUD_MIN_PER_MIN = 2
Config.IMPOSTOR_SHARE = 0.5
Config.IMPOSTOR_PRICE = { 0.86, 0.96 } -- times the victim's price: just cheaper
Config.SCAM_PRICE = { 0.35, 0.72 } -- times market: too good to be true
Config.FRAUD_LIFETIME = 120 -- a fraud nobody pays leaves after this

-- The lever: signature checks. On: impostors are rejected before they are a
-- case, but every listing and payment takes longer.
Config.SIG_LISTING_S = 3.0
Config.SIG_PAYMENT_S = 2.5

-- The built-in rule monitor (four lines; MarketSim.ruleMonitor).
Config.RULE_ALLOW_PRICE = 0.85
Config.RULE_ALLOW_RATINGS = 5
Config.RULE_BLOCK_PRICE = 0.5
Config.RULE_BLOCK_AGE = 60

-- An external monitor has this long to answer before the rules decide: one
-- tick interval plus the gateway's 900 ms, with room.
Config.MONITOR_WAIT_S = 4.5
-- An external agent's price holds this long before the scripted policy
-- resumes (the gateway's gemini-seller refreshes each trader every 12 s and
-- answers a tick late).
Config.AGENT_HOLD_S = 20.0

-- The modelled watcher (headless tests, rehearsal, and "auto" watchers):
-- one call every 5 s, right this often.
Config.WATCHER_SECONDS = 5
Config.WATCHER_ACCURACY = { ordinary = 0.95, gray = 0.8, twin = 0.6 }

-- The meter's rolling window.
Config.METER_WINDOW = 60

-- The gateway (docs/market-design.md, "The slot contract"). Off by default:
-- the world works fully without it.
Config.GATEWAY_ENABLED = false
Config.GATEWAY_URL = "https://nanda-harness-production.up.railway.app"
Config.GATEWAY_PATH = "/v1/tick"
Config.GATEWAY_EVERY_S = 2.0
-- market ticks share the harness's 45/min per-server limit with the old town;
-- a tick every 2 s is 30
Config.GATEWAY_MAX_PER_MINUTE = 30
Config.GATEWAY_TIMEOUT_S = 3 -- whole seconds (RequestAsync wants an integer); the gateway takes up to ~900 ms
Config.GATEWAY_SECRET = "nanda_harness_token"
Config.GATEWAY_MAX_CASES = 200 -- the gateway takes at most 500
Config.GATEWAY_MAX_DECISIONS = 40
-- which registration answers: nil asks every registered monitor (then the
-- gateway's own `rules`); a name asks only that one
Config.GATEWAY_MONITOR = nil :: string?
-- who drives a trader whose policy is "external" (nil: the gateway's choice,
-- which for sellers ends at its `gemini-seller`)
Config.GATEWAY_DRIVER = nil :: string?
-- what the beat-6 badge calls the hosted gateway's gemini-seller once it has
-- set a price (its /v1/health reports the model: gemini-2.5-flash)
Config.AGENT_MODEL_LABEL = "Gemini 2.5 Flash"

return Config
