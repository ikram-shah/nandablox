-- Scale: the town at 5, 25 or 100 agents, for the oversight demo (DEMO.md).
--
--   Scale.population(cfg, size)  who is in a town of `size` agents: the five
--                                 of the original game, plus a crowd of
--                                 "seller-03".."seller-40" and
--                                 "buyer-04".."buyer-60", with their list
--                                 prices. Deterministic.
--   Scale.Filter.new(cfg, pop)    the server's sampler: which town events are
--                                 sent to clients to be drawn. Every event is
--                                 simulated and counted; only the five, a few
--                                 "lit" crowd buyers, every card and every
--                                 attack are drawn, so 100 agents stay smooth
--                                 and legible from the watchtower.
--   Scale.slot(role, k)           where the k-th crowd seller / buyer stands
--                                 (client), in the open plaza around the five.
--
-- Pure: no Roblox services (Vector3 only in slot(), which the server never
-- calls), so Lune runs the first two headless.

local Scale = {}

local function sizeOf(cfg, size: number?): number
	local n = size or #cfg.SELLERS + #cfg.BUYERS
	return math.max(n, #cfg.SELLERS + #cfg.BUYERS)
end

-- The size after `size` in cfg.TOWN_SIZES (wrapping).
function Scale.nextSize(cfg, size: number): number
	local list = cfg.TOWN_SIZES
	for i, s in list do
		if s == size then
			return list[(i % #list) + 1]
		end
	end
	return list[1]
end

function Scale.factor(cfg, size: number): number
	return sizeOf(cfg, size) / (#cfg.SELLERS + #cfg.BUYERS)
end

function Scale.sellerName(i: number): string
	return string.format("seller-%02d", i)
end

function Scale.buyerName(i: number): string
	return string.format("buyer-%02d", i)
end

-- A crowd seller's list price: spread over CROWD_PRICE, ending in 95.
function Scale.crowdPrice(cfg, i: number): number
	local lo, hi = cfg.CROWD_PRICE[1], cfg.CROWD_PRICE[2]
	local steps = math.max(1, math.floor((hi - lo) / 10))
	return lo + 10 * ((i * 7) % (steps + 1))
end

-- pop = { size, sellers = {names}, buyers = {names}, core = {name -> true},
--         crowd = {name -> {role, k}} (k = index within the crowd of that
--         role), price = {name -> cents} }
function Scale.population(cfg, size: number?)
	local n = sizeOf(cfg, size)
	local share = cfg.TOWN_SELLER_SHARE or 0.4
	local nSellers = math.max(#cfg.SELLERS, math.floor(n * share + 0.5))
	local nBuyers = math.max(#cfg.BUYERS, n - nSellers)
	local pop = { size = nSellers + nBuyers, sellers = {}, buyers = {}, core = {}, crowd = {}, price = {} }
	for _, s in cfg.SELLERS do
		table.insert(pop.sellers, s)
		pop.core[s] = true
		pop.price[s] = cfg.LIST_PRICE[s] or 2000
	end
	for _, b in cfg.BUYERS do
		table.insert(pop.buyers, b)
		pop.core[b] = true
	end
	for i = #cfg.SELLERS + 1, nSellers do
		local name = Scale.sellerName(i)
		table.insert(pop.sellers, name)
		pop.crowd[name] = { role = "seller", k = i - #cfg.SELLERS }
		pop.price[name] = Scale.crowdPrice(cfg, i)
	end
	for i = #cfg.BUYERS + 1, nBuyers do
		local name = Scale.buyerName(i)
		table.insert(pop.buyers, name)
		pop.crowd[name] = { role = "buyer", k = i - #cfg.BUYERS }
	end
	return pop
end

------------------------------------------------------------------------ the sampler

local Filter = {}
Filter.__index = Filter
Scale.Filter = Filter

-- lit: how many crowd buyers have their deals drawn (cfg.CROWD_LIT)
function Filter.new(cfg, pop)
	local self = setmetatable({ cfg = cfg, nid = {}, lit = {}, shown = 0, total = 0 }, Filter)
	self:setPopulation(pop)
	return self
end

function Filter:setPopulation(pop)
	self.pop = pop
	table.clear(self.lit)
	for _, b in pop.buyers do
		local c = pop.crowd[b]
		if not c or c.k <= (self.cfg.CROWD_LIT or 0) then
			self.lit[b] = true
		end
	end
end

-- the buyer an event's deal belongs to, if it can be told from the event
function Filter:buyerOf(e): string?
	local pop = self.pop
	local function isBuyer(n: any): boolean
		return type(n) == "string" and (pop.core[n] or pop.crowd[n]) ~= nil and string.sub(n, 1, 5) == "buyer"
	end
	local d = e.detail or {}
	if isBuyer(e.observer) then
		return e.observer
	end
	if isBuyer(d.to) then
		return d.to
	end
	if isBuyer(d.from) then
		return d.from
	end
	if isBuyer(e.from) then
		return e.from
	end
	if type(e.subject) == "string" then
		local b = string.match(e.subject, "^order%-(buyer%-[%w]+)%-%d+")
		if b then
			return b
		end
		local nb = self.nid[e.subject]
		if nb then
			return nb
		end
	end
	return nil
end

-- Should this (server-side, private keys still on) event be drawn?
function Filter:keep(e): boolean
	self.total += 1
	local keep = self:decide(e)
	if keep then
		self.shown += 1
	end
	return keep
end

function Filter:decide(e): boolean
	if e.layer == "game" or e._threat ~= nil or e.snapshot then
		return true
	end
	local kind = e.kind
	if kind == "participant_joined" or kind == "account_opened" or string.sub(kind, 1, 5) == "card_" or kind == "signature_invalid" then
		return true
	end
	if kind == "negotiation_started" and type(e.subject) == "string" then
		self.nid[e.subject] = e.observer
	end
	local b = self:buyerOf(e)
	if b then
		return self.lit[b] == true
	end
	-- not tied to a buyer: a seller's own bookkeeping; draw it for the five
	return self.pop.core[e.observer] == true or self.pop.core[e.subject] == true or e.observer == "town"
end

------------------------------------------------------------------------ the crowd's places

-- Two blocks either side of the five, filled nearest-first and alternating
-- left / right so the town grows symmetrically. Sellers stand in the back row
-- beside the stalls, buyers in the front row between the three buyers.
local SELLER_BLOCK = { x0 = 30, cols = 4, dx = 4.2, z0 = -10, rows = 5, dz = -4.4 }
local BUYER_BLOCK = { x0 = 10, cols = 6, dx = 4.2, z0 = 17, rows = 5, dz = 4.4 }

function Scale.slot(role: string, k: number): (number, number, number)
	local b = role == "seller" and SELLER_BLOCK or BUYER_BLOCK
	local side = (k % 2 == 1) and -1 or 1
	local j = (k + 1) // 2 - 1 -- 0-based within the block
	local row = j // b.cols
	local col = j % b.cols
	row = row % b.rows
	local x = side * (b.x0 + col * b.dx)
	local z = b.z0 + row * b.dz
	-- facing: sellers face the square (+z), buyers face the stalls (-z)
	return x, z, role == "seller" and 1 or -1
end

return Scale
