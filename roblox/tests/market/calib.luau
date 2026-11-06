-- not a test (no test_ prefix): friction calibration, run by hand
local lib = require("./lib")
local process = require("@lune/process")
local function deals(n, lo, seed, over)
	local cfg = lib.config(over or {})
	local sim = lib.MarketSim.new({ seed = seed, n = n, config = cfg })
	sim:setMonitor("rules")
	sim:setLoadout(lo)
	sim.fraudsPaused = true
	sim:runUntil(60)
	local t0 = sim:getTotals().honestDeals
	sim:runUntil(240)
	return (sim:getTotals().honestDeals - t0) / 3
end
local sets = {
	[0] = {}, [1] = { "voucher" }, [2] = { "idCheck" }, [3] = { "voucher", "idCheck" },
	[4] = { "escrow" }, [6] = { "idCheck", "escrow" }, [7] = { "voucher", "idCheck", "escrow" },
	[8] = { "voucher", "inspector", "escrow" }, [9] = { "idCheck", "inspector", "escrow" },
	[10] = { "voucher", "idCheck", "inspector", "escrow" }, [11] = { "voucher", "idCheck", "pitchReader", "inspector", "escrow" },
}
local n = tonumber(process.args[1]) or 300
if process.args[2] == "zero" then sets = { [0] = {} } end
local fs = {}
for f in sets do table.insert(fs, f) end
table.sort(fs)
local base
for _, f in fs do
	local d = 0
	for seed = 1, 3 do d += deals(n, sets[f], seed) end
	d /= 3
	base = base or d
	print(string.format("n=%d F=%2d deals/min %.1f  rel %.2f", n, f, d, d / base))
end
