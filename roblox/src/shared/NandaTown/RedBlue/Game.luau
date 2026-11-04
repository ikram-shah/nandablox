-- Red vs. Blue: the rules around a running TownSim. Rounds, teams, red's
-- attack tokens, blue's flags, scoring, the council and the bots. Pure: the
-- server passes in time (seconds since the game started) and player ids, and
-- forwards the events this returns to every client. Lune runs it headless.
--
--   local g = Game.new({ config = Config, seed = 1 })
--   g:join(id, "Peter"); g:setTeam(id, "blue")
--   g:start(0)
--   local events = g:tick(t)          -- every ~0.1 s
--   g:attack(id, "forge" | "spoof", claimedSeller?)
--   g:flag(id, targetId, { camera = "tower" })
--   g:vote(id, "auth" | "registry")   -- toggles this player's yes vote
--
-- Game events (rendered like town events; layer "game"):
--   round_started   subject round-N   {round, seconds, layers, tokens}
--   round_finished  subject round-N   {red, blue, deals, escapes, catches, false_alarms, blocked, winner}
--   threat_caught   subject threat-N  {attack, by, target, points, after}
--   threat_escaped  subject threat-N  {attack, cents, points, after}
--   false_alarm     subject target id {by, points, stall}
--   layer_swapped   subject layer     {from, to, yes, present}

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local TownSim = sibling("TownSim")
local Council = sibling("Council")
local Telemetry = sibling("Telemetry")
local Bots = sibling("Bots")
local Oversight = sibling("Oversight")
local Scale = sibling("Scale")

local Game = {}
Game.__index = Game

Game.TEAMS = { red = true, blue = true }
Game.FLAG_COOLDOWN = 0.5

-- opts = { config, seed?, layers?, sink? (telemetry record callback), policies? }
function Game.new(opts)
	local cfg = opts.config
	local layers = {}
	for k, v in opts.layers or cfg.DEFAULT_LAYERS do
		layers[k] = v
	end
	local self = setmetatable({
		cfg = cfg,
		seed = opts.seed or 1,
		policies = opts.policies,
		layers = layers,
		counter = { n = 0 },
		out = {},
		phase = "idle",
		round = 0,
		t = 0,
		roundStart = 0,
		phaseEnds = 0,
		players = {}, -- id -> { name, team, camera, lastFlag }
		council = Council.new({ auth = true, registry = true }),
		telemetry = Telemetry.new(opts.sink),
		redBot = Bots.RedBot.new(cfg, (opts.seed or 1) * 31 + 7),
		blueBot = Bots.BlueBot.new(cfg, (opts.seed or 1) * 37 + 11),
		owners = {}, -- threat id -> attacker id
		wins = { red = 0, blue = 0 },
		lastTick = 0,
		lastAttack = -math.huge,
		-- the oversight demo (DEMO.md): off until someone asks for it
		demo = false,
		size = #cfg.SELLERS + #cfg.BUYERS,
		monitors = false,
		beat = 0,
		oversight = nil,
	}, Game)
	self:resetScores()
	return self
end

function Game:resetScores()
	self.score = { red = 0, blue = 0 }
	self.tally = { escapes = 0, catches = 0, false_alarms = 0, blocked = 0, fizzled = 0 }
	self.tokens = self.cfg.TOKENS_PER_ROUND
	self.humanAttacks = 0
end

------------------------------------------------------------------------ events

function Game:rt(): number
	return self.t - self.roundStart
end

function Game:pull()
	if self.sim then
		local ov = self.oversight
		for _, e in self.sim:drain() do
			table.insert(self.out, e)
			if ov then
				ov:observe(e, self:rt())
			end
		end
	end
end

function Game:emit(observer: string, kind: string, subject: string, detail: { [string]: any }?)
	self:pull()
	self.counter.n += 1
	local n = self.counter.n
	local e = {
		seq = n,
		id = "ev-" .. n,
		event_id = "ev-" .. n,
		at = math.floor(math.max(0, self:rt()) * 100 + 0.5) / 100,
		observer = observer,
		kind = kind,
		subject = subject,
		layer = "game",
		detail = detail or {},
	}
	table.insert(self.out, e)
	return e
end

function Game:drain(): { any }
	self:pull()
	local o = self.out
	self.out = {}
	return o
end

