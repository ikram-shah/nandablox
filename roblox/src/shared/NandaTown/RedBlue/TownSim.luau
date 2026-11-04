-- TownSim: a small, continuously running NANDA Town marketplace, in pure Luau.
--
-- This is NOT NANDA Town's code. It is a re-implementation, for the red vs.
-- blue spike, of just enough of the marketplace scenario to play on: two
-- sellers, three buyers, and the deal cycle
--
--   quote_request → quote_response → nego_offer → nego_counter → offer_accepted
--   → escrow_held → purchase_order → delivery → invoice → escrow_released
--   → payment_settled → receipt_attested → reputation_updated
--
-- with three layers modelled: auth (hmac.v1 | plain.v1), registry (index.v1 |
-- index.owned.v1) and transport (deliver, duplicate, drop). It speaks NANDA
-- Town's event envelope ({event_id, at, observer, kind, subject, detail}, see
-- docs/trace-format.md) plus a few rendering hints the replay understands:
--
--   seq, id      ev-N order (id == event_id)
--   layer        which building the event belongs to
--   travel       message_sent / message_duplicated: seconds on the road
--   origin       message_sent: where the courier really sets off, when that is
--                not the sender's stall ("gate" for a forgery, red's stall for
--                an impostor). This is the fair tell, visible to everyone.
--   dest         message_sent: where the courier really goes, when that is not
--                the addressee (a spoofed card routes to red's stall)
--   card         card_*: the card id (what blue clicks to flag it)
--   price        card_*: the card's listed unit price
--   _threat      PRIVATE: the threat id. Keys starting with "_" never leave
--                the server (RedBlueServer strips them).
--
-- No Roblox services: time is passed in (sim:advance(t), seconds since the
-- round started), randomness is the seeded Rng, so Lune can run it headless.

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local Rng = sibling("Rng")
local Policy = sibling("Policy")
local Scale = sibling("Scale")

local TownSim = {}
TownSim.__index = TownSim

local KIND_LAYER = {
	account_opened = "payments",
	escrow_held = "payments",
	escrow_released = "payments",
	escrow_refunded = "payments",
	payment_settled = "payments",
	participant_joined = "town",
	identity_created = "identity",
	card_registered = "registry",
	card_unverified = "registry",
	card_publish_refused = "registry",
	card_withdrawn = "registry",
	registry_lookup = "registry",
	signature_invalid = "auth",
	message_sent = "transport",
	message_delivered = "transport",
	message_dropped = "transport",
	message_duplicated = "transport",
	message_delayed = "transport",
	delivery_failed = "transport",
	negotiation_started = "negotiation",
	offer_made = "negotiation",
	counter_made = "negotiation",
	offer_accepted = "negotiation",
	negotiation_abandoned = "negotiation",
	receipt_attested = "data_facts",
	reputation_updated = "trust",
	duplicate_recognized = "transport",
	message_unhandled = "communication",
}
TownSim.KIND_LAYER = KIND_LAYER

-- opts = { config, layers?, seed?, counter? ({n} shared event counter),
--          policies? ({buyer, seller, impostor}), size? (agents; default 5,
--          the original town. Larger towns add a crowd: RedBlue/Scale.luau) }
function TownSim.new(opts)
	local cfg = opts.config
	local layers = {}
	for k, v in opts.layers or cfg.DEFAULT_LAYERS do
		layers[k] = v
	end
	local self = setmetatable({
		cfg = cfg,
		layers = layers,
		rng = Rng.new(opts.seed or 42),
		policy = opts.policies or { buyer = Policy.ScriptedBuyer, seller = Policy.ScriptedSeller, impostor = Policy.Impostor },
		counter = opts.counter or { n = 0 },
		now = 0,
		queue = {},
		qseq = 0,
		out = {},
		resolved = {}, -- threats that ended (escaped / blocked), drained by Game
		n = { msg = 0, conv = 0, nid = 0, card = 0, fact = 0, threat = 0 },
		balances = {},
		reputation = {},
		cards = {}, -- active listings, in publish order
		messages = {},
		deals = {},
		buyers = {},
		threats = {},
		orders = {}, -- buyer -> { order ids, newest last }
		stats = { dealsSettled = 0, centsSettled = 0, forgeries = 0, spoofs = 0, baits = 0 },
		started = false,
		-- who is in town: the five, plus a crowd at scale (joined grows as they arrive)
		pop = Scale.population(cfg, opts.size),
		scaled = opts.size ~= nil, -- the oversight demo (any size, 5 included)
		sellerNames = {},
		buyerNames = {},
		joined = {},
		crowdCount = 0,
		lastPrune = 0,
		baitCount = 0,
	}, TownSim)
	for _, s in cfg.SELLERS do
		table.insert(self.sellerNames, s)
		self.joined[s] = true
	end
	for _, b in cfg.BUYERS do
		table.insert(self.buyerNames, b)
		self.joined[b] = true
	end
	return self
end

-- agents in town now (sellers + buyers; red is not counted)
function TownSim:size(): number
	return #self.sellerNames + #self.buyerNames
end

------------------------------------------------------------------------ plumbing

function TownSim:emit(observer: string, kind: string, subject: string, detail: { [string]: any }?, extra: { [string]: any }?)
	self.counter.n += 1
	local n = self.counter.n
	local e = {
		seq = n,
		id = "ev-" .. n,
		event_id = "ev-" .. n,
		at = math.floor(self.now * 100 + 0.5) / 100,
		observer = observer,
		kind = kind,
		subject = subject,
		layer = KIND_LAYER[kind] or "other",
		detail = detail or {},
	}
	if extra then
		for k, v in extra do
			e[k] = v
		end
	end
	table.insert(self.out, e)
	return e
end

function TownSim:drain(): { any }
	local o = self.out
	self.out = {}
	return o
end

function TownSim:drainResolved(): { any }
	local o = self.resolved
	self.resolved = {}
	return o
end

function TownSim:schedule(t: number, fn: () -> ())
	self.qseq += 1
	table.insert(self.queue, { t = t, s = self.qseq, fn = fn })
end

function TownSim:after(dt: number, fn: () -> ())
	self:schedule(self.now + dt, fn)
end

-- Run everything due up to time t (seconds since the round started).
function TownSim:advance(t: number)
	while true do
		local bi = nil
		for i, q in self.queue do
			if q.t <= t and (bi == nil or q.t < self.queue[bi].t or (q.t == self.queue[bi].t and q.s < self.queue[bi].s)) then
				bi = i
			end
		end
		if not bi then
			break
		end
		local q = table.remove(self.queue, bi)
		self.now = math.max(self.now, q.t)
		q.fn()
	end
	self.now = math.max(self.now, t)
	if self.crowdCount > 0 and self.now - self.lastPrune >= 5 then
		self:prune()
	end
end

-- At scale: forget messages and deals that ended a while ago, so the scans
-- over them stay short. (Never in the original five-agent town.)
local DONE = { delivered = true, void = true, dropped = true, paid = true, blocked = true }
function TownSim:prune()
	self.lastPrune = self.now
	local before = self.now - (self.cfg.PRUNE_SECONDS or 30)
	for id, m in self.messages do
		if DONE[m.state] and m.sentAt < before and not (m.threat and self.threats[m.threat] and self.threats[m.threat].state == "live") then
			self.messages[id] = nil
		end
	end
	for id, d in self.deals do
		if (d.state == "settled" or d.state == "abandoned") and (d.endedAt or self.now) < before then
			self.deals[id] = nil
		end
	end
end

function TownSim:hop(): number
	return self.cfg.HOP_SECONDS + (self.layers.auth == "hmac.v1" and self.cfg.HMAC_HOP_EXTRA or 0)
end

function TownSim:newId(kind: string, prefix: string): string
	self.n[kind] += 1
	return prefix .. self.n[kind]
end

------------------------------------------------------------------------ start

function TownSim:start()
	assert(not self.started, "started twice")
	self.started = true
	local cfg = self.cfg
	local function open(name: string, cents: number)
		self.balances[name] = cents
		self:emit("town", "account_opened", name, { balance_cents = cents })
	end
	for _, s in cfg.SELLERS do
		open(s, 0)
		self.reputation[s] = 0
	end
	for _, b in cfg.BUYERS do
		open(b, cfg.BUYER_BALANCE)
	end
	open(cfg.ATTACKER, 0)
	for _, s in cfg.SELLERS do
		self:emit("town", "participant_joined", s, { role = "seller" })
		self:publish(s, s, true)
	end
	for _, b in cfg.BUYERS do
		self:emit("town", "participant_joined", b, { role = "buyer" })
		self.buyers[b] = { name = b, deal = nil, deals = 0, knownOrders = {} }
		self.orders[b] = {}
		self:after(self.rng:range(cfg.BUYER_FIRST_DEAL[1], cfg.BUYER_FIRST_DEAL[2]), function()
			self:startDeal(b)
		end)
	end
	self:emit("town", "participant_joined", cfg.ATTACKER, { role = "attacker" })
	self:addCrowd(0)
end

------------------------------------------------------------------------ the crowd

-- Grow the town to `size` agents while it runs (it never shrinks: a smaller
-- town is a new round). Newcomers arrive CROWD_JOIN_STAGGER apart. Returns
-- how many are on their way.
function TownSim:grow(size: number): number
	local pop = Scale.population(self.cfg, size)
	if pop.size <= self.pop.size then
		return 0
	end
	self.pop = pop
	return self:addCrowd(self.cfg.CROWD_JOIN_STAGGER or 0)
end

-- Everyone in self.pop who has not joined yet joins: sellers open a stall and
-- list a card (a quarter of them with an opening sale), buyers start trading.
function TownSim:addCrowd(stagger: number): number
	local cfg = self.cfg
	local pop = self.pop
	local list = {}
	-- interleave sellers and buyers so the town fills evenly
	local s, b = {}, {}
	for _, n in pop.sellers do
		if not self.joined[n] then
			table.insert(s, n)
		end
	end
	for _, n in pop.buyers do
		if not self.joined[n] then
			table.insert(b, n)
		end
	end
	local i, j = 1, 1
	while i <= #s or j <= #b do
		if i <= #s and (j > #b or (i - 1) / math.max(#s, 1) <= (j - 1) / math.max(#b, 1)) then
			table.insert(list, s[i])
			i += 1
		else
			table.insert(list, b[j])
			j += 1
		end
	end
	for k, name in list do
		self.joined[name] = true
		local function arrive()
			self:joinCrowd(name)
		end
		if stagger > 0 then
			self:after(k * stagger, arrive)
		else
			arrive()
		end
	end
	return #list
end

function TownSim:joinCrowd(name: string)
	local cfg = self.cfg
	local info = self.pop.crowd[name]
	if not info then
		return
	end
	self.crowdCount += 1
	if info.role == "seller" then
		table.insert(self.sellerNames, name)
		self.balances[name] = 0
		self.reputation[name] = 0
		self:emit("town", "account_opened", name, { balance_cents = 0 })
		self:emit("town", "participant_joined", name, { role = "seller", crowd = info.k })
		local list = self.pop.price[name] or 2000
		local price = list
		if self.rng:chance(cfg.CROWD_SALE_RATE or 0) then
			local u = self.rng:range(cfg.CROWD_SALE_UNDERCUT[1], cfg.CROWD_SALE_UNDERCUT[2])
			price = math.floor(self:marketPrice() * (1 - u) / 5 + 0.5) * 5
		end
		self:publish(name, name, true, price)
		self:scheduleReprice(name)
	else
		table.insert(self.buyerNames, name)
		self.balances[name] = cfg.BUYER_BALANCE
		self:emit("town", "account_opened", name, { balance_cents = cfg.BUYER_BALANCE })
		self:emit("town", "participant_joined", name, { role = "buyer", crowd = info.k })
		local loyal = self.rng:chance(cfg.CROWD_LOYAL_SHARE or 0.5)
		self.buyers[name] = {
			name = name,
			deal = nil,
			deals = 0,
			knownOrders = {},
			favorite = loyal and self.rng:pick(self.sellerNames) or nil,
			hunter = not loyal,
		}
		self.orders[name] = {}
		self:after(self.rng:range(cfg.BUYER_FIRST_DEAL[1], cfg.BUYER_FIRST_DEAL[2]), function()
			self:startDeal(name)
		end)
	end
end

-- A crowd seller now and then lists again under its own name at a new price
-- (a newer card, signed by the same key) and takes the old one down. Under
-- plain.v1 that looks exactly like a spoofed card: two cards, one name.
function TownSim:scheduleReprice(name: string)
	local cfg = self.cfg
	self:after(self.rng:range(cfg.CROWD_REPRICE[1], cfg.CROWD_REPRICE[2]), function()
		local old = {}
		for _, c in self.cards do
			if c.name == name and c.publisher == name then
				table.insert(old, c)
			end
		end
		local list = self.pop.price[name] or 2000
		local spread = cfg.CROWD_REPRICE_SPREAD or 0.06
		local price = math.floor(list * (1 + self.rng:range(-spread, spread)) / 5 + 0.5) * 5
		self:publish(name, name, true, price)
		for _, c in old do
			self:withdraw(c, "repriced")
		end
		self:scheduleReprice(name)
	end)
end

-- The going rate: the median price of the honest listings.
function TownSim:marketPrice(): number
	local prices = {}
	for _, c in self.cards do
		if not c.threat then
			table.insert(prices, c.price)
		end
	end
	if #prices == 0 then
		return 2000
	end
	table.sort(prices)
	return prices[(#prices + 1) // 2]
end

-- an honest seller's card, or (publisher ~= name) a spoofed one
function TownSim:publish(name: string, publisher: string, verified: boolean, price: number?, threat: string?)
	local id = self:newId("card", "card-")
	local card = {
		id = id,
		seq = self.n.card,
		name = name,
		capabilities = { "sell.widget" },
		publisher = publisher,
		verified = verified,
		price = price or self.cfg.LIST_PRICE[name] or 2000,
		threat = threat,
		stallUntil = -1,
	}
	table.insert(self.cards, card)
	local kind = verified and "card_registered" or "card_unverified"
	local detail = verified and { capabilities = card.capabilities, verified = true } or { capabilities = card.capabilities, publisher = publisher }
	self:emit("town", kind, name, detail, { card = id, price = card.price, _threat = threat })
	return card
end

function TownSim:cardById(id: string)
	for _, c in self.cards do
		if c.id == id then
			return c
		end
	end
	return nil
end

function TownSim:withdraw(card, reason: string)
	local i = table.find(self.cards, card)
	if i then
		table.remove(self.cards, i)
		self:emit("town", "card_withdrawn", card.name, { publisher = card.publisher, reason = reason }, { card = card.id, _threat = card.threat })
	end
end

function TownSim:listedNames(): { [string]: boolean }
	local s = {}
	for _, c in self.cards do
		s[c.name] = true
	end
	return s
end

------------------------------------------------------------------------ messages

-- opts = { dest?, origin?, deal?, threat?, forged?, conv? }
function TownSim:send(from: string, to: string, kind: string, body: { [string]: any }, o: { [string]: any }?)
	local opts = o or {}
	local id = self:newId("msg", "m-")
	local hop = self:hop()
	local msg = {
		id = id,
		from = from,
		to = to,
		dest = opts.dest or to,
		origin = opts.origin,
		kind = kind,
		body = body,
		conv = opts.conv,
		deal = opts.deal,
		threat = opts.threat,
		forged = opts.forged == true,
		sentAt = self.now,
		state = "road",
		token = 0,
	}
	self.messages[id] = msg
	self:emit(from, "message_sent", id, { to = to, kind = kind, conversation = opts.conv, body = body }, {
		travel = hop,
		origin = opts.origin,
		dest = msg.dest ~= to and msg.dest or nil,
		_threat = opts.threat,
	})
	if msg.forged and self.layers.auth == "hmac.v1" then
		-- the guards check every signature at the gate
		msg.state = "blocked"
		self:emit("town", "signature_invalid", id, { claimed = from }, { _threat = opts.threat })
		self:emit("town", "delivery_failed", id, { to = to, kind = kind, reason = "signature_invalid" }, { _threat = opts.threat })
		return msg
	end
	if kind == "quote_request" and self.rng:chance(self.cfg.DROP_QUOTE_RATE) then
		self:after(hop * 0.5, function()
			if msg.state ~= "road" then
				return
			end
			msg.state = "dropped"
			self:emit("town", "message_dropped", id, { to = to, kind = kind, fault = "drop" })
			local deal = msg.deal
			self:after(self.cfg.RETRY_SECONDS, function()
				if deal and not deal.aborted and deal.state == "quoting" then
					self:send(deal.buyer, deal.seller, "quote_request", { sku = "widget" }, { dest = deal.endpoint, deal = deal, threat = deal.threat, conv = deal.conv })
				end
			end)
		end)
		return msg
	end
	self:scheduleDelivery(msg, hop)
	if kind == "delivery" and self.rng:chance(self.cfg.DUPLICATE_DELIVERY_RATE) then
		self:after(0.3, function()
			if msg.state == "void" then
				return
			end
			self:emit("town", "message_duplicated", id, { to = to, kind = kind, fault = "duplicate" }, { travel = hop + 0.5, from = from, origin = msg.origin, dest = msg.dest ~= to and msg.dest or nil })
			self:after(hop + 0.5, function()
				if msg.state == "void" then
					return
				end
				self:emit("town", "message_delivered", id, { to = to, kind = kind }, { from = from, copy = 2 })
				local deal = msg.deal
				if deal then
					self:emit(deal.buyer, "duplicate_recognized", deal.order_id or id, { kind = kind })
				end
			end)
		end)
	end
	return msg
end

function TownSim:scheduleDelivery(msg, dt: number)
	msg.token += 1
	local token = msg.token
	msg.deliverAt = self.now + dt
	self:after(dt, function()
		if msg.token ~= token or msg.state ~= "road" then
			return
		end
		self:deliver(msg)
	end)
end

function TownSim:deliver(msg)
	msg.state = "delivered"
	-- hold: seconds an invoice sits on the buyer's desk before it is paid (a
	-- forged one waits for its payout, an honest one is paid at once)
	local hold = nil
	if msg.kind == "invoice" then
		hold = msg.forged and math.max(0, msg.sentAt + self.cfg.FORGE_WINDOW - self.now) or self.cfg.THINK_SECONDS
	end
	self:emit("town", "message_delivered", msg.id, { to = msg.to, kind = msg.kind }, { from = msg.from, hold = hold, _threat = msg.threat })
	local deal = msg.deal
	if deal and deal.aborted then
		return
	end
	local k = msg.kind
	local think = self.cfg.THINK_SECONDS
	if k == "invoice" and msg.forged then
		self:onForgedInvoice(msg)
		return
	end
	if not deal then
		return
	end
	if k == "quote_request" then
		self:after(think, function()
			self:sellerQuote(deal)
		end)
	elseif k == "quote_response" then
		self:after(think, function()
			self:buyerOffer(deal, msg.body.unit_cents)
		end)
	elseif k == "nego_offer" then
		self:after(think, function()
			self:sellerCounter(deal, msg.body.cents)
		end)
	elseif k == "nego_counter" then
		self:after(think, function()
			self:buyerAccept(deal, msg.body.cents)
		end)
	elseif k == "purchase_order" then
		self:after(think, function()
			self:sellerShip(deal)
		end)
	elseif k == "delivery" then
		deal.delivered = true
	elseif k == "invoice" then
		self:after(think, function()
			self:buyerPay(deal, msg)
		end)
	end
end

------------------------------------------------------------------------ the deal cycle

function TownSim:buyerView(b: string)
	return {
		name = b,
		now = self.now,
		balance = self.balances[b] or 0,
		reputation = self.reputation,
		layers = self.layers,
		listed = self:listedNames(),
		knownOrders = self.buyers[b] and self.buyers[b].knownOrders or {},
		favorite = (self.cfg.BUYER_FAVORITE and self.cfg.BUYER_FAVORITE[b]) or (self.buyers[b] and self.buyers[b].favorite) or nil,
	}
end

function TownSim:sellerView(deal)
	return {
		name = deal.seller,
		now = self.now,
		balance = self.balances[deal.endpoint] or 0,
		reputation = self.reputation,
		layers = self.layers,
		listPrice = deal.card.price,
	}
end

function TownSim:sellerPolicy(deal)
	return deal.endpoint == self.cfg.ATTACKER and self.policy.impostor or self.policy.seller
end

-- the seller side's messages: an impostor answers under the card's name, but
-- its couriers set off from red's stall
function TownSim:sellerSend(deal, kind: string, body)
	local impostor = deal.endpoint ~= deal.seller
	return self:send(deal.seller, deal.buyer, kind, body, {
		origin = impostor and deal.endpoint or nil,
		deal = deal,
		threat = deal.threat,
		conv = deal.conv,
	})
end

function TownSim:buyerSend(deal, kind: string, body)
	return self:send(deal.buyer, deal.seller, kind, body, { dest = deal.endpoint, deal = deal, threat = deal.threat, conv = deal.conv })
end

function TownSim:startDeal(b: string)
	local buyer = self.buyers[b]
	if not buyer or buyer.deal then
		return
	end
	local owned = self.layers.registry == "index.owned.v1"
	local delay = owned and self.cfg.OWNED_LOOKUP_EXTRA or 0
	self:emit(b, "registry_lookup", "sell.widget", { registry = self.layers.registry, owned_check = owned })
	buyer.deal = { pending = true }
	self:after(delay, function()
		local cards = {}
		for _, c in self.cards do
			if c.stallUntil <= self.now then
				table.insert(cards, c)
			end
		end
		if buyer.hunter and #cards > (self.cfg.CROWD_SHOP_AROUND or 4) then
			-- a crowd bargain hunter compares a few listings, not the whole board
			local pool = table.clone(cards)
			local some = {}
			for _ = 1, self.cfg.CROWD_SHOP_AROUND or 4 do
				table.insert(some, table.remove(pool, self.rng:int(1, #pool)))
			end
			cards = some
		end
		local card = #cards > 0 and self.policy.buyer.chooseCard(self:buyerView(b), cards) or nil
		if not card then
			buyer.deal = nil
			self:after(2, function()
				self:startDeal(b)
			end)
			return
		end
		local deal = {
			nid = self:newId("nid", "n-"),
			conv = self:newId("conv", "c-"),
			buyer = b,
			card = card,
			seller = card.name,
			endpoint = card.publisher,
			threat = card.threat,
			state = "quoting",
		}
		self.deals[deal.nid] = deal
		buyer.deal = deal
		if card.threat then
			local th = self.threats[card.threat]
			if th then
				th.routed = (th.routed or 0) + 1
				th.deal = deal
			end
		end
		self:buyerSend(deal, "quote_request", { sku = "widget" })
	end)
end

function TownSim:sellerQuote(deal)
	if deal.aborted then
		return
	end
	local cents = self:sellerPolicy(deal).quote(self:sellerView(deal), { sku = "widget" })
	deal.quote = cents
	deal.state = "quoted"
	self:sellerSend(deal, "quote_response", { sku = "widget", unit_cents = cents })
end

function TownSim:buyerOffer(deal, quote: number)
	if deal.aborted then
		return
	end
	local cents = self.policy.buyer.offer(self:buyerView(deal.buyer), quote)
	deal.state = "haggling"
	self:emit(deal.buyer, "negotiation_started", deal.nid, { seller = deal.seller, subject = "widget" })
	self:emit(deal.buyer, "offer_made", deal.nid, { cents = cents })
	self:buyerSend(deal, "nego_offer", { nid = deal.nid, cents = cents })
end

function TownSim:sellerCounter(deal, offer: number)
	if deal.aborted then
		return
	end
	local cents = self:sellerPolicy(deal).counter(self:sellerView(deal), offer)
	self:emit(deal.seller, "counter_made", deal.nid, { cents = cents }, { origin = deal.endpoint ~= deal.seller and deal.endpoint or nil })
	self:sellerSend(deal, "nego_counter", { nid = deal.nid, cents = cents })
end

function TownSim:buyerAccept(deal, counter: number)
	if deal.aborted then
		return
	end
	local b = deal.buyer
	if not self.policy.buyer.accept(self:buyerView(b), counter) then
		self:abandon(deal, "price")
		return
	end
	local buyer = self.buyers[b]
	buyer.deals += 1
	deal.unit = counter
	deal.cents = counter * self.cfg.QUANTITY
	deal.order_id = string.format("order-%s-%d", b, buyer.deals)
	deal.state = "ordered"
	deal.orderedAt = self.now
	buyer.knownOrders[deal.order_id] = true
	table.insert(self.orders[b], deal.order_id)
	self:emit(b, "offer_accepted", deal.nid, { cents = counter })
	self.balances[b] -= deal.cents
	deal.escrow = deal.cents
	self:emit("town", "escrow_held", deal.order_id, { from = b, cents = deal.cents }, { _threat = deal.threat })
	self:buyerSend(deal, "purchase_order", { nid = deal.nid, order_id = deal.order_id, sku = "widget", quantity = self.cfg.QUANTITY, unit_cents = counter })
end

function TownSim:sellerShip(deal)
	if deal.aborted then
		return
	end
	deal.state = "shipped"
	self:sellerSend(deal, "delivery", { order_id = deal.order_id, sku = "widget", quantity = self.cfg.QUANTITY })
	self:after(self.cfg.THINK_SECONDS, function()
		if deal.aborted then
			return
		end
		self:sellerSend(deal, "invoice", { order_id = deal.order_id, cents = deal.cents, pay_to = deal.seller })
	end)
end

function TownSim:buyerPay(deal, msg)
	if deal.aborted or not deal.escrow then
		return
	end
	local b = deal.buyer
	if not self.policy.buyer.payInvoice(self:buyerView(b), { from = msg.from, order_id = msg.body.order_id, cents = msg.body.cents, pay_to = msg.body.pay_to }) then
		self:emit(b, "message_unhandled", msg.id, { kind = "invoice" })
		return
	end
	local to = deal.endpoint
	local cents = deal.escrow
	deal.escrow = nil
	self.balances[to] = (self.balances[to] or 0) + cents
	self:emit("town", "escrow_released", deal.order_id, { to = to, cents = cents }, { _threat = deal.threat })
	self:emit("town", "payment_settled", deal.order_id, { from = b, to = to, cents = cents, via = "escrow" }, { _threat = deal.threat })
	-- an impostor (a spoofed card) or a fly-by-night stall (bait) sends an empty crate
	local impostor = to ~= deal.seller or deal.threat ~= nil
	local good = not impostor
	self.n.fact += 1
	local fact = "fact-" .. self.n.fact
	self:emit(b, "receipt_attested", deal.seller, { record_id = fact, claim = "trade.outcome", value = good and "good" or "bad" })
	local delta = good and 1 or -1
	self.reputation[deal.seller] = (self.reputation[deal.seller] or 0) + delta
	self:emit(b, "reputation_updated", deal.seller, { outcome = good and "good" or "bad", delta = delta, score = self.reputation[deal.seller], receipt = fact })
	deal.state = "settled"
	if impostor then
		self:escape(deal.threat, cents)
	else
		self.stats.dealsSettled += 1
		self.stats.centsSettled += cents
	end
	self:finishDeal(deal)
end

function TownSim:finishDeal(deal, rest: number?)
	deal.endedAt = self.now
	local buyer = self.buyers[deal.buyer]
	if buyer and buyer.deal == deal then
		buyer.deal = nil
		local r = rest or self.rng:range(self.cfg.BUYER_REST[1], self.cfg.BUYER_REST[2])
		self:after(r, function()
			self:startDeal(deal.buyer)
		end)
	end
end

function TownSim:abandon(deal, reason: string)
	if deal.aborted then
		return
	end
	deal.aborted = true
	deal.state = "abandoned"
	if deal.escrow then
		local cents = deal.escrow
		deal.escrow = nil
		self.balances[deal.buyer] += cents
		self:emit("town", "escrow_refunded", deal.order_id, { to = deal.buyer, cents = cents })
	end
	self:emit(deal.buyer, "negotiation_abandoned", deal.nid, { seller = deal.seller, reason = reason })
	-- couriers of this deal still on the road never arrive
	for _, m in self.messages do
		if m.deal == deal and m.state == "road" then
			m.state = "void"
			self:emit("town", "delivery_failed", m.id, { to = m.to, kind = m.kind, reason = reason })
		end
	end
	self:finishDeal(deal, 3)
end

------------------------------------------------------------------------ attacks

function TownSim:newThreat(kind: string, fields: { [string]: any })
	local id = self:newId("threat", "threat-")
	local th = { id = id, kind = kind, state = "live", createdAt = self.now }
	for k, v in fields do
		th[k] = v
	end
	self.threats[id] = th
	return th
end

function TownSim:resolve(th, outcome: string, cents: number?)
	if th.state ~= "live" then
		return false
	end
	th.state = outcome
	th.resolvedAt = self.now
	th.cents = cents
	table.insert(self.resolved, th)
	return true
end

function TownSim:escape(threatId: string?, cents: number)
	local th = threatId and self.threats[threatId]
	if not th then
		return
	end
	if self:resolve(th, "escaped", cents) and (th.kind == "spoof" or th.kind == "bait") then
		local card = self:cardById(th.cardId)
		if card then
			self:withdraw(card, "the impostor cashed out and left")
		end
		-- one token, one payout: other buyers mid-deal with it are left hanging
		for _, d in self.deals do
			if d.threat == th.id and not d.aborted and d.state ~= "settled" then
				self:abandon(d, "the seller vanished")
			end
		end
	end
end

-- The buyer most worth robbing as `claimed`: one that traded with that seller
-- last, else any buyer.
function TownSim:victimOf(claimed: string): string
	local best, bestT = nil, -1
	for _, d in self.deals do
		if d.seller == claimed and d.endpoint == claimed and d.orderedAt and d.orderedAt >= bestT then
			best, bestT = d.buyer, d.orderedAt
		end
	end
	return best or self.rng:pick(self.buyerNames)
end

-- Red forges an invoice signed as `claimed` (a real seller), redirecting a
-- payment to an alias that is not on the notice board. It enters the roads at
-- the gate. Returns the threat (state "blocked" under hmac.v1).
function TownSim:forge(claimed: string?)
	local cfg = self.cfg
	local seller = claimed or self.rng:pick(self.sellerNames)
	local victim = self:victimOf(seller)
	local orders = self.orders[victim] or {}
	local ref = orders[#orders] or string.format("order-%s-%d", victim, 1)
	local alias = self.rng:pick(cfg.PAYEE_ALIASES)
	self.stats.forgeries += 1
	local th = self:newThreat("forge", { claimed = seller, victim = victim, alias = alias })
	local msg = self:send(seller, victim, "invoice", { order_id = ref, cents = cfg.FORGE_CENTS, pay_to = alias, memo = "balance due" }, {
		origin = "gate",
		threat = th.id,
		forged = true,
	})
	th.msgId = msg.id
	if msg.state == "blocked" then
		self:resolve(th, "blocked")
		return th
	end
	-- the payout: FORGE_WINDOW after it set off, unless someone catches it
	self:after(cfg.FORGE_WINDOW, function()
		if th.state ~= "live" then
			return
		end
		local cents = cfg.FORGE_CENTS
		self.balances[victim] -= cents
		self.balances[cfg.ATTACKER] += cents
		msg.state = "paid"
		self:emit("town", "payment_settled", ref .. "/invoice", { from = victim, to = cfg.ATTACKER, cents = cents, via = "invoice", pay_to = alias }, { _threat = th.id })
		self:resolve(th, "escaped", cents)
	end)
	return th
end

-- a forged invoice arrived: the buyer believes it and will pay at the payout
function TownSim:onForgedInvoice(msg)
	local th = self.threats[msg.threat]
	if not th or th.state ~= "live" then
		return
	end
	local ok = self.policy.buyer.payInvoice(self:buyerView(msg.to), { from = msg.from, order_id = msg.body.order_id, cents = msg.body.cents, pay_to = msg.body.pay_to })
	if ok then
		msg.state = "held" -- waits at the buyer until the payout: still flaggable
	else
		self:emit(msg.to, "message_unhandled", msg.id, { kind = "invoice" })
		self:resolve(th, "fizzled")
	end
end

-- Red posts a card claiming a real seller's name and capability.
function TownSim:spoof(claimed: string?)
	local cfg = self.cfg
	local name = claimed or self.rng:pick(self.sellerNames)
	self.stats.spoofs += 1
	local cheapest = math.huge
	for _, c in self.cards do
		-- at scale, undercut the honest listings only: undercutting red's own
		-- earlier fakes compounds to absurd prices ($1.32 for a widget)
		if not (self.scaled and c.threat) then
			cheapest = math.min(cheapest, c.price)
		end
	end
	if cheapest == math.huge then
		cheapest = 2000
	end
	local price = math.floor(cheapest * cfg.SPOOF_UNDERCUT + 0.5)
	local th = self:newThreat("spoof", { claimed = name })
	if self.layers.registry == "index.owned.v1" then
		self.n.card += 1
		local id = "card-" .. self.n.card
		th.cardId = id
		self:emit("town", "card_publish_refused", name, { capabilities = { "sell.widget" }, publisher = cfg.ATTACKER, reason = "not signed by the listing's key" }, { card = id, price = price, _threat = th.id })
		self:resolve(th, "blocked")
		return th
	end
	local verified = true
	if self.layers.auth == "hmac.v1" then
		-- index.v1 still lists it, but the signature does not match the name
		self:emit("town", "signature_invalid", name, { claimed = name }, { card = "card-" .. (self.n.card + 1), _threat = th.id })
		verified = false
	end
	local card = self:publish(name, cfg.ATTACKER, verified, price, th.id)
	th.cardId = card.id
	return th
end

-- Red opens a fly-by-night stall: a NEW seller, under a name nobody owns, with
-- its own key, listed `undercut` under the going rate. It passes every layer
-- (its signature is good, it owns its name), so nothing but judgment can tell
-- it from an honest newcomer with an opening sale. A buyer who bites pays
-- into escrow and gets an empty crate: an escape.
function TownSim:bait(undercut: number?)
	local cfg = self.cfg
	local names = cfg.BAIT_NAMES or { "widget-hut" }
	self.baitCount += 1
	local base = names[((self.baitCount - 1) % #names) + 1]
	local round = (self.baitCount - 1) // #names
	local name = round == 0 and base or string.format("%s-%d", base, round + 1)
	local u = undercut or self.rng:range(cfg.BAIT_UNDERCUT[1], cfg.BAIT_UNDERCUT[2])
	local price = math.floor(self:marketPrice() * (1 - u) / 5 + 0.5) * 5
	self.stats.baits += 1
	local th = self:newThreat("bait", { claimed = name, undercut = u })
	self.balances[name] = 0
	self.reputation[name] = 0
	self:emit("town", "account_opened", name, { balance_cents = 0 }, { _threat = th.id })
	self:emit("town", "participant_joined", name, { role = "seller" }, { _threat = th.id })
	local card = self:publish(name, name, true, price, th.id)
	th.cardId = card.id
	return th
end

------------------------------------------------------------------------ the watchtower

-- What a flag on `id` (a message id or a card id) would hit.
-- Returns kind ("message" | "card" | nil), the object, and the live threat or nil.
function TownSim:target(id: string)
	local m = self.messages[id]
	if m then
		local th = m.threat and self.threats[m.threat]
		return "message", m, (th and th.state == "live") and th or nil
	end
	local c = self:cardById(id)
	if c then
		local th = c.threat and self.threats[c.threat]
		return "card", c, (th and th.state == "live") and th or nil
	end
	return nil, nil, nil
end

-- A correct flag: the threat is neutralized. Returns true if it was live.
function TownSim:catch(threatId: string): boolean
	local th = self.threats[threatId]
	if not th or not self:resolve(th, "caught") then
		return false
	end
	if th.kind == "forge" then
		local m = self.messages[th.msgId]
		if m and (m.state == "road" or m.state == "held") then
			m.state = "void"
			self:emit("town", "delivery_failed", m.id, { to = m.to, kind = m.kind, reason = "flagged by the watchtower" })
		end
	elseif th.kind == "spoof" or th.kind == "bait" then
		local card = self:cardById(th.cardId)
		if card then
			self:withdraw(card, "flagged by the watchtower")
		end
		for _, d in self.deals do
			if d.threat == th.id and not d.aborted and d.state ~= "settled" then
				self:abandon(d, "seller was an impostor")
			end
		end
	end
	return true
end

-- A wrong flag on an honest envelope or card: it is held FALSE_ALARM_STALL s.
-- Returns true if something was actually held.
function TownSim:hold(id: string): boolean
	local stall = self.cfg.FALSE_ALARM_STALL
	local m = self.messages[id]
	if m and m.state == "road" then
		local left = math.max(0, (m.deliverAt or self.now) - self.now)
		self:emit("town", "message_delayed", id, { to = m.to, kind = m.kind, fault = "false_alarm", delay = stall })
		self:scheduleDelivery(m, left + stall)
		return true
	end
	local c = self:cardById(id)
	if c then
		c.stallUntil = self.now + stall
		return true
	end
	return false
end

function TownSim:liveThreats(): { any }
	local list = {}
	for _, th in self.threats do
		if th.state == "live" then
			table.insert(list, th)
		end
	end
	table.sort(list, function(a, b)
		return a.createdAt < b.createdAt
	end)
	return list
end

-- the ids blue could click right now that belong to a live threat
function TownSim:threatTargets(th): { string }
	local ids = {}
	if th.kind == "forge" then
		local m = self.messages[th.msgId]
		if m and (m.state == "road" or m.state == "held") then
			table.insert(ids, m.id)
		end
	elseif th.kind == "spoof" or th.kind == "bait" then
		if self:cardById(th.cardId) then
			table.insert(ids, th.cardId)
		end
		for _, m in self.messages do
			if m.threat == th.id and m.state == "road" then
				table.insert(ids, m.id)
			end
		end
	end
	table.sort(ids)
	return ids
end

-- honest envelopes on the road (what a false alarm would hit)
function TownSim:honestTargets(): { string }
	local ids = {}
	for _, m in self.messages do
		if m.state == "road" and not m.threat then
			table.insert(ids, m.id)
		end
	end
	table.sort(ids)
	return ids
end

------------------------------------------------------------------------ the council

-- Swap a layer mid-round. Adopting index.owned.v1 re-checks every listing,
-- so impostor cards come down at once.
function TownSim:setLayer(layer: string, value: string)
	self.layers[layer] = value
	if layer == "registry" and value == "index.owned.v1" then
		for i = #self.cards, 1, -1 do
			local c = self.cards[i]
			if c.publisher ~= c.name then
				local th = c.threat and self.threats[c.threat]
				self:withdraw(c, "not signed by the listing's key")
				if th then
					for _, d in self.deals do
						if d.threat == th.id and not d.aborted and d.state ~= "settled" then
							self:abandon(d, "listing withdrawn")
						end
					end
					self:resolve(th, "blocked")
				end
			end
		end
	end
end

------------------------------------------------------------------------ snapshot

-- Events that rebuild the town's current state on a client that joins mid-round.
function TownSim:snapshotEvents(): { any }
	local saved = self.out
	self.out = {}
	local savedN = self.counter.n
	local cfg = self.cfg
	-- money in escrow is shown as opened-with, then held again, so the
	-- client's ledger adds up
	local held = {}
	for _, d in self.deals do
		if d.escrow then
			held[d.buyer] = (held[d.buyer] or 0) + d.escrow
		end
	end
	local function all(list)
		for _, n in list do
			self:emit("town", "account_opened", n, { balance_cents = (self.balances[n] or 0) + (held[n] or 0) })
		end
	end
	all(self.sellerNames)
	all(self.buyerNames)
	all({ cfg.ATTACKER })
	for _, s in self.sellerNames do
		local c = self.pop.crowd[s]
		self:emit("town", "participant_joined", s, { role = "seller", crowd = c and c.k or nil })
	end
	for _, b in self.buyerNames do
		local c = self.pop.crowd[b]
		self:emit("town", "participant_joined", b, { role = "buyer", crowd = c and c.k or nil })
	end
	-- fly-by-night stalls still trading
	for _, th in self.threats do
		if th.kind == "bait" and th.state == "live" then
			self:emit("town", "participant_joined", th.claimed, { role = "seller" })
		end
	end
	self:emit("town", "participant_joined", cfg.ATTACKER, { role = "attacker" })
	for _, c in self.cards do
		local kind = c.verified and "card_registered" or "card_unverified"
		local detail = c.verified and { capabilities = c.capabilities, verified = true } or { capabilities = c.capabilities, publisher = c.publisher }
		self:emit("town", kind, c.name, detail, { card = c.id, price = c.price })
	end
	for _, d in self.deals do
		if d.escrow then
			self:emit("town", "escrow_held", d.order_id, { from = d.buyer, cents = d.escrow })
		end
	end
	for _, s in self.sellerNames do
		if (self.reputation[s] or 0) ~= 0 then
			self:emit("town", "reputation_updated", s, { outcome = "snapshot", delta = 0, score = self.reputation[s] })
		end
	end
	local snap = self.out
	self.out = saved
	self.counter.n = savedN
	for _, e in snap do
		e.snapshot = true
	end
	return snap
end

return TownSim
