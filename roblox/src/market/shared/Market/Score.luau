-- Score: both sides' profit in Nandabux from the sim's running totals
-- (docs/market-game.md, "Money: Nandabux (NB)"). Pure; all in cents.
--
--   Blue = fees on honest deals - refunds to cheated buyers + fines - check costs
--   Red  = loot - rent - vouches, IDs and ads - forfeited deposits
--
-- `d` is a table of totals (or of differences since a round began):
-- blueFees, blueRefunds, blueFines, blueCosts, compute, redStolen, redRent,
-- redPurchases, redLost. The bigger profit wins.

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

function Score.blue(d, _cfg)
	local fees = d.blueFees or 0
	local refunds = d.blueRefunds or 0
	local fines = d.blueFines or 0
	local costs = d.blueCosts or 0
	return {
		score = r(fees - refunds + fines - costs),
		fees = r(fees),
		refunds = r(refunds),
		fines = r(fines),
		costs = r(costs),
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

-- who is ahead: "blue" | "red" | "tie"
function Score.winner(blue: number, red: number): string
	if blue > red then
		return "blue"
	elseif red > blue then
		return "red"
	end
	return "tie"
end

-- one Red player's ledger (MarketSim.red[owner]) as a score
function Score.ledger(l)
	if not l then
		return Score.red({})
	end
	local sc = Score.red({ redStolen = l.stolen, redRent = l.rent, redPurchases = l.bought, redLost = l.lost })
	sc.purse = r(l.purse or 0)
	return sc
end

return Score