-- An event as clients may see it: private keys (leading "_") removed.
function Game.public(e)
	local c = {}
	for k, v in e do
		if type(k) ~= "string" or string.sub(k, 1, 1) ~= "_" then
			c[k] = v
		end
	end
	return c
end

------------------------------------------------------------------------ players

function Game:join(id: any, name: string?)
	if not self.players[id] then
		self.players[id] = { name = name or tostring(id), team = nil, camera = "walk", lastFlag = -math.huge }
	end
end

function Game:leave(id: any)
	self.players[id] = nil
	self.council:remove(id)
	self:checkCouncil()
end

function Game:setTeam(id: any, team: string?)
	local p = self.players[id]
	if p and (team == nil or Game.TEAMS[team]) then
		local firstRed = team == "red" and p.team ~= "red" and self:humans().red == 0
		p.team = team
		if firstRed then
			-- RedBot's attacks were its own: the first human on red gets the
			-- tokens humans have not spent this round
			self.tokens = self.cfg.TOKENS_PER_ROUND - self.humanAttacks
		end
	end
end

function Game:teamOf(id: any): string?
	if id == Bots.RED_ID then
		return "red"
	elseif id == Bots.BLUE_ID or id == Bots.MONITOR_ID then
		return "blue"
	end
	local p = self.players[id]
	return p and p.team or nil
end

function Game:nameOf(id: any): string
	if id == Bots.RED_ID then
		return "RedBot"
	elseif id == Bots.BLUE_ID then
		return "BlueBot"
	elseif id == Bots.MONITOR_ID then
		return "Monitors"
	end
	local p = self.players[id]
	return p and p.name or tostring(id)
end

function Game:humans(): { red: number, blue: number, present: number }
	local h = { red = 0, blue = 0, present = 0 }
	for _, p in self.players do
		h.present += 1
		if p.team == "red" then
			h.red += 1
		elseif p.team == "blue" then
			h.blue += 1
		end
	end
	return h
end

function Game:botOn(which: string): boolean
	local mode = which == "red" and self.cfg.RED_BOT or self.cfg.BLUE_BOT
	if mode == "on" then
		return true
	elseif mode == "off" then
		return false
	end
	return self:humans()[which] == 0
end

function Game:setCamera(id: any, mode: string)
	local p = self.players[id]
	if p and p.camera ~= mode then
		p.camera = mode
		self.telemetry:record(self.t, "camera", { player = self:nameOf(id), team = p.team, mode = mode })
	end
end

function Game:watchers(): { [string]: string }
	local w = {}
	for _, p in self.players do
		if p.team == "blue" then
			w[p.name] = p.camera
		end
	end
	return w
end

------------------------------------------------------------------------ rounds

function Game:start(t: number)
	self.t = t
	self.lastTick = t
	self:startRound()
end

function Game:startRound()
	self.round += 1
	self.phase = "play"
	self.roundStart = self.t
	self.phaseEnds = self.t + self:roundSeconds()
	self.lastAttack = -math.huge
	if self.cfg.RESET_LAYERS_EACH_ROUND then
		for k, v in self.cfg.DEFAULT_LAYERS do
			self.layers[k] = v
		end
	end
	self:resetScores()
	self.redBot:reset()
	self.blueBot:reset()
	self.sim = nil
	self:emit("town", "round_started", "round-" .. self.round, {
		round = self.round,
		seconds = self:roundSeconds(),
		layers = { auth = self.layers.auth, registry = self.layers.registry, transport = self.layers.transport },
		tokens = self.tokens,
		size = self.demo and self.size or nil,
	})
	self.oversight = nil
	if self.demo then
		self.oversight = Oversight.new({ config = self.cfg, seed = self.seed * 1000 + self.round + 17, layers = self.layers, monitors = self.monitors })
		self.oversight:mark(0, self:settingLabel())
	end
	self.sim = TownSim.new({
		config = self.cfg,
		layers = self.layers,
		seed = self.seed * 1000 + self.round,
		counter = self.counter,
		policies = self.policies,
		size = self.demo and self.size or nil,
	})
	self.sim:start()
	self.telemetry:record(self.t, "round_started", { round = self.round, layers = { auth = self.layers.auth, registry = self.layers.registry } })
	self:pull()
end

-- Red takes the round only by getting something through and outscoring blue:
-- a round where every attack was stopped is blue's (the town held), even if
-- blue's false alarms left it below zero.
function Game:winner(): string
	return (self.tally.escapes > 0 and self.score.red > self.score.blue) and "red" or "blue"
