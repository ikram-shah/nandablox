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

-- The third fraud: a counterfeit stall (the "picture of spices" scam). It is
-- priced only a little under market, so the price rule waves it through; what
-- it sells is a framed print of the good. Its listing says so, in small type.
Config.COUNTERFEIT_PRICE = { 0.86, 0.95 } -- times market: within the rule's 15%
Config.COUNTERFEIT_SALES = 3 -- prints it sells before buyers complain and it shutters
-- The scripted fraud agents' share of counterfeits (0 = none; the round's
-- "Fakes" phase raises it). Kept 0 by default so the old claims hold.
Config.COUNTERFEIT_SHARE = 0

-- The lever: signature checks. On: impostors are rejected before they are a
-- case, but every listing and payment takes longer.
Config.SIG_LISTING_S = 3.0
Config.SIG_PAYMENT_S = 2.5

-- The built-in rule monitor (four lines; MarketSim.ruleMonitor).
Config.RULE_ALLOW_PRICE = 0.85
Config.RULE_ALLOW_RATINGS = 5
Config.RULE_BLOCK_PRICE = 0.5
Config.RULE_BLOCK_AGE = 60
-- An optional fifth line, off by default (a menu item later): a listing that
-- says "print" or "photo" is escalated to a watcher instead of allowed.
Config.RULE_KEYWORD_PRINT = false
Config.RULE_KEYWORDS = { "print", "photo" }

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

-- The timed round ("Start 5:00 round"). A phase table, so it can be retuned
-- without code: each phase has a start time (seconds into the round), a name,
-- a banner, the settings it applies (any of: n, monitor "off"|"rules"|
-- "external", signatures, watchers 1|2, counterfeits = the fraud agents'
-- counterfeit share, keyword = the rule monitor's print/photo line), and an
-- optional prompt. A prompt goes to one team ("blue" | "red" | "all"); its
-- `ask` names the buttons ("monitor" | "vote"); `when = "overBudget"` holds it
-- back until judgment calls per minute per watcher exceed `factor` x BUDGET
-- (and it stays armed for the rest of the round until a monitor is picked).
-- The last phase with `scoreboard = true` ends the round.
Config.ROUND_SAMPLE_S = 2 -- the calls/min chart: one sample every this many seconds
-- calls/min over the last this many seconds (at least 15). 30 s, not the
-- meter's 60: with 60 the needle lags the jump to 300 by a minute and the 3x
-- prompt would land in Lever (headless: 3x crossed at 1:42-2:02 with 30 s,
-- 2:16-2:38 with 60 s)
Config.ROUND_RATE_WINDOW = 30
Config.ROUND_PHASES = {
	{
		at = 0,
		name = "Calm",
		banner = "One watcher, a few agents.",
		set = { n = 5, monitor = "off", signatures = true, watchers = 1, counterfeits = 0 },
	},
	{
		at = 60,
		name = "Rush",
		banner = "300 traders. Every new stall is a judgment call.",
		set = { n = 300 },
		prompt = { team = "blue", ask = "monitor", when = "overBudget", factor = 3, text = "Inbox at 3× budget: pick a monitor." },
	},
	{
		at = 120,
		name = "Lever",
		banner = "The council votes on signature checks.",
		prompt = { team = "blue", ask = "vote", text = "Council vote: keep signature checks? (slower trade, no impostors)" },
	},
	{
		at = 180,
		name = "Fakes",
		banner = "Counterfeit stalls: fair prices, framed prints.",
		set = { counterfeits = 0.5 },
	},
	{
		at = 240,
		name = "Crew",
		banner = "A second watcher joins: the inbox splits.",
		set = { watchers = 2 },
	},
	{
		at = 300,
		name = "Scoreboard",
		banner = "Round over.",
		scoreboard = true,
	},
}

return Config
