-- Ghost: a whole 5:00 round played headless by a Blue that holds one
-- loadout all round, against the bot Red. The balance tests use it (no
-- checks loses, every check loses, a sensible loadout wins), and the server
-- runs two at the start of each round, a slice per frame, so the scoreboard
-- can mark where the two extreme Blues would have finished on that seed.
--
--   local g = Ghost.new(seed, { "priceFloor", "voucher", "inspector" })
--   while not g.done do g:advance(10) end
--   g:result()  -- { blue = cents, red = cents, winner, stolen, ... }

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local DefaultConfig = sibling("Config")
local MarketSim = sibling("MarketSim")
local Round = sibling("Round")
local Score = sibling("Score")

local Ghost = {}
Ghost.__index = Ghost

Ghost.NONE = {}
Ghost.ALL = { "priceFloor", "voucher", "idCheck", "pitchReader", "inspector", "escrow" }
Ghost.SENSIBLE = { "priceFloor", "voucher", "inspector" }

function Ghost.new(seed: number, list: { string }, cfg)
	cfg = cfg or DefaultConfig
	local sim = MarketSim.new({ seed = seed, n = 5, config = cfg })
	-- one person at the inbox, deciding what the checks escalate
	sim:addWatcher("blue", { auto = true })
	local round = Round.new(cfg)
	round:start(sim.now, sim:getTotals())
	local self = setmetatable({ sim = sim, round = round, list = list, cfg = cfg, done = false }, Ghost)
	self:hold()
	return self
end

-- the loadout, held: the checks decide, a person sees what they escalate
function Ghost:hold()
	self.sim:setMonitor("rules", nil, true)
	self.sim:setLoadout(self.list)
end

function Ghost:advance(seconds: number)
	local sim, round = self.sim, self.round
	local stop = sim.now + seconds
	while not self.done and sim.now < stop - 1e-9 do
		sim:step(0.25)
		sim:drain()
		for _, ph in round:update(sim.now, sim:getTotals(), #sim.watchers) do
			Round.apply(sim, ph.phase.set)
			self:hold()
		end
		for _, p in round:prompt(sim.monitor) do
			round:answer(p.id)
		end
		round:checkMoney(sim, { "bot" })
		self.done = round.done
	end
	return self.done
end

function Ghost:result()
	local d = self.round:diff(self.sim:getTotals())
	local b = Score.blue(d, self.cfg)
	local r = Score.red(d)
	return {
		blue = b.score,
		red = r.score,
		winner = self.round.score and self.round.score.ended and self.round.score.ended.winner or Score.winner(b.score, r.score),
		ended = self.round.score and self.round.score.ended and self.round.score.ended.why or nil,
		endedAt = self.round.score and self.round.score.endedAt or nil,
		fees = b.fees,
		refunds = b.refunds,
		fines = b.fines,
		costs = b.costs,
		stolen = r.stolen,
		honestDeals = d.honestDeals or 0,
		frauds = d.frauds or 0,
		done = self.done,
	}
end

function Ghost.play(seed: number, list: { string }, cfg)
	local g = Ghost.new(seed, list, cfg)
	while not g.done do
		g:advance(30)
	end
	return g:result()
end

return Ghost