end

function Game:finishRound()
	self:settle()
	local w = self:winner()
	self.wins[w] += 1
	local deals = self.sim and self.sim.stats.dealsSettled or 0
	self.lastDeals = deals
	self:emit("town", "round_finished", "round-" .. self.round, {
		round = self.round,
		red = self.score.red,
		blue = self.score.blue,
		deals = deals,
		escapes = self.tally.escapes,
		catches = self.tally.catches,
		false_alarms = self.tally.false_alarms,
		blocked = self.tally.blocked,
		winner = w,
		layers = { auth = self.layers.auth, registry = self.layers.registry },
	})
	self.telemetry:record(self.t, "round_summary", {
		round = self.round,
		red = self.score.red,
		blue = self.score.blue,
		deals = deals,
		escapes = self.tally.escapes,
		catches = self.tally.catches,
		false_alarms = self.tally.false_alarms,
		blocked = self.tally.blocked,
		winner = w,
		layers = { auth = self.layers.auth, registry = self.layers.registry },
	})
	self.phase = "results"
	self.phaseEnds = self.t + self.cfg.INTERMISSION_SECONDS
	self.sim = nil
end

-- Score the threats the town resolved (escapes, blocks); catches are scored
-- in flag(), where the catcher is known.
function Game:settle()
	if not self.sim then
		return
	end
	for _, th in self.sim:drainResolved() do
		if self.oversight then
			self.oversight:resolved(th, self:rt())
		end
		local after = math.floor((th.resolvedAt - th.createdAt) * 10 + 0.5) / 10
		if th.state == "escaped" then
			self.score.red += self.cfg.ESCAPE_POINTS
			self.tally.escapes += 1
			self:emit(self.cfg.ATTACKER, "threat_escaped", th.id, { attack = th.kind, cents = th.cents, points = self.cfg.ESCAPE_POINTS, after = after, claimed = th.claimed })
		elseif th.state == "blocked" then
			self.tally.blocked += 1
		elseif th.state == "fizzled" then
			self.tally.fizzled += 1
		end
		self.telemetry:record(self.t, "threat_resolved", {
			threat = th.id,
			attack = th.kind,
			outcome = th.state,
			after = after,
			watchers = self:watchers(),
		})
	end
end

function Game:tick(t: number): { any }
	local dt = math.max(0, t - self.lastTick)
	self.lastTick = t
	self.t = t
	if self.phase == "play" then
		local rt = self:rt()
		if self.demo then
			-- the oversight demo: red at the town's scale; blue's bot is the
			-- attention-budgeted human in Oversight, not BlueBot's dice
			if self:botOn("red") then
				self.redBot:scaledTick(self, rt, Scale.factor(self.cfg, self.size))
			end
		else
			if self:botOn("red") then
				self.redBot:tick(self, rt)
			end
			if self:botOn("blue") then
				self.blueBot:tick(self, rt, dt)
			end
		end
		if self.sim then
			self.sim:advance(math.min(rt, self:roundSeconds()))
		end
		self:pull()
		self:settle()
		if self.oversight and self.sim then
			self:tickOversight(rt)
		end
		if t >= self.phaseEnds then
			self:finishRound()
		end
	elseif self.phase == "results" and t >= self.phaseEnds then
		self:startRound()
	end
	return self:drain()
end

------------------------------------------------------------------------ red

