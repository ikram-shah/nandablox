-- Shared helpers for the NANDA Market tests.

local base = "../../src/market/shared/Market/"
local function req(name: string): any
	return (require :: any)(base .. name)
end

local lib = {}
lib.Config = req("Config")
lib.MarketSim = req("MarketSim")
lib.Layout = req("Layout")
lib.Gateway = req("Gateway")
lib.Rng = req("Rng")
lib.Avatars = req("Avatars")

function lib.config(over: { [string]: any }?)
	local c = table.clone(lib.Config)
	for k, v in over or {} do
		c[k] = v
	end
	return c
end

-- A market in one setting, measured over `seconds` after a `warm` warm-up,
-- with one modelled watcher. Returns the meter and the sim.
function lib.measure(opts)
	local sim = lib.MarketSim.new({ seed = opts.seed or 1, n = opts.n, config = opts.config })
	sim:setMonitor(opts.monitor or "off")
	sim:setSignatures(if opts.signatures == nil then true else opts.signatures)
	for i = 1, opts.watchers or 1 do
		sim:addWatcher("w" .. i, { auto = true })
	end
	sim:runUntil(opts.warm or 60)
	sim:drain()
	sim:mark("measured")
	local events = {}
	local stop = (opts.warm or 60) + (opts.seconds or 180)
	while sim.now < stop - 1e-9 do
		sim:step(0.25)
		for _, e in sim:drain() do
			if opts.keep then
				table.insert(events, e)
			end
		end
	end
	return sim:meter(), sim, events
end

-- mean over seeds of the numbers the claims are about
function lib.mean(opts, seeds: { number })
	local acc = {
		calls = 0, perWatcher = 0, caught = 0, escaped = 0, falseAlarms = 0, deals = 0, frauds = 0,
		rejected = 0, decided = 0,
	}
	for _, seed in seeds do
		local o = table.clone(opts)
		o.seed = seed
		local m = lib.measure(o)
		local minutes = m.elapsed / 60
		acc.calls += m.asked / minutes
		acc.perWatcher += m.asked / minutes / math.max(1, m.watchers)
		acc.caught += m.caught / minutes
		acc.escaped += m.escaped / minutes
		acc.falseAlarms += m.falseAlarms / minutes
		acc.deals += m.deals / minutes
		acc.frauds += m.frauds / minutes
		acc.rejected += m.rejected / minutes
		acc.decided += m.decided / minutes
	end
	for k, v in acc do
		acc[k] = v / #seeds
	end
	return acc
end

return lib
