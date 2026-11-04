-- MarketSim: the NANDA Market engine (docs/market-design.md).
--
-- Pure Luau: deterministic, seeded, no Roblox services. The server steps it at
-- a fixed tick and forwards its events; the tests run it headless with Lune.
--
--   local sim = MarketSim.new({ seed = 1, n = 300 })
--   sim:setMonitor("rules")          -- "off" | "rules" | "external"
--   sim:setSignatures(false)         -- the lever
--   sim:addWatcher("peter")          -- a human; { auto = true } for the modelled one
--   sim:step(0.25)                   -- advance simulated time
--   sim:verdict("peter", "c-17", "block")
--   for _, e in sim:drain() do ... end
--   sim:meter()                      -- the numbers on the meter
--
-- Holds traders (sellers with stalls, buyers), four goods, the emergent market
-- price, listings, deals, the two frauds with ground truth, cases with
-- deadlines, the monitor slot, the agent slot, the lever, and the meter.

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local DefaultConfig = sibling("Config")
local Rng = sibling("Rng")
local Layout = sibling("Layout")
local Names = sibling("Names")

local MarketSim = {}
MarketSim.__index = MarketSim

local LIVE = { setup = true, open = true, restock = true }

------------------------------------------------------------------ the rules

-- The built-in rule monitor, in full (the design doc's four lines). `c` is a
-- case's public fields: what anyone can see, never the ground truth.
function MarketSim.ruleMonitor(c, signatures: boolean, cfg): (string, string)
	cfg = cfg or DefaultConfig
	if c.twin and not signatures then
		return "escalate", "two stalls, one name: can't tell which is real"
	end
	if c.price >= cfg.RULE_ALLOW_PRICE * c.market or c.ratings >= cfg.RULE_ALLOW_RATINGS then
		return "allow", "ordinary business"
	end
	if c.price < cfg.RULE_BLOCK_PRICE * c.market and c.age_s < cfg.RULE_BLOCK_AGE then
		return "block", "half price and brand new: almost always a scam"
	end
	return "escalate", "the gray zone"
end

------------------------------------------------------------------ construction

local function median(xs: { number }): number?
	if #xs == 0 then
		return nil
	end
	local c = table.clone(xs)
	table.sort(c)
	local m = #c // 2
	if #c % 2 == 1 then
		return c[m + 1]
	end
	return (c[m] + c[m + 1]) / 2
end

function MarketSim.sellersFor(n: number, cfg): number
	cfg = cfg or DefaultConfig
	return math.max(cfg.MIN_SELLERS, math.floor(n * cfg.SELLER_SHARE + 0.5))
end

-- opts = { seed, n, config, monitor, signatures }
function MarketSim.new(opts)
	opts = opts or {}
	local cfg = opts.config or DefaultConfig
	local self = setmetatable({
		cfg = cfg,
		rng = Rng.new(opts.seed or 1),
		seed = opts.seed or 1,
		now = 0,
		n = 0,
		monitor = opts.monitor or "off",
		signatures = if opts.signatures == nil then true else opts.signatures,
		goods = {},
		goodList = {},
		sellers = {}, -- array, in creation order
		byId = {},
		slots = {}, -- slot index -> seller id
		buyers = {},
		cases = {}, -- id -> case
		caseList = {}, -- open cases, in creation order
		watchers = {},
		pending = {}, -- scheduled seller arrivals { at, kind, established }
		unwatched = {}, -- escalated cases while no watcher is present
		events = {},
		nextSeller = 1,
		nextBuyer = 1,
		nextCase = 1,
		nextPriceAt = 0,
		monitorName = "rules",
		gatewayStats = { ticks = 0, verdicts = 0, actions = 0, fallbacks = 0 },
	}, MarketSim)
	for _, g in cfg.GOODS do
		local good = { id = g.id, label = g.label, base = g.base, market = g.base, sales = {} }
		self.goods[g.id] = good
		table.insert(self.goodList, good)
	end
	self:mark()
	self:setSize(opts.n or 5, true)
	return self
end

function MarketSim:emit(e)
	table.insert(self.events, e)
end

function MarketSim:drain()
	local e = self.events
	self.events = {}
	return e
end

------------------------------------------------------------------ the meter

-- Reset the meter's counters (a change of setting starts a clean count).
function MarketSim:mark(label: string?)
	self.markAt = self.now
	self.markLabel = label
	self.count = {
		listings = 0,
		cases = 0,
		asked = 0, -- cases that reached a watcher: judgment calls asked for
		decided = 0, -- verdicts watchers gave
		deals = 0,
		rejected = 0, -- impostors stopped by signature checks
		caught = { signatures = 0, monitor = 0, watchers = 0 },
		escaped = { missed = 0, judged = 0, waited = 0 },
		falseAlarms = { monitor = 0, watchers = 0 },
		expiredHonest = 0,
		frauds = 0,
	}
	self.roll = { asked = {}, decided = {}, deals = {}, escaped = {}, caught = {}, falseAlarms = {} }
end

local function push(self, key: string)
	table.insert(self.roll[key], self.now)
end

local function rate(self, key: string, window: number): number
	local list = self.roll[key]
	local cut = self.now - window
	local i = 1
	while i <= #list and list[i] < cut do
		i += 1
	end
	if i > 1 then
		table.move(list, i, #list, 1)
		for k = #list - i + 2, #list do
			list[k] = nil
		end
	end
	return #list * 60 / window
end

local function sum(t): number
	local s = 0
	for _, v in t do
		s += v
	end
	return s
end

function MarketSim:meter()
	local c = self.count
	local elapsed = self.now - self.markAt
	local window = math.min(self.cfg.METER_WINDOW, math.max(10, elapsed))
	local watchers = #self.watchers
	local calls = rate(self, "asked", window)
	local minutes = math.max(elapsed, 1) / 60
	local open = 0
	for _, w in self.watchers do
		open += #w.queue
	end
	local unwatched = self.unwatched and #self.unwatched or 0
	return {
		t = self.now,
		n = self.n,
		monitor = self.monitor,
		monitorName = self.monitorName,
		signatures = self.signatures,
		watchers = watchers,
		budget = self.cfg.BUDGET,
		-- judgment calls asked of the watchers, per minute (the meter's needle)
		callsPerMin = calls,
		perWatcher = calls / math.max(1, watchers),
		decidedPerMin = rate(self, "decided", window),
		dealsPerMin = rate(self, "deals", window),
		escapedPerMin = rate(self, "escaped", window),
		caughtPerMin = rate(self, "caught", window),
		falseAlarmsPerMin = rate(self, "falseAlarms", window),
		inbox = open + unwatched,
		-- since the last mark
		elapsed = elapsed,
		since = self.markLabel,
		listings = c.listings,
		cases = c.cases,
		asked = c.asked,
		askedPerMinAvg = c.asked / minutes,
		decided = c.decided,
		deals = c.deals,
		dealsPerMinAvg = c.deals / minutes,
		caught = sum(c.caught),
		caughtBy = table.clone(c.caught),
		escaped = sum(c.escaped),
		escapedBy = table.clone(c.escaped),
		falseAlarms = sum(c.falseAlarms),
		falseAlarmsBy = table.clone(c.falseAlarms),
		rejected = c.rejected,
		expiredHonest = c.expiredHonest,
		frauds = c.frauds,
	}
end

function MarketSim:prices()
	local out = {}
	for _, g in self.goodList do
		out[g.id] = math.floor(g.market + 0.5)
	end
	return out
end

------------------------------------------------------------------ sellers

local function takenNames(self)
	local t = {}
	for _, s in self.sellers do
		if s.state ~= "gone" then
			t[s.name] = true
		end
	end
	return t
end

local function freeSlot(self): number?
	for i = 1, #Layout.SLOTS do
		if self.slots[i] == nil then
			return i
		end
	end
	return nil
end

local function marketOf(self, good: string): number
	return self.goods[good].market
end

function MarketSim:publicSeller(s)
	local shown = s.kind == "impostor" and not self.signatures and self.byId[s.victim] or s
	return {
		id = s.id,
		slot = s.slot,
		name = s.name,
		good = s.good,
		price = math.floor(s.price + 0.5),
		stock = s.stock,
		state = s.state,
		openAt = s.openAt,
		ratings = shown and shown.ratings or s.ratings,
		rating_avg = shown and shown.ratings > 0 and shown.ratingSum / shown.ratings or nil,
		policy = s.policy,
		label = s.label,
		look = s.look,
		-- ground truth only once it no longer matters (the aftermath)
		truth = (s.state == "shuttered" or s.state == "blocked" or s.state == "gone") and s.kind or nil,
		reason = s.reason,
	}
end

local function emitStall(self, s)
	self:emit({ k = "stall", s = self:publicSeller(s) })
end

local function setState(self, s, state: string, untilT: number?)
	s.state = state
	s.stateUntil = untilT
	emitStall(self, s)
end

-- a new seller takes a free slot; kind = "honest" | "scam" | "impostor"
local function addSeller(self, kind: string, opts)
	local slot = freeSlot(self)
	if not slot then
		return nil
	end
	local rng = self.rng
	local cfg = self.cfg
	local good = opts.good or rng:pick(self.goodList).id
	local market = marketOf(self, good)
	local s = {
		id = "s-" .. self.nextSeller,
		kind = kind,
		good = good,
		slot = slot,
		name = opts.name or Names.fresh(rng, good, takenNames(self)),
		price = opts.price or market,
		stock = 0,
		reserved = 0,
		ratings = opts.ratings or 0,
		ratingSum = (opts.ratings or 0) * (opts.ratingAvg or 4.6),
		since = self.now - (opts.age or 0),
		state = "new",
		busyUntil = 0,
		sold = {},
		nextNudge = self.now + rng:range(0, cfg.NUDGE_EVERY),
		policy = "scripted",
		victim = opts.victim,
		look = rng:int(1, 1000),
		createdAt = self.now,
	}
	self.nextSeller += 1
	self.slots[slot] = s.id
	self.byId[s.id] = s
	table.insert(self.sellers, s)
	return s
end

-- the next buyer's arrival at a stall that is setting up (the case deadline)
local function windowLength(self): number
	local w = self.rng:range(self.cfg.CASE_WINDOW[1], self.cfg.CASE_WINDOW[2])
	if self.signatures then
		w += self.cfg.SIG_LISTING_S
	end
	return w
end

local caseFor, route -- forward

-- A stall opens for business: a listing. Every listing is a case.
local function list(self, s)
	local cfg = self.cfg
	self.count.listings += 1
	s.stock = cfg.STOCK
	s.reserved = 0
	s.allowedBy = nil
	if s.kind == "impostor" and self.signatures then
		-- the protocol checks the key against the name: rejected before it is ever a case
		self.count.rejected += 1
		self.count.caught.signatures += 1
		push(self, "caught")
		s.reason = "signature does not match the name"
		setState(self, s, "rejected", self.now + 3)
		self:emit({ k = "rejected", seller = s.id, name = s.name, slot = s.slot })
		return
	end
	s.openAt = self.now + windowLength(self)
	setState(self, s, "setup")
	local c = caseFor(self, s, "listing")
	route(self, c)
	-- with signatures off, two stalls with one name look identical: the
	-- original's stall becomes a case too
	if c.twin and s.kind == "impostor" then
		local v = self.byId[s.victim]
		if v and LIVE[v.state] and not v.case then
			local c2 = caseFor(self, v, "twin")
			c2.deadline = c.deadline
			c2.deadline_at = c.deadline_at
			route(self, c2)
		end
	end
end

local function honestCount(self): number
	local k = 0
	for _, s in self.sellers do
		if s.kind == "honest" and s.state ~= "gone" and s.state ~= "blocked" then
			k += 1
		end
	end
	for _, p in self.pending do
		if p.kind == "honest" then
			k += 1
		end
	end
	return k
end

local function newcomerPrice(self, good: string): number
	local market = marketOf(self, good)
	local u = self.rng:next()
	local acc = 0
	for _, band in self.cfg.NEWCOMER_PRICE do
		acc += band.p
		if u <= acc then
			return market * self.rng:range(band.lo, band.hi)
		end
	end
	return market
end

local function arrive(self, p)
	local rng = self.rng
	if p.kind == "honest" then
		local good = rng:pick(self.goodList).id
		local s
		if p.established then
			s = addSeller(self, "honest", {
				good = good,
				price = marketOf(self, good) * rng:range(0.92, 1.1),
				ratings = rng:int(6, 60),
				ratingAvg = rng:range(4.1, 4.9),
				age = rng:range(400, 4000),
			})
		else
			s = addSeller(self, "honest", { good = good, price = newcomerPrice(self, good) })
		end
		if s then
			if p.instant then
				-- the market as it stands at the start: already open, no case
				s.stock = rng:int(2, self.cfg.STOCK)
				s.openAt = self.now
				setState(self, s, "open")
			else
				list(self, s)
			end
		end
	end
end

-- A fraud agent acts. kind = "scam" | "impostor"; opts.good, opts.price (fraction
-- of market), opts.victim (a seller id) for a human red player.
function MarketSim:injectFraud(kind: string, opts)
	opts = opts or {}
	local rng = self.rng
	local cfg = self.cfg
	if kind == "impostor" then
		local victim = opts.victim and self.byId[opts.victim]
		if not victim then
			local cands = {}
			for _, s in self.sellers do
				if s.kind == "honest" and (s.state == "open" or s.state == "setup") then
					table.insert(cands, s)
				end
			end
			if #cands == 0 then
				return nil
			end
			victim = rng:pick(cands)
		end
		local s = addSeller(self, "impostor", {
			good = victim.good,
			name = victim.name,
			price = victim.price * rng:range(cfg.IMPOSTOR_PRICE[1], cfg.IMPOSTOR_PRICE[2]),
			victim = victim.id,
		})
		if not s then
			return nil
		end
		s.look = victim.look -- dressed the same, too
		s.leaveAt = self.now + cfg.FRAUD_LIFETIME
		self.count.frauds += 1
		list(self, s)
		return s
	else
		local good = opts.good or rng:pick(self.goodList).id
		local frac = opts.price or rng:range(cfg.SCAM_PRICE[1], cfg.SCAM_PRICE[2])
		local s = addSeller(self, "scam", { good = good, price = marketOf(self, good) * frac })
		if not s then
			return nil
		end
		s.leaveAt = self.now + cfg.FRAUD_LIFETIME
		self.count.frauds += 1
		list(self, s)
		return s
	end
end

local function remove(self, s, why: string?)
	if s.case then
		local c = self.cases[s.case]
		if c then
			MarketSim.closeCase(self, c, "withdrawn", "market")
		end
	end
	self.slots[s.slot] = nil
	s.reason = why or s.reason
	setState(self, s, "gone")
end

------------------------------------------------------------------ cases

function caseFor(self, s, kind: string)
	local shown = s
	if s.kind == "impostor" and not self.signatures then
		shown = self.byId[s.victim] or s -- unsigned, the name's history is all anyone sees
	end
	local twin = false
	if not self.signatures then
		for _, o in self.sellers do
			if o ~= s and o.name == s.name and (LIVE[o.state]) then
				twin = true
				break
			end
		end
	end
	local market = marketOf(self, s.good)
	local signature = "unchecked"
	if self.signatures then
		signature = s.kind == "impostor" and "invalid" or "valid"
	end
	local c = {
		id = "c-" .. self.nextCase,
		seller = s.id,
		kind = kind,
		stall = s.name,
		good = s.good,
		price = math.floor(s.price + 0.5),
		market = math.floor(market + 0.5),
		age_s = math.floor(self.now - shown.since),
		ratings = shown.ratings,
		rating_avg = shown.ratings > 0 and math.floor(shown.ratingSum / shown.ratings * 10 + 0.5) / 10 or nil,
		signature = signature,
		twin = twin,
		created = self.now,
		deadline_at = s.openAt,
		truth = s.kind, -- ground truth: never sent to a monitor or a watcher
		stage = "new",
	}
	self.nextCase += 1
	self.cases[c.id] = c
	table.insert(self.caseList, c)
	s.case = c.id
	self.count.cases += 1
	return c
end

-- the fields a monitor or a watcher sees (the slot contract's case shape)
function MarketSim:publicCase(c)
	return {
		id = c.id,
		stall = c.stall,
		good = c.good,
		price = c.price,
		market = c.market,
		age_s = c.age_s,
		ratings = c.ratings,
		rating_avg = c.rating_avg,
		signature = c.signature,
		twin = c.twin,
		deadline_s = math.max(0, math.floor((c.deadline_at - self.now) * 10 + 0.5) / 10),
		-- for the inbox card (not in the contract's fields, harmless)
		kind = c.kind,
		created = c.created,
		deadline_at = c.deadline_at,
		watcher = c.watcher,
		slot = self.byId[c.seller] and self.byId[c.seller].slot,
		seller = c.seller,
	}
end

local function leastBusy(self)
	local best, bestN = nil, math.huge
	for _, w in self.watchers do
		if #w.queue < bestN then
			best, bestN = w, #w.queue
		end
	end
	return best
end

local function toInbox(self, c)
	c.stage = "inbox"
	self.count.asked += 1
	push(self, "asked")
	local w = leastBusy(self)
	if w then
		c.watcher = w.id
		table.insert(w.queue, c.id)
		w.asked += 1
	else
		c.watcher = nil
		table.insert(self.unwatched, c.id)
	end
	self:emit({ k = "case", c = self:publicCase(c) })
end

function MarketSim.closeCase(self, c, verdict: string, by: string, who: string?, reason: string?)
	if c.stage == "done" then
		return
	end
	local wasInbox = c.stage == "inbox"
	c.stage = "done"
	c.verdict = verdict
	c.by = by
	local s = self.byId[c.seller]
	if s and s.case == c.id then
		s.case = nil
	end
	-- take it out of whichever inbox holds it
	if wasInbox then
		local q = self.unwatched
		if c.watcher then
			for _, w in self.watchers do
				if w.id == c.watcher then
					q = w.queue
				end
			end
		end
		local i = table.find(q, c.id)
		if i then
			table.remove(q, i)
		end
	end
	local fraud = c.truth ~= "honest"
	-- a twin case is about the original seller's stall
	if verdict == "block" then
		if fraud then
			self.count.caught[by == "monitor" and "monitor" or "watchers"] += 1
			push(self, "caught")
		else
			self.count.falseAlarms[by == "monitor" and "monitor" or "watchers"] += 1
			push(self, "falseAlarms")
		end
		if s and LIVE[s.state] then
			s.reason = reason or (by == "monitor" and "blocked by the monitor" or "blocked by a watcher")
			s.blockedBy = by
			setState(self, s, "blocked", self.now + self.cfg.BOARDED_S)
		end
	elseif verdict == "allow" then
		if s then
			s.allowedBy = by
		end
	elseif verdict == "expired" then
		if s then
			s.allowedBy = "expired"
		end
		if not fraud then
			self.count.expiredHonest += 1
		end
	end
	self:emit({
		k = "caseEnd",
		id = c.id,
		verdict = verdict,
		by = by,
		who = who,
		truth = c.truth,
		correct = (verdict == "block") == fraud,
		reason = reason,
	})
end

-- Where a new case goes: the monitor slot decides, and only escalated cases
-- reach a watcher.
function route(self, c)
	if self.monitor == "off" then
		toInbox(self, c)
	elseif self.monitor == "external" then
		c.stage = "monitor"
		c.monitorBy = self.now + self.cfg.MONITOR_WAIT_S
	else
		local v, why = MarketSim.ruleMonitor(c, self.signatures, self.cfg)
		self:monitorVerdict(c, v, why, "rules")
	end
end

function MarketSim:monitorVerdict(c, v: string, why: string?, name: string?)
	c.monitorName = name
	c.monitorReason = why
	if v == "allow" or v == "block" then
		MarketSim.closeCase(self, c, v, "monitor", name, why)
	else
		c.reason = why
		toInbox(self, c)
	end
end

-- A watcher's verdict: one judgment call.
function MarketSim:verdict(watcherId: string, caseId: string, v: string): (boolean, string?)
	local c = self.cases[caseId]
	if not c then
		return false, "no such case"
	end
	if c.stage ~= "inbox" then
		return false, "already " .. tostring(c.verdict or c.stage)
	end
	if v ~= "allow" and v ~= "block" then
		return false, "allow or block"
	end
	self.count.decided += 1
	push(self, "decided")
	for _, w in self.watchers do
		if w.id == watcherId then
			w.decided += 1
		end
	end
	MarketSim.closeCase(self, c, v, "watcher", watcherId)
	return true
end

------------------------------------------------------------------ watchers

function MarketSim:addWatcher(id: string, opts)
	opts = opts or {}
	for _, w in self.watchers do
		if w.id == id then
			return w
		end
	end
	local w = {
		id = id,
		auto = opts.auto or false,
		label = opts.label or id,
		queue = {},
		busyUntil = 0,
		working = nil,
		asked = 0,
		decided = 0,
		rng = Rng.new(self.seed * 7919 + #self.watchers * 104729 + 13),
	}
	table.insert(self.watchers, w)
	-- the unwatched backlog goes to whoever arrives
	local back = self.unwatched
	self.unwatched = {}
	for _, id2 in back do
		local c = self.cases[id2]
		if c and c.stage == "inbox" then
			local to = leastBusy(self)
			c.watcher = to.id
			table.insert(to.queue, c.id)
			self:emit({ k = "case", c = self:publicCase(c) })
		end
	end
	return w
end

function MarketSim:removeWatcher(id: string)
	for i, w in self.watchers do
		if w.id == id then
			table.remove(self.watchers, i)
			for _, cid in w.queue do
				local c = self.cases[cid]
				if c and c.stage == "inbox" then
					local to = leastBusy(self)
					if to then
						c.watcher = to.id
						table.insert(to.queue, cid)
					else
						c.watcher = nil
						table.insert(self.unwatched, cid)
					end
					self:emit({ k = "case", c = self:publicCase(c) })
				end
			end
			return
		end
	end
end

function MarketSim:setAuto(id: string, auto: boolean)
	for _, w in self.watchers do
		if w.id == id then
			w.auto = auto
		end
	end
end

function MarketSim:inbox(watcherId: string?)
	local out = {}
	local q = self.unwatched
	if watcherId then
		q = {}
		for _, w in self.watchers do
			if w.id == watcherId then
				q = w.queue
			end
		end
	end
	for _, cid in q do
		local c = self.cases[cid]
		if c and c.stage == "inbox" then
			table.insert(out, self:publicCase(c))
		end
	end
	return out
end

-- the modelled watcher: one call every WATCHER_SECONDS, oldest decidable case
-- first, right with a probability that depends on how the case looks
local function autoWatch(self, w)
	local cfg = self.cfg
	if w.working then
		if self.now < w.busyUntil then
			return
		end
		local c = self.cases[w.working]
		w.working = nil
		if c and c.stage == "inbox" then
			local acc = cfg.WATCHER_ACCURACY
			local p = acc.ordinary
			if c.twin then
				p = acc.twin
			elseif c.price < cfg.RULE_ALLOW_PRICE * c.market and c.ratings < cfg.RULE_ALLOW_RATINGS then
				p = acc.gray
			end
			local right = c.truth == "honest" and "allow" or "block"
			local wrong = right == "allow" and "block" or "allow"
			self:verdict(w.id, c.id, w.rng:chance(p) and right or wrong)
		end
	end
	if not w.auto then
		return
	end
	for _, cid in w.queue do
		local c = self.cases[cid]
		if c and c.stage == "inbox" and c.deadline_at > self.now + cfg.WATCHER_SECONDS + 0.25 then
			w.working = cid
			w.busyUntil = self.now + cfg.WATCHER_SECONDS
			return
		end
	end
end

------------------------------------------------------------------ buyers

local function emitBuyer(self, b)
	self:emit({
		k = "buyer",
		id = b.id,
		from = b.from,
		to = b.to,
		t0 = b.t0,
		t1 = b.t1,
		state = b.state,
		carry = b.carry,
		look = b.look,
		target = b.target,
	})
end

local function walkTo(self, b, q, state: string)
	local p = b.pos
	local pts = Layout.path(p, q)
	local len = Layout.length(pts)
	b.from, b.to = p, q
	b.t0 = self.now
	b.t1 = self.now + len / b.speed
	b.state = state
	emitBuyer(self, b)
end

local function standUntil(self, b, t: number, state: string)
	b.from, b.to = b.pos, b.pos
	b.t0, b.t1 = self.now, t
	b.state = state
	emitBuyer(self, b)
end

local function counterSpot(self, b, s)
	local slot = Layout.SLOTS[s.slot]
	-- people at a counter spread along it a little
	local tx, tz = -slot.facing.z, slot.facing.x
	local off = ((b.n * 37) % 7 - 3) * 0.9
	local back = ((b.n * 13) % 3) * 1.2
	return {
		x = slot.front.x + tx * off + slot.facing.x * back,
		z = slot.front.z + tz * off + slot.facing.z * back,
	}
end

local function chooseStall(self, b)
	local best, bestScore = nil, math.huge
	for _, s in self.sellers do
		if s.good == b.want and (s.state == "open" or s.state == "setup") and s.reserved < s.stock then
			local slot = Layout.SLOTS[s.slot]
			local d = math.sqrt((slot.front.x - b.pos.x) ^ 2 + (slot.front.z - b.pos.z) ^ 2)
			local score = s.price * (1 + d / self.cfg.PRICE_DISTANCE) * (1 + 0.12 * s.reserved) * self.rng:range(0.92, 1.08)
			if score < bestScore then
				best, bestScore = s, score
			end
		end
	end
	return best
end

local function addBuyer(self, atGate: boolean)
	local rng = self.rng
	local b = {
		id = "b-" .. self.nextBuyer,
		n = self.nextBuyer,
		speed = rng:range(self.cfg.WALK_SPEED[1], self.cfg.WALK_SPEED[2]),
		look = rng:int(1, 1000),
		carry = nil,
	}
	self.nextBuyer += 1
	b.pos = atGate and Layout.gate(rng) or Layout.randomSpot(rng, self:aisles())
	table.insert(self.buyers, b)
	if atGate then
		walkTo(self, b, Layout.randomSpot(rng, self:aisles()), "stroll")
	else
		standUntil(self, b, self.now + rng:range(0, 4), "browse")
	end
	return b
end

local function shop(self, b)
	local rng = self.rng
	-- shop for something someone sells (a small market may not have all four)
	local sold, seen = {}, {}
	for _, s in self.sellers do
		if (s.state == "open" or s.state == "setup") and not seen[s.good] then
			seen[s.good] = true
			table.insert(sold, s.good)
		end
	end
	table.sort(sold)
	b.want = #sold > 0 and rng:pick(sold) or rng:pick(self.goodList).id
	local s = chooseStall(self, b)
	if s then
		b.target = s.id
		s.reserved += 1
		walkTo(self, b, counterSpot(self, b, s), "walk")
	else
		b.target = nil
		walkTo(self, b, Layout.randomSpot(rng, self:aisles()), "stroll")
	end
end

local function release(self, b)
	local s = b.target and self.byId[b.target]
	if s and s.reserved > 0 then
		s.reserved -= 1
	end
	b.target = nil
end

local function dealDone(self, b, s)
	local cfg = self.cfg
	s.reserved = math.max(0, s.reserved - 1)
	b.target = nil
	if not (s.state == "open" and s.stock > 0) then
		standUntil(self, b, self.now + 0.5, "browse")
		return
	end
	local price = s.price
	s.stock -= 1
	table.insert(s.sold, self.now)
	self.count.deals += 1
	push(self, "deals")
	if s.kind == "honest" then
		table.insert(self.goods[s.good].sales, { t = self.now, p = price })
		if self.rng:chance(0.6) then
			s.ratings += 1
			s.ratingSum += self.rng:range(3.8, 5)
		end
		b.carry = s.good
		self:emit({ k = "deal", buyer = b.id, seller = s.id, price = math.floor(price + 0.5), ok = true })
		if s.stock <= 0 then
			setState(self, s, "restock", self.now + self.rng:range(cfg.RESTOCK_S[1], cfg.RESTOCK_S[2]))
		end
		walkTo(self, b, Layout.randomSpot(self.rng, self:aisles()), "stroll")
	else
		-- a fraud nobody blocked in time: a buyer paid it. An escape.
		local why = s.allowedBy == "monitor" and "missed" or (s.allowedBy == "watcher" and "judged" or "waited")
		self.count.escaped[why] += 1
		push(self, "escaped")
		b.carry = nil
		self:emit({
			k = "deal",
			buyer = b.id,
			seller = s.id,
			price = math.floor(price + 0.5),
			ok = false,
			why = why,
		})
		s.reason = "took payment, never delivered"
		setState(self, s, "shuttered", self.now + cfg.BOARDED_S)
		walkTo(self, b, Layout.randomSpot(self.rng, self:aisles()), "cheated")
	end
end

local function stepBuyer(self, b)
	-- a buyer can make several transitions in one tick (e.g. arrive, then wait)
	for _ = 1, 4 do
		if self.now < b.t1 then
			return
		end
		b.pos = b.to
		local st = b.state
		if st == "browse" or st == "stroll" or st == "cheated" then
			if st ~= "browse" then
				b.carry = (st == "stroll") and b.carry or nil
				standUntil(self, b, self.now + self.rng:range(self.cfg.BROWSE_S[1], self.cfg.BROWSE_S[2]), "browse")
				if b.carry and self.rng:chance(0.5) then
					b.carry = nil -- put it away
				end
			else
				shop(self, b)
			end
		elseif st == "walk" or st == "wait" then
			local s = b.target and self.byId[b.target]
			if not s or not (s.state == "open" or s.state == "setup") then
				release(self, b)
				standUntil(self, b, self.now + 0.6, "browse")
			elseif s.state == "setup" then
				standUntil(self, b, math.max(s.openAt, self.now + 0.1), "wait")
			else
				local dealS = self.cfg.DEAL_S + (self.signatures and self.cfg.SIG_PAYMENT_S or 0)
				local start = math.max(self.now, s.busyUntil)
				s.busyUntil = start + dealS
				if start > self.now + 0.05 then
					standUntil(self, b, start, "queue")
				else
					standUntil(self, b, start + dealS, "deal")
				end
			end
		elseif st == "queue" then
			-- our turn at the counter (the slot was booked when we joined the queue)
			local s = b.target and self.byId[b.target]
			if s and s.state == "open" then
				local dealS = self.cfg.DEAL_S + (self.signatures and self.cfg.SIG_PAYMENT_S or 0)
				standUntil(self, b, self.now + dealS, "deal")
			else
				release(self, b)
				standUntil(self, b, self.now + 0.6, "browse")
			end
		elseif st == "deal" then
			local s = b.target and self.byId[b.target]
			if s then
				dealDone(self, b, s)
			else
				standUntil(self, b, self.now + 0.5, "browse")
			end
		end
	end
end

------------------------------------------------------------------ size

function MarketSim:aisles(): number
	-- enough aisles for the stalls this market needs, with room to spare
	local need = MarketSim.sellersFor(self.n, self.cfg) * 1.3 + 6
	for a = 1, Layout.AISLES do
		if Layout.capacity(a) >= need then
			return a
		end
	end
	return Layout.AISLES
end

-- Grow or shrink the market. Newcomers walk in; stalls open (each a listing).
function MarketSim:setSize(n: number, instant: boolean?)
	n = math.max(2, math.floor(n))
	local old = self.n
	self.n = n
	local wantSellers = MarketSim.sellersFor(n, self.cfg)
	local wantBuyers = n - wantSellers
	-- buyers
	while #self.buyers < wantBuyers do
		addBuyer(self, not instant)
	end
	while #self.buyers > wantBuyers do
		local b = table.remove(self.buyers)
		release(self, b)
		self:emit({ k = "buyerGone", id = b.id })
	end
	-- sellers
	local have = honestCount(self)
	if have < wantSellers then
		for i = 1, wantSellers - have do
			local p = { kind = "honest", established = true, instant = instant }
			if instant then
				arrive(self, p)
			else
				-- staggered over ~20 s, so the square fills rather than pops
				p.at = self.now + 1 + (i - 1) * math.min(0.4, 20 / (wantSellers - have))
				table.insert(self.pending, p)
			end
		end
	elseif have > wantSellers then
		local extra = have - wantSellers
		-- drop pending first, then stalls, newest first
		for i = #self.pending, 1, -1 do
			if extra > 0 and self.pending[i].kind == "honest" then
				table.remove(self.pending, i)
				extra -= 1
			end
		end
		for i = #self.sellers, 1, -1 do
			local s = self.sellers[i]
			if extra > 0 and s.kind == "honest" and s.state ~= "gone" and s.state ~= "blocked" then
				remove(self, s, "packed up")
				extra -= 1
			end
		end
	end
	self:emit({ k = "size", n = n, old = old, aisles = self:aisles() })
end

------------------------------------------------------------------ settings

function MarketSim:setMonitor(mode: string, name: string?)
	assert(mode == "off" or mode == "rules" or mode == "external", "monitor: off | rules | external")
	self.monitor = mode
	self.monitorName = name or (mode == "external" and "external" or "rules")
	-- cases already in an inbox stay there; the next ones are routed anew
	self:emit({ k = "setting", monitor = mode, signatures = self.signatures })
end

function MarketSim:setSignatures(on: boolean)
	self.signatures = on and true or false
	self:emit({ k = "setting", monitor = self.monitor, signatures = self.signatures })
end

-- The agent slot: a seller's policy is "scripted" or "external" (the gateway).
function MarketSim:setPolicy(sellerId: string, policy: string, label: string?, driver: string?)
	local s = self.byId[sellerId]
	if not s then
		return false
	end
	s.policy = policy
	s.label = label
	s.driver = driver
	emitStall(self, s)
	return true
end

------------------------------------------------------------------ prices

local function nudge(self, s)
	local cfg = self.cfg
	if s.policy == "external" and s.extAt and self.now - s.extAt < cfg.AGENT_HOLD_S then
		return -- an outside agent set this price; it holds
	end
	if s.kind ~= "honest" then
		return -- frauds keep their bait price
	end
	local recent = 0
	for i = #s.sold, 1, -1 do
		if s.sold[i] >= self.now - 20 then
			recent += 1
		else
			break
		end
	end
	local market = marketOf(self, s.good)
	local p = s.price
	if s.state == "open" or s.state == "restock" then
		if recent >= 3 then
			p *= 1 + cfg.NUDGE_UP
		elseif recent == 0 and s.state == "open" and self.now - (s.openAt or 0) > 15 then
			p *= 1 - cfg.NUDGE_DOWN
		end
	end
	p += (market - p) * cfg.NUDGE_TO_MARKET
	local base = self.goods[s.good].base
	p = math.clamp(p, base * cfg.PRICE_CLAMP[1], base * cfg.PRICE_CLAMP[2])
	if math.abs(p - s.price) >= 1 then
		s.price = p
		emitStall(self, s)
	end
end

local function updateMarket(self)
	local cut = self.now - self.cfg.MARKET_WINDOW
	for _, g in self.goodList do
		local keep, ps = {}, {}
		for _, sale in g.sales do
			if sale.t >= cut then
				table.insert(keep, sale)
				table.insert(ps, sale.p)
			end
		end
		g.sales = keep
		local m = median(ps)
		if m then
			g.market = m
		end
	end
	self:emit({ k = "prices", p = self:prices() })
end

------------------------------------------------------------------ the tick

local function stepSeller(self, s)
	local cfg = self.cfg
	local st = s.state
	if st == "setup" then
		if self.now >= s.openAt then
			setState(self, s, "open")
		end
	elseif st == "restock" then
		if self.now >= s.stateUntil then
			if s.kind == "honest" and self.rng:chance(cfg.RETIRE_CHANCE) then
				remove(self, s, "retired")
			else
				list(self, s)
			end
		end
	elseif st == "blocked" or st == "shuttered" or st == "rejected" then
		if self.now >= s.stateUntil then
			remove(self, s)
		end
	end
	if s.leaveAt and LIVE[s.state] and self.now >= s.leaveAt then
		remove(self, s, "left")
	end
	if self.now >= s.nextNudge then
		s.nextNudge = self.now + cfg.NUDGE_EVERY
		nudge(self, s)
	end
end

function MarketSim:step(dt: number)
	local cfg = self.cfg
	local rng = self.rng
	self.now += dt
	self.unwatched = self.unwatched or {}

	-- the scripted fraud agents: a steady rate that scales with N
	local perMin = math.max(cfg.FRAUD_MIN_PER_MIN, cfg.FRAUD_PER_TRADER_MIN * self.n)
	if rng:chance(perMin / 60 * dt) then
		self:injectFraud(rng:chance(cfg.IMPOSTOR_SHARE) and "impostor" or "scam")
	end

	-- keep the honest seller count at N's share: newcomers replace leavers
	local want = MarketSim.sellersFor(self.n, cfg)
	local have = honestCount(self)
	if have < want then
		for _ = 1, want - have do
			table.insert(self.pending, {
				kind = "honest",
				at = self.now + rng:range(cfg.NEWCOMER_DELAY[1], cfg.NEWCOMER_DELAY[2]),
			})
		end
	end
	local i = 1
	while i <= #self.pending do
		local p = self.pending[i]
		if self.now >= p.at then
			table.remove(self.pending, i)
			arrive(self, p)
		else
			i += 1
		end
	end

	for _, s in self.sellers do
		if s.state ~= "gone" then
			stepSeller(self, s)
		end
	end

	-- cases: an external monitor's time runs out; deadlines pass
	local k = 1
	while k <= #self.caseList do
		local c = self.caseList[k]
		if c.stage == "done" then
			table.remove(self.caseList, k)
		else
			if c.stage == "monitor" and self.now >= c.monitorBy then
				self.gatewayStats.fallbacks += 1
				local v, why = MarketSim.ruleMonitor(c, self.signatures, cfg)
				self:monitorVerdict(c, v, why, "rules (fallback)")
			end
			if c.stage ~= "done" and self.now >= c.deadline_at then
				MarketSim.closeCase(self, c, "expired", c.stage == "inbox" and "deadline" or "monitor")
			end
			if c.stage == "done" then
				table.remove(self.caseList, k)
			else
				k += 1
			end
		end
	end

	for _, w in self.watchers do
		autoWatch(self, w)
	end

	for _, b in self.buyers do
		stepBuyer(self, b)
	end

	if self.now >= self.nextPriceAt then
		self.nextPriceAt = self.now + 1
		updateMarket(self)
	end

	-- forget sellers that are gone (keep the array short)
	if #self.sellers > 0 and (math.floor(self.now / dt) % 40 == 0) then
		local keep = {}
		for _, s in self.sellers do
			if s.state ~= "gone" then
				table.insert(keep, s)
			else
				self.byId[s.id] = nil
			end
		end
		self.sellers = keep
	end
end

-- run until simulated time t, in fixed steps
function MarketSim:runUntil(t: number, dt: number?)
	dt = dt or 0.25
	while self.now < t - 1e-9 do
		self:step(dt)
	end
end

------------------------------------------------------------------ snapshot

-- everything a client that just joined needs to draw the market as it is
function MarketSim:snapshot()
	local stalls = {}
	for _, s in self.sellers do
		if s.state ~= "gone" then
			table.insert(stalls, self:publicSeller(s))
		end
	end
	local buyers = {}
	for _, b in self.buyers do
		table.insert(buyers, {
			id = b.id,
			from = b.from,
			to = b.to,
			t0 = b.t0,
			t1 = b.t1,
			state = b.state,
			carry = b.carry,
			look = b.look,
			target = b.target,
		})
	end
	local cases = {}
	for _, c in self.caseList do
		if c.stage == "inbox" then
			table.insert(cases, self:publicCase(c))
		end
	end
	return {
		t = self.now,
		n = self.n,
		aisles = self:aisles(),
		stalls = stalls,
		buyers = buyers,
		cases = cases,
		prices = self:prices(),
		monitor = self.monitor,
		signatures = self.signatures,
	}
end

------------------------------------------------------------------ the gateway

-- The slot contract's request body (docs/market-design.md): one call per tick
-- carrying every case an outside monitor must decide and every decision an
-- outside agent must make.
function MarketSim:gatewayRequest(serverId: string?)
	local cfg = self.cfg
	local cases = {}
	for _, c in self.caseList do
		if c.stage == "monitor" and #cases < cfg.GATEWAY_MAX_CASES then
			local p = self:publicCase(c)
			table.insert(cases, {
				id = p.id,
				stall = p.stall,
				good = p.good,
				price = p.price,
				market = p.market,
				age_s = p.age_s,
				ratings = p.ratings,
				rating_avg = p.rating_avg,
				signature = p.signature,
				twin = p.twin,
				deadline_s = p.deadline_s,
			})
		end
	end
	local decisions = {}
	for _, s in self.sellers do
		if s.policy == "external" and LIVE[s.state] and #decisions < cfg.GATEWAY_MAX_DECISIONS then
			local sold = 0
			for _, t in s.sold do
				if t >= self.now - 60 then
					sold += 1
				end
			end
			table.insert(decisions, {
				agent = s.id,
				-- the registration that drives it (gateway decision 5); nil = the first with the role
				driver = s.driver or cfg.GATEWAY_DRIVER,
				role = "seller",
				good = s.good,
				stock = s.stock,
				price = math.floor(s.price + 0.5),
				market = math.floor(marketOf(self, s.good) + 0.5),
				sold_last_min = sold,
			})
		end
	end
	return {
		server = serverId or "local",
		t = math.floor(self.now * 10 + 0.5) / 10,
		-- which registered monitor to ask (gateway decision 4); none = every one, then its rules
		monitor = (self.monitorName ~= "external" and self.monitorName ~= "gateway") and self.monitorName or cfg.GATEWAY_MONITOR,
		market = self:prices(),
		lever = { signatures = self.signatures },
		-- the slot is off unless it is external: then no cases are sent at all
		cases = cases,
		decisions = decisions,
	}
end

-- Apply a gateway response. Unknown, late or malformed entries are ignored:
-- whatever is missing falls back to the built-in policy.
function MarketSim:applyGateway(resp)
	if type(resp) ~= "table" then
		return 0, 0
	end
	self.gatewayStats.ticks += 1
	local nv, na = 0, 0
	if type(resp.verdicts) == "table" then
		for _, v in resp.verdicts do
			if type(v) == "table" and type(v.case) == "string" then
				local c = self.cases[v.case]
				local verdict = v.verdict
				if c and c.stage == "monitor" and (verdict == "allow" or verdict == "block" or verdict == "escalate") then
					-- untrusted text (gateway decision 7): the server filters it before a player sees it
					local reason = type(v.reason) == "string" and string.sub(v.reason, 1, 120) or nil
					local name = type(v.monitor) == "string" and string.sub(v.monitor, 1, 32) or "external"
					self:monitorVerdict(c, verdict, reason, name)
					nv += 1
				end
			end
		end
	end
	if type(resp.actions) == "table" then
		local cfg = self.cfg
		for _, a in resp.actions do
			if type(a) == "table" and type(a.agent) == "string" and type(a.set_price) == "number" then
				local s = self.byId[a.agent]
				if s and s.policy == "external" and LIVE[s.state] and a.set_price == a.set_price then
					local base = self.goods[s.good].base
					s.price = math.clamp(a.set_price, base * cfg.PRICE_CLAMP[1], base * cfg.PRICE_CLAMP[2])
					s.extAt = self.now
					emitStall(self, s)
					na += 1
				end
			end
		end
	end
	self.gatewayStats.verdicts += nv
	self.gatewayStats.actions += na
	return nv, na
end

return MarketSim