-- Returns ok, reason ("ok" | "not_playing" | "not_red" | "no_tokens" |
-- "cooldown" | "bad_attack"), and the threat.
function Game:attack(id: any, kind: string, claimed: string?): (boolean, string, any)
	if self.phase ~= "play" or not self.sim then
		return false, "not_playing", nil
	end
	if self:teamOf(id) ~= "red" then
		return false, "not_red", nil
	end
	if kind ~= "forge" and kind ~= "spoof" and not (kind == "bait" and self.demo) then
		return false, "bad_attack", nil
	end
	-- at scale, RedBot attacks at the town's rate and spends no tokens
	local scaledBot = self.demo and id == Bots.RED_ID
	if self.tokens <= 0 and not scaledBot then
		return false, "no_tokens", nil
	end
	if self.t - self.lastAttack < self.cfg.ATTACK_COOLDOWN and not scaledBot then
		return false, "cooldown", nil
	end
	if claimed and not table.find(self.sim.sellerNames, claimed) then
		claimed = nil
	end
	if not scaledBot then
		self.tokens -= 1
	end
	if id ~= Bots.RED_ID then
		self.humanAttacks += 1
	end
	self.lastAttack = self.t
	self.sim:advance(self:rt()) -- bring the town up to now first
	self:pull()
	local th
	if kind == "forge" then
		th = self.sim:forge(claimed)
	elseif kind == "bait" then
		th = self.sim:bait()
	else
		th = self.sim:spoof(claimed)
	end
	self.owners[th.id] = id
	if self.oversight then
		self.oversight:threatAppeared(th, self:rt())
	end
	self.telemetry:record(self.t, "threat_appeared", {
		threat = th.id,
		attack = kind,
		by = self:nameOf(id),
		claimed = th.claimed,
		layers = { auth = self.layers.auth, registry = self.layers.registry },
		outcome = th.state, -- "blocked" when a layer stopped it at once
	})
	self:settle()
	self:pull()
	return true, "ok", th
end

------------------------------------------------------------------------ blue

-- Returns "catch" | "false_alarm" | "stale" | "miss" | "not_blue" |
-- "not_playing" | "cooldown".
function Game:flag(id: any, target: string?, ctx: { [string]: any }?): string
	local camera = ctx and ctx.camera or (self.players[id] and self.players[id].camera) or "?"
	local team = self:teamOf(id)
	local function click(result: string, extra: { [string]: any }?)
		local r = { player = self:nameOf(id), team = team, target = target, result = result, camera = camera }
		for k, v in extra or {} do
			r[k] = v
		end
		self.telemetry:record(self.t, "flag", r)
		return result
	end
	if self.phase ~= "play" or not self.sim then
		return "not_playing"
	end
	if team ~= "blue" then
		return "not_blue"
	end
	local p = self.players[id]
	if p then
		if self.t - p.lastFlag < Game.FLAG_COOLDOWN then
			return "cooldown"
		end
		p.lastFlag = self.t
	end
	if not target or target == "" then
		return click("miss")
	end
	self.sim:advance(self:rt())
	self:pull()
	if self.oversight and p then
		self.oversight:humanFlagged(target)
	end
	local kind, obj, th = self.sim:target(target)
	if not kind then
		return click("miss")
	end
	if th then
		local latency = math.floor((self.sim.now - th.createdAt) * 10 + 0.5) / 10
		if self.demo then
			self:settle() -- whatever else ended while the town caught up is scored first
		end
		self.sim:catch(th.id)
		self.sim:drainResolved() -- a catch is scored here, not in settle()
		if self.oversight then
			self.oversight:caught(th.id, id == Bots.MONITOR_ID and "monitor" or "human")
		end
		self.score.blue += self.cfg.CATCH_POINTS
		self.tally.catches += 1
		self:emit("watchtower", "threat_caught", th.id, {
			attack = th.kind,
			by = self:nameOf(id),
			target = target,
			points = self.cfg.CATCH_POINTS,
			after = latency,
			claimed = th.claimed,
		})
		self.telemetry:record(self.t, "threat_resolved", { threat = th.id, attack = th.kind, outcome = "caught", after = latency, watchers = self:watchers() })
		return click("catch", { threat = th.id, latency = latency, attack = th.kind })
	end
	-- not a live threat: honest, or a threat that already ended
	local honest = (obj.threat == nil)
	if not honest then
		return click("stale")
	end
	if kind == "message" and obj.state ~= "road" then
		return click("stale")
	end
	self.sim:hold(target)
	self.score.blue += self.cfg.FALSE_ALARM_POINTS
	self.tally.false_alarms += 1
	if self.oversight then
		self.oversight:falseAlarm(target, self:nameOf(id))
	end
	self:emit("watchtower", "false_alarm", target, { by = self:nameOf(id), points = self.cfg.FALSE_ALARM_POINTS, stall = self.cfg.FALSE_ALARM_STALL, what = kind })
	return click("false_alarm")
end

-- a watchtower click that hit nothing flaggable (telemetry only)
function Game:click(id: any, ctx: { [string]: any }?)
	local p = self.players[id]
	self.telemetry:record(self.t, "click", { player = self:nameOf(id), team = p and p.team, target = nil, camera = ctx and ctx.camera or (p and p.camera) })
end

------------------------------------------------------------------------ council

