-- The oversight demo (roblox/DEMO.md), headless: the same Game / TownSim /
-- Oversight modules the Roblox server runs, stepped through the demo's beats
-- in simulated time, printing the HUD's numbers at the end of each beat. It is
-- the rehearsal without Studio, and the source of the backup-slide numbers.
--
--   tools/scale_demo.sh              # 60 s per beat, seed 1
--   tools/scale_demo.sh 45 3         # 45 s per beat, seed 3
--   tools/scale_demo.sh 60 1 json    # one JSON object per beat

local process = require("@lune/process")
local serde = require("@lune/serde")

local base = "../src/shared/NandaTown/RedBlue/"
local Config = (require :: any)(base .. "Config")
local Game = (require :: any)(base .. "Game")
local Oversight = (require :: any)(base .. "Oversight")

local perBeat = tonumber(process.args[1]) or 60
local seed = tonumber(process.args[2]) or 1
local json = process.args[3] == "json"

local g = Game.new({ config = Config, seed = seed })
g:start(0)
local t = 0
local function run(seconds: number)
	local stop = t + seconds
	while t < stop - 1e-9 do
		t = math.min(stop, t + Config.TICK_SECONDS)
		g:tick(t)
	end
end
run(5) -- the live mode, before the demo

local function show(b)
	local m = g:oversightMetrics()
	if not m then
		print(string.format("%-10s (oversight off)", b.id))
		return
	end
	if json then
		m.rows = nil
		m.beat_id = b.id
		print(serde.encode("json", m))
		return
	end
	print(string.format(
		"%-9s %3d agents  monitors %-3s auth %-8s | events/min %5.0f  threats/min %4.1f  judgment calls/min %5.1f (human can do %d)  queue %3d  open threats %2d | caught %3d (monitors %3d, human %3d)  escaped %3d (missed by monitors %d, waited %d, human wrong %d)  false alarms %d  blocked by layers %d  deals %d",
		b.id,
		m.size,
		m.monitors and "on" or "off",
		m.auth,
		m.eventsPerMin,
		m.threatsPerMin,
		m.callsPerMin,
		m.capacityPerMin,
		m.queue,
		m.openThreats,
		m.caught,
		m.autoCaught,
		m.humanCaught,
		m.escaped,
		m.missedByMonitors,
		m.escapedWaiting,
		m.humanWrong,
		m.falseAlarms,
		m.blocked,
		m.deals
	))
end

for i, b in Oversight.BEATS do
	g:setBeat(i)
	if b.oversight == false then
		show(b)
		break
	end
	run(perBeat)
	show(b)
end
