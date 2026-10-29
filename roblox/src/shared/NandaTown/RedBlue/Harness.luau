-- Harness: the game's side of the conversation with the external LLM harness
-- (harness/, a small Python service; see roblox/README.md).
--
-- Pure Luau: it builds the request, decides when one is allowed, and takes
-- the answer apart. The actual HTTPS call is three lines in RedBlueServer,
-- in a coroutine of its own, so no decision and no frame ever waits for it.
--
--   local h = Harness.new({ config = Config, store = llmPolicy })
--   h:note(events)                      -- every tick: the town's own events
--   if h:due() and h:begin() then
--       local body = h:observation(game)         -- a plain table, JSON on the wire
--       ... HttpService:RequestAsync ...
--       h:finish(decodedResponse)                -- or h:fail("timeout")
--   end
--
-- Three things keep it inside Roblox's budget of 500 external requests per
-- server per minute: one request carries every agent (LLM_POLL_SECONDS = 2.5 s,
-- so 24/min however many agents are model-driven), only one request is ever in
-- flight, and a sliding-window ceiling (LLM_MAX_PER_MINUTE) refuses the rest
-- whatever else goes wrong. A failed request backs off, doubling.
--
-- Nothing a player types can reach the model: the observation is built here
-- out of Config's agent names and the simulation's numbers, and the ticker
-- renders a closed list of event kinds. Player display names live only on
-- game-layer events (threat_caught, false_alarm, …), which are not in it.

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local LlmPolicy = sibling("LlmPolicy")

local Harness = {}
Harness.__index = Harness

-- what the scripted policies do, as a stance, so the model sees where it starts
Harness.SCRIPTED = {
	seller = { quote_pct = 100, floor_pct = 90 },
	buyer = { offer_pct = 80, accept_pct = 100 },
}

-- opts = { config, store (LlmPolicy), clock? () -> seconds }
function Harness.new(opts)
	local cfg = opts.config
	return setmetatable({
		cfg = cfg,
		store = opts.store,
		clock = opts.clock or os.clock,
		url = cfg.LLM_URL .. cfg.LLM_PATH,
		ticker = {},
		window = {}, -- timestamps of recent requests (the per-minute ceiling)
		inflight = false,
		nextAt = 0,
		backoff = 0,
		stats = { requests = 0, ok = 0, errors = 0, actions = 0, rejected = 0, refused = 0 },
		serverId = opts.server or "local", -- which Roblox server this is (JobId)
		tokenSource = opts.tokenSource or "none", -- where the shared secret came from
		lastError = nil :: string?,
		lastOkAt = nil :: number?,
		lastRoundTrip = nil :: number?,
		health = "idle", -- idle | ok | error
	}, Harness)
end

------------------------------------------------------------------------ ticker

local function known(self, name: any): string?
	if type(name) ~= "string" then
		return nil
	end
	local cfg = self.cfg
	if name == cfg.ATTACKER or table.find(cfg.SELLERS, name) or table.find(cfg.BUYERS, name) then
		return name
	end
	return nil
end

local ABANDON = {
	price = "over its price",
	["seller was an impostor"] = "the seller was an impostor",
	["listing withdrawn"] = "the listing came down",
	["the seller vanished"] = "the seller vanished",
}

-- One line of context for the model, or nil. Only these kinds, only names the
-- town knows, only numbers: a closed list, so nothing else can slip through.
function Harness:render(e): string?
	local d = e.detail or {}
	local k = e.kind
	if k == "payment_settled" then
		local from, to = known(self, d.from), known(self, d.to)
		if from and to then
			return string.format("%s paid %s %dc%s", from, to, d.cents or 0, d.via == "invoice" and " on an invoice" or "")
		end
	elseif k == "negotiation_abandoned" then
		local buyer, seller = known(self, e.observer), known(self, d.seller)
		if buyer and seller then
			return string.format("%s walked away from %s (%s)", buyer, seller, ABANDON[d.reason] or "no deal")
		end
	elseif k == "card_registered" or k == "card_unverified" then
		local name = known(self, e.subject)
		if name then
			return string.format("a%s card for %s was pinned at %dc", k == "card_unverified" and "n UNVERIFIED" or "", name, e.price or 0)
		end
	elseif k == "card_withdrawn" then
		local name = known(self, e.subject)
		if name then
			return string.format("the card for %s came down", name)
		end
	elseif k == "card_publish_refused" then
		local name = known(self, e.subject)
		if name then
			return string.format("the board refused a card claiming to be %s", name)
		end
	elseif k == "signature_invalid" then
		return "the guards stopped a forged signature at the gate"
	elseif k == "reputation_updated" then
		local name = known(self, e.subject)
		if name and d.score then
			return string.format("%s's reputation is now %d", name, d.score)
		end
	elseif k == "layer_swapped" then
		local opts = self.cfg.LAYER_OPTIONS[e.subject]
		if opts and table.find(opts, d.to) then
			return string.format("the council switched %s to %s", e.subject, d.to)
		end
	end
	return nil
end

-- Keep the last LLM_TICKER renderable lines of the town's own events.
function Harness:note(events)
	for _, e in events do
		local line = self:render(e)
		if line then
			table.insert(self.ticker, line)
		end
	end
	while #self.ticker > self.cfg.LLM_TICKER do
		table.remove(self.ticker, 1)
	end
end

------------------------------------------------------------------- observation

local function stance(self, name: string, role: string)
	local d = self.store:fresh(name)
	local s = {}
	for field, v in Harness.SCRIPTED[role] do
		s[field] = d and d[field] or v
	end
	return s