function Game:needed(): number
	return Council.needed(self:humans().present)
end

-- Toggle this player's yes vote on swapping `layer`; carry it on a majority.
-- Returns the vote now (true / false), or nil for an unknown proposal / player.
function Game:vote(id: any, layer: string): boolean?
	if not self.players[id] or not self.cfg.LAYER_OPTIONS[layer] then
		return nil
	end
	local yes = self.council:toggle(id, layer)
	self.telemetry:record(self.t, "vote", { player = self:nameOf(id), proposal = layer, yes = yes, count = self.council:count(layer), needed = self:needed() })
	self:checkCouncil()
	return yes
end

function Game:otherOption(layer: string): string
	local opts = self.cfg.LAYER_OPTIONS[layer]
	return self.layers[layer] == opts[1] and opts[2] or opts[1]
end

function Game:checkCouncil()
	local present = self:humans().present
	for layer in self.cfg.LAYER_OPTIONS do
		if self.council:passes(layer, present) then
			local yes = self.council:count(layer)
			self.council:clear(layer)
			self:applySwap(layer, self:otherOption(layer), yes, present)
		end
	end
end

-- Swap a layer now (a carried vote, or the demo's presenter).
function Game:applySwap(layer: string, to: string, yes: number?, present: number?)
	local from = self.layers[layer]
	if from == to then
		return
	end
	self.layers[layer] = to
	if self.sim then
		self.sim:advance(self:rt())
		self:pull()
	end
	self:emit("council", "layer_swapped", layer, { from = from, to = to, yes = yes or 0, present = present or self:humans().present })
	if self.sim then
		self.sim:setLayer(layer, to)
		self:settle()
	end
	if self.oversight then
		self.oversight:mark(self:rt(), self:settingLabel())
	end
	self.telemetry:record(self.t, "layer_swapped", { layer = layer, from = from, to = to })
end

----------------------------------------------------------- the oversight demo

function Game:roundSeconds(): number
	return self.demo and (self.cfg.DEMO_ROUND_SECONDS or 900) or self.cfg.ROUND_SECONDS
end

function Game:settingLabel(): string
	return string.format("%d agents · monitors %s · auth %s · registry %s", self.size, self.monitors and "on" or "off", self.layers.auth, self.layers.registry)
end

-- A fresh round now (the intermission skipped): the demo's settings take
-- effect from a clean town.
function Game:restartRound()
	if self.phase == "play" and self.sim then
		self.sim:advance(self:rt())
		self:pull()
		self:settle()
	end
	self.sim = nil
	self:startRound()
end

-- Oversight mode on or off. On: a fresh, long round at the current size.
-- Off: back to the original five-agent game, monitors off, a fresh round.
function Game:setOversight(on: boolean)
	if on == self.demo then
		return
	end
	self.demo = on
	if not on then
		self.size = #self.cfg.SELLERS + #self.cfg.BUYERS
		self.monitors = false
		self.beat = 0
	end
	self.telemetry:record(self.t, "oversight", { on = on, size = self.size, monitors = self.monitors })
	self:restartRound()
end

-- The town grows while it runs; a smaller town is a fresh round.
function Game:setSize(n: number)
	if not table.find(self.cfg.TOWN_SIZES, n) then
		return
	end
	if not self.demo then
		self.size = n
		self:setOversight(true)
		return
	end
	if n == self.size then
		return
	end
	local grow = n > self.size
	self.size = n
	self.telemetry:record(self.t, "town_size", { size = n })
	if grow and self.sim and self.phase == "play" then
		self.sim:advance(self:rt())
		self:pull()
		self.sim:grow(n)
		self:emit("town", "town_grew", "town", { size = n })
		if self.oversight then
			self.oversight:mark(self:rt(), self:settingLabel())
		end
	else
		self:restartRound()
	end
end

function Game:setMonitors(on: boolean)
	if not self.demo then
		self.monitors = on
		self:setOversight(true)
		return
	end
	if on == self.monitors then
		return
	end
	self.monitors = on
	self.telemetry:record(self.t, "monitors", { on = on })
	if self.oversight then
		self.oversight:setMonitors(on, self:rt())
		self.oversight:mark(self:rt(), self:settingLabel())
	end
	self:emit("town", "monitors_switched", "monitors", { on = on })
end

-- Step to beat i of Oversight.BEATS (default: the next one, wrapping).
function Game:setBeat(i: number?)
	local beats = Oversight.BEATS
	local n = i or (self.beat % #beats) + 1
	local b = beats[n]
	if not b then
		return nil
	end
	self.beat = n
	if b.oversight == false then
		self:setOversight(false)
		if self.layers.auth ~= self.cfg.DEFAULT_LAYERS.auth then
			self:applySwap("auth", self.cfg.DEFAULT_LAYERS.auth)
		end
		return b
	end
	if b.oversight and not self.demo then
		self.size = b.size or self.size
		if b.monitors ~= nil then
			self.monitors = b.monitors
		end
		if b.auth and self.layers.auth ~= b.auth then
			self.layers.auth = b.auth -- before the round starts: no swap to show
		end
		self:setOversight(true)
		self.beat = n
		return b
	end
	if b.size then
		self:setSize(b.size)
	end
	if b.monitors ~= nil then
		self:setMonitors(b.monitors)
	end
	if b.auth and self.layers.auth ~= b.auth then
		self:applySwap("auth", b.auth)
	end
	self.beat = n
	return b
end

function Game:tickOversight(rt: number)
	local sim = self.sim
	local watcher = self:botOn("blue")
	self.oversight:tick(rt, {
		watcher = watcher,
		live = function(threatId: string): boolean
			local th = sim.threats[threatId]
			return th ~= nil and th.state == "live"
		end,
		flag = function(as: string, target: string)
			return self:flag(as == "monitor" and Bots.MONITOR_ID or Bots.BLUE_ID, target, { camera = as })
		end,
	})
end

-- What the oversight HUD shows (nil when the demo is off).
function Game:oversightMetrics()
	if not self.oversight or not self.sim then
		return nil
	end
	local sim = self.sim
	return self.oversight:metrics(self:rt(), {
		size = sim:size(),
		target = self.size,
		openThreats = #sim:liveThreats(),
		auth = self.layers.auth,
		registry = self.layers.registry,
		beat = self.beat,
		beats = #Oversight.BEATS,
		beatLabel = Oversight.BEATS[self.beat] and Oversight.BEATS[self.beat].label or nil,
		nextLabel = Oversight.BEATS[(self.beat % #Oversight.BEATS) + 1].label,
		watcher = self:botOn("blue") and "BlueBot" or "you",
		deals = sim.stats.dealsSettled,
	})
end

------------------------------------------------------------------------ for clients

-- What a client joining mid-game replays to catch up: the round header and
-- the town's current state.
function Game:snapshotEvents(): { any }
	local list = {}
	table.insert(list, {
		seq = self.counter.n,
		id = "ev-" .. self.counter.n,
		event_id = "ev-" .. self.counter.n,
		at = math.floor(math.max(0, self:rt()) * 100 + 0.5) / 100,
		observer = "town",
		kind = "round_started",
		subject = "round-" .. self.round,
		layer = "game",
		detail = {
			round = self.round,
			seconds = self.cfg.ROUND_SECONDS,
			layers = { auth = self.layers.auth, registry = self.layers.registry, transport = self.layers.transport },
			tokens = self.tokens,
		},
		snapshot = true,
	})
	if self.sim then
		for _, e in self.sim:snapshotEvents() do
			table.insert(list, e)
		end
	end
	return list
end

-- The numbers the HUD shows (the server publishes them as attributes).
function Game:status()
	local h = self:humans()
	return {
		phase = self.phase,
		round = self.round,
		left = math.max(0, self.phaseEnds - self.t),
		red = self.score.red,
		blue = self.score.blue,
		deals = self.sim and self.sim.stats.dealsSettled or (self.lastDeals or 0),
		tokens = self.tokens,
		auth = self.layers.auth,
		registry = self.layers.registry,
		voteAuth = self.council:count("auth"),
		voteRegistry = self.council:count("registry"),
		needed = Council.needed(h.present),
		present = h.present,
		redBot = self:botOn("red"),
		blueBot = self:botOn("blue"),
		winsRed = self.wins.red,
		winsBlue = self.wins.blue,
		escapes = self.tally.escapes,
		catches = self.tally.catches,
		falseAlarms = self.tally.false_alarms,
		blocked = self.tally.blocked,
		demo = self.demo,
		size = self.demo and self.size or (#self.cfg.SELLERS + #self.cfg.BUYERS),
		monitors = self.monitors,
		beat = self.beat,
	}
end

return Game
