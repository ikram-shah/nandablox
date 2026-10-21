-- Shared helpers for the headless tests.

local base = "../src/shared/NandaTown/RedBlue/"
local function req(name: string): any
	return (require :: any)(base .. name)
end

local lib = {}
lib.Config = req("Config")
lib.TownSim = req("TownSim")
lib.Game = req("Game")
lib.Council = req("Council")
lib.Bots = req("Bots")
lib.Rng = req("Rng")
lib.Telemetry = req("Telemetry")
lib.Policy = req("Policy")

-- A copy of Config with overrides (tests never mutate the real one).
function lib.config(over: { [string]: any }?)
	local c = {}
	for k, v in lib.Config do
		c[k] = v
	end
	for k, v in over or {} do
		c[k] = v
	end
	return c
end

-- A quiet town: no random transport faults, so a deal's events are exact.
function lib.quiet(over: { [string]: any }?)
	local o = { DUPLICATE_DELIVERY_RATE = 0, DROP_QUOTE_RATE = 0 }
	for k, v in over or {} do
		o[k] = v
	end
	return lib.config(o)
end

function lib.sim(cfg, layers, seed)
	local s = lib.TownSim.new({ config = cfg, layers = layers, seed = seed or 42 })
	s:start()
	return s
end

-- advance in small steps (as the server does), collecting events
function lib.run(sim, untilT: number, step: number?)
	local evs = {}
	local t = sim.now
	local dt = step or 0.1
	while t < untilT - 1e-9 do
		t = math.min(untilT, t + dt)
		sim:advance(t)
		for _, e in sim:drain() do
			table.insert(evs, e)
		end
	end
	return evs
end

function lib.runGame(game, untilT: number, step: number?)
	local evs = {}
	local t = game.t
	local dt = step or 0.1
	while t < untilT - 1e-9 do
		t = math.min(untilT, t + dt)
		for _, e in game:tick(t) do
			table.insert(evs, e)
		end
	end
	return evs
end

function lib.ofKind(evs, kind: string)
	local out = {}
	for _, e in evs do
		if e.kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

function lib.first(evs, pred)
	for _, e in evs do
		if pred(e) then
			return e
		end
	end
	return nil
end

function lib.count(evs, pred): number
	local n = 0
	for _, e in evs do
		if pred(e) then
			n += 1
		end
	end
	return n
end

function lib.ledgerTotal(sim): number
	local total = 0
	for _, v in sim.balances do
		total += v
	end
	for _, d in sim.deals do
		total += d.escrow or 0
	end
	return total
end

return lib
