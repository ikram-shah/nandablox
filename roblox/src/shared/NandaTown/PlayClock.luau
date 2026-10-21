-- The play place's shared timeline. The server owns two facts, published as
-- workspace attributes:
--
--   NandaScenario  the trace module name (ReplicatedStorage.NandaTown.Traces.*)
--   NandaStart     the server time (workspace:GetServerTimeNow()) of replay t = 0
--   NandaRun       a counter, bumped on every (re)start, so clients notice a
--                  restart even when scenario and period repeat
--
-- and every client renders the same timeline from the trace locally:
-- t = GetServerTimeNow() - NandaStart. A run is LEAD seconds of quiet town, the
-- replay itself (Replay.schedule, ~TARGET seconds), HOLD seconds on the
-- verdict, then PAUSE seconds before the server starts the next run. Both
-- sides compute the period from the same trace with the same code, so nothing
-- but the two attributes crosses the network.

local Replay = require(script.Parent.Replay)

local PlayClock = {}

PlayClock.TARGET = 52 -- seconds of replay (the movie's pacing)
PlayClock.LEAD = 2.0 -- quiet town before the first event
PlayClock.HOLD = 6.0 -- on the verdict
PlayClock.PAUSE = 4.0 -- between runs (a countdown on screen)
PlayClock.SWITCH_DELAY = 1.0 -- a board pick starts the new run this far ahead

PlayClock.DEFAULT = "marketplace"
-- Not a trace: NandaScenario = LIVE means Red vs. Blue (live), a TownSim
-- running on the server (RedBlueServer.luau) instead of a recorded run.
PlayClock.LIVE = "redblue"

-- The board's order: the movie's scenario first, then the rest by name.
PlayClock.ORDER = {
	"marketplace",
	"auction",
	"supply_chain",
	"voting",
	"consensus",
	"capability_spoofing",
	"capability_spoofing_weak_auth",
	"capped_influence",
	"capped_influence_uncapped_control",
	"registry_eviction",
	"registry_eviction_unowned",
}

local cache: { [string]: any } = {}

-- { times, lead, finish (last event), ends (verdict hold over), period }
function PlayClock.timeline(trace): { [string]: any }
	local key = tostring(trace.run_id) .. ":" .. tostring(trace.scenario)
	if cache[key] then
		return cache[key]
	end
	local times = Replay.schedule(trace, PlayClock.TARGET)
	local finish = PlayClock.LEAD + times[#times]
	local tl = {
		times = times,
		lead = PlayClock.LEAD,
		finish = finish,
		ends = finish + PlayClock.HOLD,
		period = finish + PlayClock.HOLD + PlayClock.PAUSE,
	}
	cache[key] = tl
	return tl
end

function PlayClock.traces(): Instance
	return script.Parent:WaitForChild("Traces")
end

function PlayClock.load(name: string)
	local m = PlayClock.traces():FindFirstChild(name)
	if not m then
		return nil
	end
	return require(m :: ModuleScript)
end

return PlayClock