end

-- The market as a model-driven agent may see it: public listings, its own
-- books, the town's laws. One table, one request, every agent.
function Harness:observation(game)
	local cfg, sim = self.cfg, game.sim
	local obs = {
		round = game.round,
		t = math.floor(math.max(0, game:rt()) * 10 + 0.5) / 10,
		round_seconds = cfg.ROUND_SECONDS,
		deals = sim and sim.stats.dealsSettled or 0,
		auth = game.layers.auth,
		registry = game.layers.registry,
		ticker = table.clone(self.ticker),
		agents = {},
	}
	if not sim then
		return obs
	end
	-- the notice board, as anyone in the square can read it
	local listings = {}
	for _, c in sim.cards do
		table.insert(listings, { name = c.name, cents = c.price, reputation = sim.reputation[c.name] or 0, unverified = not c.verified or nil })
	end
	for _, name in self.store:agents() do
		local role = cfg.LLM_AGENT_ROLE[name]
		local deals, abandoned = 0, 0
		for _, d in sim.deals do
			local mine = (role == "seller" and d.seller == name and d.endpoint == name) or (role == "buyer" and d.buyer == name)
			if mine then
				if d.state == "settled" then
					deals += 1
				elseif d.aborted then
					abandoned += 1
				end
			end
		end
		local a = {
			name = name,
			role = role,
			deals = deals,
			abandoned = abandoned,
			reputation = sim.reputation[name] or 0,
			rivals = {},
		}
		for _, l in listings do
			if l.name ~= name or role == "buyer" then
				table.insert(a.rivals, l)
			end
		end
		for field, v in stance(self, name, role) do
			a[field] = v
		end
		if role == "seller" then
			a.list_cents = cfg.LIST_PRICE[name] or 2000
		else
			a.balance_cents = sim.balances[name] or 0
			a.favourite = cfg.BUYER_FAVORITE and cfg.BUYER_FAVORITE[name] or nil
		end
		table.insert(obs.agents, a)
	end
	return obs
end

--------------------------------------------------------------------- the clock

-- Is a request allowed right now? (Someone model-driven, nothing in flight,
-- the interval and any backoff elapsed, and room under the per-minute ceiling.)
function Harness:due(): boolean
	if self.inflight or not self.store:any() then
		return false
	end
	local now = self.clock()
	if now < self.nextAt then
		return false
	end
	return self:budget() > 0
end

-- How many more requests this minute would be allowed.
function Harness:budget(): number
	local now = self.clock()
	while #self.window > 0 and now - self.window[1] >= 60 do
		table.remove(self.window, 1)
	end
	return self.cfg.LLM_MAX_PER_MINUTE - #self.window
end

-- Take a slot. Returns false if the ceiling says no (and counts the refusal).
function Harness:begin(): boolean
	if self.inflight then
		return false
	end
	if self:budget() <= 0 then
		self.stats.refused += 1
		self.nextAt = self.clock() + 1
		return false
	end
	local now = self.clock()
	table.insert(self.window, now)
	self.inflight = true
	self.startedAt = now
	self.stats.requests += 1
	self.nextAt = now + self.cfg.LLM_POLL_SECONDS
	return true
end

-- The harness answered. Returns how many actions were taken.
function Harness:finish(response: any): number
	self.inflight = false
	local now = self.clock()
	self.lastRoundTrip = self.startedAt and (now - self.startedAt) or nil
	self.backoff = 0
	self.nextAt = now + self.cfg.LLM_POLL_SECONDS
	self.lastOkAt = now
	self.stats.ok += 1
	self.health = "ok"
	self.llm = type(response) == "table" and type(response.llm) == "string" and string.sub(response.llm, 1, 16) or nil
	local n = 0
	if type(response) == "table" and type(response.actions) == "table" then
		for _, action in response.actions do
			local ok = self.store:apply(action)
			if ok then
				n += 1
				self.stats.actions += 1
			else
				self.stats.rejected += 1
			end
		end
	end
	return n
end

-- The request failed (no harness, a timeout, nonsense back). The agents keep
-- their stance until it expires, then they are scripted again.
function Harness:fail(err: string?)
	self.inflight = false
	self.stats.errors += 1
	self.lastError = type(err) == "string" and string.sub(err, 1, 120) or "error"
	self.health = "error"
	local lo, hi = self.cfg.LLM_BACKOFF[1], self.cfg.LLM_BACKOFF[2]
	self.backoff = math.clamp(self.backoff == 0 and lo or self.backoff * 2, lo, hi)
	self.nextAt = self.clock() + self.backoff
end

-- What the HUD shows about the harness itself.
function Harness:status()
	local now = self.clock()
	return {
		url = self.url,
		token = self.tokenSource, -- "secrets_store" | "place" | "none"; never the secret
		health = self.health,
		llm = self.llm, -- "ready" | "no_key", as the harness reports it
		requests = self.stats.requests,
		ok = self.stats.ok,
		errors = self.stats.errors,
		actions = self.stats.actions,
		rejected = self.stats.rejected,
		refused = self.stats.refused,
		backoff = self.backoff,
		budget = self:budget(),
		since = self.lastOkAt and math.floor((now - self.lastOkAt) * 10 + 0.5) / 10 or nil,
		roundTrip = self.lastRoundTrip and math.floor(self.lastRoundTrip * 1000 + 0.5) or nil,
		error = self.lastError,
		agents = self.store:report(),
	}
end

Harness.LlmPolicy = LlmPolicy

return Harness
