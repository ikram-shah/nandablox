-- LlmPolicy: the model-driven side of Policy.luau.
--
-- TownSim asks a policy for a decision and uses the answer at once (quote,
-- counter, offer, accept). A language model takes about a second, sometimes
-- twelve, so it can never sit in that call. Instead the harness
-- (harness/, polled by RedBlueServer over HttpService) keeps each
-- model-driven agent's **stance** up to date, and the stance is applied
-- synchronously, exactly like the scripted policy:
--
--   seller   quote_pct   the price it quotes, as a percent of its list price
--            floor_pct   the lowest percent of list it will take when haggling
--   buyer    offer_pct   its opening offer, as a percent of the seller's quote
--            accept_pct  the most it will pay, as a percent of that quote
--
-- plus one `reason` code out of a closed list. The model writes no text: the
-- sentences below are the game's, keyed by the code, which is why nothing
-- here needs TextService:FilterStringAsync. Numbers out of range are clamped
-- and an unknown code becomes "steady", so a confused (or hostile) harness
-- can only move prices inside a band the game chose.
--
-- Everything falls back: with no directive, one older than LLM_TTL seconds,
-- or an agent that is not model-driven right now, every call lands on
-- Policy.ScriptedBuyer / Policy.ScriptedSeller. The default is scripted, so
-- the published place is unchanged for anyone who joins.
--
--   local store = LlmPolicy.new({ config = Config })
--   store:setAgents({ "seller-b" })         -- who the model drives now
--   local game = Game.new({ config = Config, policies = store:policies() })
--   store:apply({ agent = "seller-b", kind = "seller_pricing",
--                 quote_pct = 92, floor_pct = 86, reason = "undercut_rival" })
--
-- No Roblox services: Lune runs it headless (tests/test_llm.luau).

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local Policy = sibling("Policy")

local LlmPolicy = {}
LlmPolicy.__index = LlmPolicy

-- The whole vocabulary a model may answer in. harness/nanda_harness/schema.py
-- holds the same list, and a test there checks the two against each other.
LlmPolicy.KINDS = { seller_pricing = "seller", buyer_bargaining = "buyer" }
LlmPolicy.RANGES = {
	seller = { quote_pct = { 70, 130 }, floor_pct = { 60, 120 } },
	buyer = { offer_pct = { 50, 100 }, accept_pct = { 60, 120 } },
}
-- The game's words for the model's reason code: the model never writes text.
LlmPolicy.REASONS = {
	seller = {
		undercut_rival = "undercutting the rival listing",
		hold_price = "holding its price",
		rebuild_trust = "rebuilding trust after a bad receipt",
		buyers_walking = "buyers were walking away",
		slow_lane = "deals are slow under these laws",
		impostor_nearby = "an impostor is trading under its name",
		steady = "staying the course",
	},
	buyer = {
		lowball = "lowballing the sellers",
		close_fast = "closing deals quickly",
		trust_favourite = "sticking with its usual seller",
		avoid_impostor = "avoiding a listing it does not trust",
		budget_tight = "watching its purse",
		steady = "staying the course",
	},
}

local function round(x: number): number
	return math.floor(x + 0.5)
end

local function clamp(v: any, lo: number, hi: number): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return math.clamp(round(v), lo, hi)
end

-- The only string from the harness that reaches a screen is the model's name,
-- which is the operator's own configuration, not model output. It is still
-- cut down to something that cannot be a sentence.
local function safeModel(v: any): string?
	if type(v) ~= "string" then
		return nil
	end
	local first = string.match(v, "^%s*([^%s]+)") -- one token, never a sentence
	if not first then
		return nil
	end
	local s = string.gsub(string.sub(first, 1, 32), "[^%w%.%-_]", "")
	return s ~= "" and s or nil
end

-- opts = { config, clock? () -> seconds }
function LlmPolicy.new(opts)
	local cfg = opts.config
	return setmetatable({
		cfg = cfg,
		clock = opts.clock or os.clock,
		ttl = cfg.LLM_TTL,
		roles = {}, -- agent name -> "seller" | "buyer" (model-driven right now)
		directives = {}, -- agent name -> directive
		quotes = {}, -- buyer name -> the quote it is haggling over
		used = {}, -- agent name -> decisions actually taken from the model
		fell_back = 0, -- decisions that wanted a directive and found none
	}, LlmPolicy)
end

------------------------------------------------------------------------ who

-- Which agents the model drives now. Names not in Config.LLM_AGENT_ROLE are
-- ignored; an agent that is dropped loses its directive at once.
function LlmPolicy:setAgents(names: { string }?)
	local roles = {}
	for _, n in names or {} do
		local role = self.cfg.LLM_AGENT_ROLE[n]
		if role then
			roles[n] = role
		end
	end
	for n in self.directives do
		if not roles[n] then
			self.directives[n] = nil
		end
	end
	self.roles = roles
	return self:agents()
end

function LlmPolicy:agents(): { string }
	local list = {}
	for n in self.roles do
		table.insert(list, n)
	end
	table.sort(list)
	return list
end

function LlmPolicy:isDriven(name: string?): string?
	return name and self.roles[name] or nil
end

function LlmPolicy:any(): boolean
	return next(self.roles) ~= nil
end

------------------------------------------------------------------- directives

