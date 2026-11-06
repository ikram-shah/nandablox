-- Loadout: Blue's checks and what each one does (docs/market-game.md).
--
-- Pure Luau, no state of its own: MarketSim holds the loadout (a set of check
-- ids in effect) and asks this module what a check makes of a stall. A
-- stall's properties are what anyone could look at, plus the two facts a
-- check is built to test (does the signature carry the name's key? what is
-- on the counter?):
--
--   { price, market, established (5+ ratings, own or borrowed), vouched,
--     key = "own" | "none" | "stolen", counter = "empty"|"stocked"|"prints",
--     text = listing and pitch, pitch = true if it talks, kind }
--
--   Loadout.friction(lo)                -> total friction
--   Loadout.band(f)                     -> { name, stay, listS, payS }
--   Loadout.listing(props, lo, roll)    -> "reject"|"escalate"|"allow", reasons
--   Loadout.inspectorShuts(props)       -> true if an inspector closes it
--   Loadout.escrowRefunds(props)        -> true if escrow refunds the buyer

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local DefaultConfig = sibling("Config")

local Loadout = {}

function Loadout.checks(cfg)
	return (cfg or DefaultConfig).CHECKS
end

function Loadout.check(id: string, cfg)
	for _, c in Loadout.checks(cfg) do
		if c.id == id then
			return c
		end
	end
	return nil
end

function Loadout.isCheck(id: any, cfg): boolean
	return type(id) == "string" and Loadout.check(id, cfg) ~= nil
end

-- an empty loadout (every check off)
function Loadout.empty(cfg)
	local lo = {}
	for _, c in Loadout.checks(cfg) do
		lo[c.id] = false
	end
	return lo
end

function Loadout.from(list: { string }, cfg)
	local lo = Loadout.empty(cfg)
	for _, id in list do
		if lo[id] ~= nil then
			lo[id] = true
		end
	end
	return lo
end

-- the ids in effect, in table order
function Loadout.list(lo, cfg): { string }
	local out = {}
	for _, c in Loadout.checks(cfg) do
		if lo[c.id] then
			table.insert(out, c.id)
		end
	end
	return out
end

function Loadout.friction(lo, cfg): number
	local f = 0
	for _, c in Loadout.checks(cfg) do
		if lo[c.id] then
			f += c.friction
		end
	end
	return f
end

-- What a friction total does to the market: its name, the share of honest
-- sellers who stay, and the extra seconds on every listing and every deal.
function Loadout.band(f: number, cfg)
	cfg = cfg or DefaultConfig
	local listS = f * cfg.FRICTION_LISTING_S
	local payS = f * cfg.FRICTION_PAYMENT_S
	if f >= cfg.FRICTION_SEIZED then
		return {
			name = "seized",
			stay = cfg.FRICTION_SEIZED_STAY,
			listS = listS + cfg.FRICTION_SEIZED_LISTING_S,
			payS = payS + cfg.FRICTION_SEIZED_PAYMENT_S,
		}
	elseif f > cfg.FRICTION_HEALTHY then
		return {
			name = "slow",
			stay = cfg.FRICTION_STAY[math.floor(f)] or 1,
			listS = listS,
			payS = payS + (f - cfg.FRICTION_HEALTHY) * cfg.FRICTION_SLOW_PAYMENT_S,
		}
	end
	return { name = "healthy", stay = 1, listS = listS, payS = payS }
end

local function says(text: string?, cfg): string?
	if type(text) ~= "string" then
		return nil
	end
	local t = string.lower(text)
	for _, w in cfg.PITCH_KEYWORDS do
		if string.find(t, w, 1, true) then
			return w
		end
	end
	return nil
end
Loadout.says = function(text: string?, cfg)
	return says(text, cfg or DefaultConfig)
end

-- The listing-time checks, in order: the ID check rejects outright; the
-- price floor, the voucher and the pitch reader escalate. `roll` answers the
-- pitch reader's uncertain reads: roll("smallprint") / roll("falseAlarm")
-- -> boolean (MarketSim passes its own seeded stream; nil = never).
-- Returns the verdict and a list of { check, text } reasons.
function Loadout.listing(p, lo, cfg, roll): (string, { { check: string, text: string } })
	cfg = cfg or DefaultConfig
	local reasons = {}
	if lo.idCheck and p.key == "none" then
		table.insert(reasons, { check = "idCheck", text = "signature does not match the name" })
		return "reject", reasons
	end
	if lo.priceFloor and p.market and p.market > 0 and p.price < cfg.PRICE_FLOOR * p.market then
		local pct = math.floor((1 - p.price / p.market) * 100 + 0.5)
		table.insert(reasons, { check = "priceFloor", text = pct .. "% below market" })
	end
	if lo.voucher and not p.established and not p.vouched then
		table.insert(reasons, { check = "voucher", text = "new seller, nobody vouches" })
	end
	if lo.pitchReader then
		local w = p.pitch and says(p.text, cfg) or nil
		if w then
			table.insert(reasons, { check = "pitchReader", text = "the pitch says \"" .. w .. "\"" })
		elseif p.counter == "prints" and says(p.text, cfg) and roll and roll("smallprint") then
			table.insert(reasons, { check = "pitchReader", text = "small print says \"" .. (says(p.text, cfg) :: string) .. "\"" })
		elseif p.kind == "honest" and roll and roll("falseAlarm") then
			table.insert(reasons, { check = "pitchReader", text = "the listing reads oddly" })
		end
	end
	if #reasons > 0 then
		return "escalate", reasons
	end
	return "allow", reasons
end

function Loadout.reasonText(reasons): string?
	if not reasons or #reasons == 0 then
		return nil
	end
	local parts = {}
	for _, r in reasons do
		table.insert(parts, r.text)
	end
	return table.concat(parts, "; ")
end

-- The inspector looks at the counter. An empty counter or framed prints is
-- shut down, unless the stall talks its way out (a smooth talker's pitch:
-- the doc's table has it beat the inspector).
function Loadout.inspectorShuts(p): boolean
	if p.pitch then
		return false
	end
	return p.counter == "empty" or p.counter == "prints"
end

-- Escrow holds the money until the goods arrive: non-delivery (an empty
-- counter) and prints are refunded and the seller is caught. An impostor's
-- goods do arrive (it steals the name's custom, not the buyer's goods).
function Loadout.escrowRefunds(p): boolean
	return p.counter == "empty" or p.counter == "prints"
end

return Loadout
