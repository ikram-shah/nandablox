-- Score: both sides' scores from the sim's running totals
-- (docs/market-game.md, "Scoring"). Pure; all in cents.
--
--   Blue = honest trade value x SCORE_TRADE_SHARE - stolen - friction cost
--   Red  = stolen by Red's stalls - rent - vouches, IDs and ads - stalls lost
--
-- `d` is a table of totals (or of differences of totals since a round began):
-- honestValue, stolen, frictionCost, compute, redStolen, redRent,
-- redPurchases, redLost.

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local DefaultConfig = sibling("Config")

local Score = {}

local function r(x: number): number
	return math.floor(x + 0.5)
end

function Score.blue(d, cfg)
	cfg = cfg or DefaultConfig
	local trade = (d.honestValue or 0) * cfg.SCORE_TRADE_SHARE
	local friction = (d.frictionCost or 0) + (d.compute or 0)
	local stolen = d.stolen or 0
	return {
		score = r(trade - stolen - friction),
		trade = r(trade),
		stolen = r(stolen),
		friction = r(friction),
		compute = r(d.compute or 0),
	}
end

function Score.red(d)
	local stolen = d.redStolen or 0
	local rent = d.redRent or 0
	local bought = d.redPurchases or 0
	local lost = d.redLost or 0
	return {
		score = r(stolen - rent - bought - lost),
		stolen = r(stolen),
		rent = r(rent),
		bought = r(bought),
		lost = r(lost),
	}
end

-- one Red player's ledger (MarketSim.red[owner]) as a score
function Score.ledger(l)
	if not l then
		return Score.red({})
	end
	return Score.red({ redStolen = l.stolen, redRent = l.rent, redPurchases = l.bought, redLost = l.lost })
end

return Score