-- Take one action from the harness. Returns ok, why
-- ("ok" | "not_a_table" | "unknown_agent" | "wrong_kind" | "bad_numbers").
function LlmPolicy:apply(action: any): (boolean, string)
	if type(action) ~= "table" then
		return false, "not_a_table"
	end
	local name = action.agent
	local role = self:isDriven(type(name) == "string" and name or nil)
	if not role then
		return false, "unknown_agent"
	end
	if LlmPolicy.KINDS[action.kind] ~= role then
		return false, "wrong_kind"
	end
	local d = { role = role, at = self.clock() }
	for field, range in LlmPolicy.RANGES[role] do
		local v = clamp(action[field], range[1], range[2])
		if not v then
			return false, "bad_numbers"
		end
		d[field] = v
	end
	if role == "seller" and d.floor_pct > d.quote_pct then
		d.floor_pct = d.quote_pct
	end
	if role == "buyer" and d.accept_pct < d.offer_pct then
		d.accept_pct = d.offer_pct
	end
	d.reason = LlmPolicy.REASONS[role][action.reason] and action.reason or "steady"
	d.model = safeModel(action.model)
	d.seq = type(action.seq) == "number" and action.seq or nil
	d.latency = type(action.latency_ms) == "number" and round(action.latency_ms) or nil
	d.age = type(action.age_ms) == "number" and round(action.age_ms) or nil
	self.directives[name] = d
	return true, "ok"
end

-- The directive in force for this agent, or nil (so: the scripted policy).
function LlmPolicy:fresh(name: string?)
	local d = name and self.directives[name]
	if not d then
		return nil
	end
	if self.clock() - d.at > self.ttl then
		return nil
	end
	return d
end

function LlmPolicy:forget(name: string?)
	if name then
		self.directives[name] = nil
	else
		table.clear(self.directives)
	end
end

-- One line the HUD can show, written here, from the code the model picked.
function LlmPolicy:line(name: string): string?
	local role = self:isDriven(name)
	if not role then
		return nil
	end
	local d = self:fresh(name)
	if not d then
		return string.format("%s · waiting for the harness · scripted meanwhile", name)
	end
	local why = LlmPolicy.REASONS[role][d.reason] or LlmPolicy.REASONS[role].steady
	if role == "seller" then
		return string.format("%s quotes %d%% of list, floor %d%% — %s", name, d.quote_pct, d.floor_pct, why)
	end
	return string.format("%s opens at %d%% of the quote, pays up to %d%% — %s", name, d.offer_pct, d.accept_pct, why)
end

-- What the HUD and the nameplate need, per model-driven agent.
function LlmPolicy:report(): { any }
	local out = {}
	for _, name in self:agents() do
		local d = self:fresh(name)
		table.insert(out, {
			name = name,
			role = self.roles[name],
			line = self:line(name),
			model = d and d.model or nil,
			source = d and "llm" or "scripted",
			reason = d and d.reason or nil,
			latency = d and d.latency or nil,
			seq = d and d.seq or nil,
			decisions = self.used[name] or 0,
		})
	end
	return out
end

------------------------------------------------------------------- the policy

local function take(self, name: string)
	self.used[name] = (self.used[name] or 0) + 1
end

-- The policy table to hand Game.new / TownSim.new. With no model-driven
-- agent it is Policy.Scripted* exactly: the same decisions, event for event.
function LlmPolicy:policies(base: any?)
	local scriptedBuyer = (base and base.buyer) or Policy.ScriptedBuyer
	local scriptedSeller = (base and base.seller) or Policy.ScriptedSeller
	local self_ = self
	return {
		impostor = (base and base.impostor) or Policy.Impostor,
		seller = {
			quote = function(view, request)
				local d = self_:isDriven(view.name) and self_:fresh(view.name)
				if not d then
					if self_:isDriven(view.name) then
						self_.fell_back += 1
					end
					return scriptedSeller.quote(view, request)
				end
				take(self_, view.name)
				return round(view.listPrice * d.quote_pct / 100)
			end,
			counter = function(view, offerCents)
				local d = self_:isDriven(view.name) and self_:fresh(view.name)
				if not d then
					if self_:isDriven(view.name) then
						self_.fell_back += 1
					end
					return scriptedSeller.counter(view, offerCents)
				end
				take(self_, view.name)
				-- never below the buyer's own offer, as the scripted seller does
				return math.max(offerCents, round(view.listPrice * d.floor_pct / 100))
			end,
		},
		buyer = {
			-- which listing to buy from, and whether to pay an invoice that
			-- arrived, stay scripted: those are the attack surface red plays
			-- against, and a model must not quietly change the game's rules.
			chooseCard = function(view, cards)
				return scriptedBuyer.chooseCard(view, cards)
			end,
			payInvoice = function(view, invoice)
				return scriptedBuyer.payInvoice(view, invoice)
			end,
			offer = function(view, quoteCents)
				self_.quotes[view.name] = quoteCents
				local d = self_:isDriven(view.name) and self_:fresh(view.name)
				if not d then
					if self_:isDriven(view.name) then
						self_.fell_back += 1
					end
					return scriptedBuyer.offer(view, quoteCents)
				end
				take(self_, view.name)
				return round(quoteCents * d.offer_pct / 100)
			end,
			accept = function(view, counterCents)
				local d = self_:isDriven(view.name) and self_:fresh(view.name)
				-- the purse is the game's rule, not the model's: a buyer can
				-- never accept what it cannot pay for
				if not scriptedBuyer.accept(view, counterCents) then
					return false
				end
				if not d then
					if self_:isDriven(view.name) then
						self_.fell_back += 1
					end
					return true
				end
				take(self_, view.name)
				local quote = self_.quotes[view.name]
				if not quote then
					return true
				end
				return counterCents <= round(quote * d.accept_pct / 100)
			end,
		},
	}
end

return LlmPolicy
