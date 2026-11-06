-- Round: the timed 5:00 round, driven by Config.ROUND_PHASES.
--
-- Pure Luau (like MarketSim): the server owns one, steps it with the sim's
-- clock and the sim's running totals, and applies each phase's settings
-- itself. The tests run it headless against a real MarketSim.
--
--   local r = Round.new(Config)
--   r:start(sim.now, sim:getTotals())
--   for _, ph in r:update(sim.now, sim:getTotals(), #sim.watchers) do apply(ph.set) end
--   r:prompt(sim.monitor)          -- the prompt to show now, if any
--   r:scoreboard()                 -- once r.done
--
-- With the game (docs/market-game.md), pass `sim:gameState()` as update's
-- fourth argument: each sample then also records Blue's loadout, friction,
-- trade health, stolen and caught so far, and both scores, and the
-- scoreboard replays them.
--
-- Calls per minute are judgment calls asked of the watchers (the meter's
-- needle), measured here from the running total over a trailing window, so a
-- change of setting (which restarts the meter) does not restart the chart.

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local DefaultConfig = sibling("Config")
local Score = sibling("Score")

local Round = {}
Round.__index = Round

-- the phase table, checked: sorted by start, the first at 0, one scoreboard at the end
function Round.validate(phases): (boolean, string?)
	if type(phases) ~= "table" or #phases == 0 then
		return false, "no phases"
	end
	if phases[1].at ~= 0 then
		return false, "the first phase must start at 0"
	end
	for i, p in phases do
		if type(p.at) ~= "number" or type(p.name) ~= "string" then
			return false, "phase " .. i .. ": needs at and name"
		end
		if i > 1 and p.at <= phases[i - 1].at then
			return false, "phase " .. i .. ": starts must increase"
		end
		if p.scoreboard and i ~= #phases then
			return false, "only the last phase may be the scoreboard"
		end
		if p.prompt and (type(p.prompt.text) ~= "string" or not (p.prompt.team == "blue" or p.prompt.team == "red" or p.prompt.team == "all")) then
			return false, "phase " .. i .. ": a prompt needs text and team blue|red|all"
		end
	end
	if not phases[#phases].scoreboard then
		return false, "the last phase must be the scoreboard"
	end
	return true
end

function Round.new(cfg)
	cfg = cfg or DefaultConfig
	local phases = cfg.ROUND_PHASES
	assert(Round.validate(phases))
	return setmetatable({
		cfg = cfg,
		phases = phases,
		length = phases[#phases].at,
		active = false,
		done = false,
		phase = 0,
		t0 = 0,
		samples = {}, -- { t (s into the round), asked (running total), rate (calls/min), perWatcher }
		nextSample = 0,
		peak = 0,
		peakPerWatcher = 0,
		base = nil,
		last = nil,
		-- live prompts: { id, phase, prompt, visible }; one held back by `when`
		-- turns visible once its condition holds, and stays armed after its phase
		prompts = {},
		answered = {}, -- prompt id -> true
		promptSeq = 0,
	}, Round)
end

-- Start (or restart) at sim time `now`; `totals` = sim:getTotals().
function Round:start(now: number, totals)
	self.active = true
	self.done = false
	self.phase = 0
	self.t0 = now
	self.samples = {}
	self.nextSample = 0
	self.peak = 0
	self.peakPerWatcher = 0
	self.base = table.clone(totals)
	self.last = table.clone(totals)
	self.prompts = {}
	self.answered = {}
	self.score = nil
end

function Round:stop()
	self.active = false
	self.prompts = {}
end

function Round:elapsed(now: number): number
	return math.max(0, now - self.t0)
end

-- calls per minute at the latest sample, over the trailing window (at least
-- 15 s, at most ROUND_RATE_WINDOW, never before the round began)
local function rateAt(self, t: number, asked: number): number
	local window = math.min(self.cfg.ROUND_RATE_WINDOW or 60, math.max(15, t))
	local cut = t - window
	-- the asked total at the cut: the newest sample at or before it (or the start)
	local before = self.base.asked
	for i = #self.samples, 1, -1 do
		local s = self.samples[i]
		if s.t <= cut + 1e-6 then
			before = s.asked
			break
		end
	end
	return (asked - before) * 60 / window
end

-- Advance to `now`. Returns the phases entered on this call (in order), each
-- { index, phase }; the caller applies phase.set. `watchers` = how many
-- watchers share the inbox (for the per-watcher rate).
function Round:update(now: number, totals, watchers: number?, game: any?)
	local entered = {}
	if not self.active then
		return entered
	end
	self.last = table.clone(totals)
	local t = self:elapsed(now)
	-- samples for the chart
	local every = self.cfg.ROUND_SAMPLE_S or 2
	while t + 1e-6 >= self.nextSample and self.nextSample <= self.length + 1e-6 do
		local st = self.nextSample
		local rate = rateAt(self, math.max(st, 0), totals.asked)
		local per = rate / math.max(1, watchers or 1)
		local sample: any = { t = st, asked = totals.asked, rate = rate, perWatcher = per }
		if game then
			local d = self:diff(totals)
			sample.loadout = table.clone(game.loadout or {})
			sample.friction = game.friction
			sample.health = game.health
			sample.stolen = math.floor((d.stolen or 0) + 0.5)
			sample.caught = d.caught or 0
			sample.escaped = d.escaped or 0
			sample.blue = Score.blue(d, self.cfg).score
			sample.red = Score.red(d).score
		end
		table.insert(self.samples, sample)
		self.peak = math.max(self.peak, rate)
		self.peakPerWatcher = math.max(self.peakPerWatcher, per)
		self.nextSample += every
	end
	-- phases
	while self.phase < #self.phases and t + 1e-6 >= self.phases[self.phase + 1].at do
		self.phase += 1
		local ph = self.phases[self.phase]
		table.insert(entered, { index = self.phase, phase = ph })
		-- a new phase clears the last phase's plain questions; conditional ones stay armed
		local keep = {}
		for _, p in self.prompts do
			if p.prompt.when and not self.answered[p.id] then
				table.insert(keep, p)
			end
		end
		self.prompts = keep
		if ph.prompt then
			self.promptSeq += 1
			table.insert(self.prompts, { id = self.promptSeq, phase = self.phase, prompt = ph.prompt, visible = not ph.prompt.when })
		end
		if ph.scoreboard then
			self.score = self:scoreboard()
			self.active = false
			self.done = true
			self.prompts = {}
		end
	end
	return entered
end

-- Money runs out (docs/market-game.md; Config.BLUE_STAKE): Blue's treasury
-- below 0 ends the round with Red the winner, and every Red in `reds` (owner
-- ids) broke, with no stall open, ends it with Blue the winner. Call after
-- update(); returns the ending ({ why, winner, text }) or nil.
function Round:checkMoney(sim, reds: { string })
	if not self.active then
		return nil
	end
	local d = self:diff(sim:getTotals())
	local treasury = (self.cfg.BLUE_STAKE or 0) + Score.blue(d, self.cfg).score
	local ending = nil
	if treasury < 0 then
		ending = { why = "bankrupt", winner = "red", text = "the market went bankrupt" }
	elseif #reds > 0 then
		local broke = true
		for _, owner in reds do
			if not sim:redBroke(owner) then
				broke = false
				break
			end
		end
		if broke then
			ending = { why = "broke", winner = "blue", text = "Red went broke" }
		end
	end
	if ending then
		self:finish(sim.now, sim:getTotals(), ending)
	end
	return ending
end

-- end the round now (money ran out): the scoreboard, as at 5:00
function Round:finish(now: number, totals, ending)
	self.last = table.clone(totals)
	self.score = self:scoreboard()
	self.score.ended = ending
	self.score.endedAt = math.floor(self:elapsed(now) + 0.5)
	self.active = false
	self.done = true
	self.prompts = {}
end

-- The latest calls/min (all watchers) and per watcher.
function Round:rate(): (number, number)
	local s = self.samples[#self.samples]
	if not s then
		return 0, 0
	end
	return s.rate, s.perWatcher
end

-- The prompts to show now (a list, oldest first). `monitor` = the sim's
-- monitor mode: a monitor prompt is moot once one is picked.
function Round:prompt(monitor: string?)
	local out = {}
	if not self.active then
		return out
	end
	for _, p in self.prompts do
		if not self.answered[p.id] then
			if not p.visible and p.prompt.when == "overBudget" then
				local _, per = self:rate()
				if per > (p.prompt.factor or 3) * (self.cfg.BUDGET or 12) then
					p.visible = true
					p.firedAt = self.samples[#self.samples] and self.samples[#self.samples].t or 0
				end
			end
			local moot = p.prompt.ask == "monitor" and monitor ~= nil and monitor ~= "off"
			if p.visible and not moot then
				table.insert(out, { id = p.id, team = p.prompt.team, ask = p.prompt.ask, text = p.prompt.text, phase = p.phase })
			end
		end
	end
	return out
end

-- someone answered prompt `id` (a monitor picked, a vote cast)
function Round:answer(id: number)
	self.answered[id] = true
end

-- totals since the round began
function Round:diff(totals)
	local b = self.base or {}
	local out = {}
	for k, v in totals do
		if type(v) == "number" then
			out[k] = v - (b[k] or 0)
		end
	end
	return out
end

-- What the round did: totals since its start, plus the chart.
function Round:scoreboard()
	local b, l = self.base or {}, self.last or {}
	local function d(k: string): number
		return (l[k] or 0) - (b[k] or 0)
	end
	local diff = self:diff(l)
	local marks = {}
	for _, p in self.phases do
		table.insert(marks, { at = p.at, name = p.name })
	end
	local chart = {}
	-- the game's series: Blue's loadout over time against trade and fraud
	local series = {}
	for _, s in self.samples do
		table.insert(chart, { t = s.t, r = math.floor(s.rate * 10 + 0.5) / 10 })
		if s.friction then
			table.insert(series, {
				t = s.t,
				lo = s.loadout,
				f = s.friction,
				h = s.health,
				st = s.stolen,
				c = s.caught,
				e = s.escaped,
				b = s.blue,
				r = s.red,
			})
		end
	end
	return {
		length = self.length,
		honestDeals = d("honestDeals"),
		honestValue = math.floor(d("honestValue") + 0.5),
		stolen = math.floor(d("stolen") + 0.5),
		stolenSales = d("stolenSales"),
		frauds = d("frauds"),
		caught = d("caught"),
		escaped = d("escaped"),
		falseAlarms = d("falseAlarms"),
		asked = d("asked"),
		decided = d("decided"),
		peak = math.floor(self.peak * 10 + 0.5) / 10,
		peakPerWatcher = math.floor(self.peakPerWatcher * 10 + 0.5) / 10,
		budget = self.cfg.BUDGET,
		chart = chart,
		marks = marks,
		series = series,
		blue = Score.blue(diff, self.cfg),
		red = Score.red(diff),
		refunded = d("refunded"),
		inspected = d("inspected"),
		rejected = d("rejected"),
	}
end

-- Apply one phase's settings to a sim. `hooks.monitor(mode)` and
-- `hooks.watchers(k)` let the server do these its own way (the gateway, the
-- room's players); without hooks the sim's own setters are used, and
-- `watchers` adds or removes a modelled helper.
function Round.apply(sim, set, hooks)
	if not set then
		return
	end
	hooks = hooks or {}
	if set.n and sim.n ~= set.n then
		sim:setSize(set.n)
		sim:mark(set.n .. " traders")
	end
	if set.monitor and sim.monitor ~= set.monitor then
		if hooks.monitor then
			hooks.monitor(set.monitor)
		else
			sim:setMonitor(set.monitor)
			sim:mark("monitor " .. set.monitor)
		end
	end
	if set.signatures ~= nil and sim.signatures ~= set.signatures then
		sim:setSignatures(set.signatures)
		sim:mark(set.signatures and "signatures on" or "signatures off")
	end
	if set.counterfeits ~= nil then
		sim:setCounterfeitShare(set.counterfeits)
	end
	if set.keyword ~= nil then
		sim:setRuleKeyword(set.keyword)
	end
	-- the game's settings
	if set.resetLoadout then
		sim:setLoadout(sim.signatures and { "idCheck" } or {})
	end
	if set.scripted ~= nil then
		sim.fraudsPaused = not set.scripted
	end
	if set.resetUnlocks then
		sim:setUnlocked({})
	end
	if set.unlock ~= nil then
		sim:unlock(set.unlock)
	end
	if set.botRate ~= nil then
		if hooks.botRate then
			hooks.botRate(set.botRate)
		else
			sim:setRedBot(true, set.botRate)
		end
	end
	if set.llmShoppers ~= nil then
		sim:setLlmShoppers(set.llmShoppers)
	end
	if set.watchers then
		if hooks.watchers then
			hooks.watchers(set.watchers)
		elseif set.watchers >= 2 then
			sim:addWatcher("helper", { auto = true, label = "second watcher" })
		else
			sim:removeWatcher("helper")
		end
	end
end

-- What every client needs each half second (small; the chart comes with the scoreboard).
function Round:public(now: number, monitor: string?)
	local ph = self.phases[self.phase]
	local nextPh = self.phases[self.phase + 1]
	local rate, per = self:rate()
	local marks = {}
	for _, p in self.phases do
		table.insert(marks, { at = p.at, name = p.name })
	end
	return {
		active = self.active,
		done = self.done,
		t = self.active and self:elapsed(now) or (self.done and self.length or 0),
		length = self.length,
		phase = self.phase,
		name = ph and ph.name or nil,
		banner = ph and ph.banner or nil,
		nextAt = nextPh and nextPh.at or nil,
		nextName = nextPh and nextPh.name or nil,
		rate = math.floor(rate * 10 + 0.5) / 10,
		perWatcher = math.floor(per * 10 + 0.5) / 10,
		prompts = self:prompt(monitor),
		marks = marks,
		-- both scores so far (since the round began)
		blue = (self.active or self.done) and Score.blue(self:diff(self.last or {}), self.cfg).score or nil,
		red = (self.active or self.done) and Score.red(self:diff(self.last or {})).score or nil,
		blueStake = self.cfg.BLUE_STAKE, -- (the treasury is this plus Blue's profit)
		ended = self.score and self.score.ended or nil,
	}
end

return Round
