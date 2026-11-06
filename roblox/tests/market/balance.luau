-- not a test: Blue strategies over a full round against the bot Red, run by hand
local lib = require("./lib")
local Round = (require :: any)("../../src/market/shared/Market/Round")
local Config = lib.Config
local function play(seed, strategy)
	local sim = lib.MarketSim.new({ seed = seed, n = 5 })
	sim:addWatcher("you", { auto = true })
	local r = Round.new(Config)
	r:start(sim.now, sim:getTotals())
	local asked = {}
	while not r.done do
		sim:step(0.25)
		local el = r:elapsed(sim.now)
		for _, ph in r:update(sim.now, sim:getTotals(), #sim.watchers, sim:gameState()) do
			Round.apply(sim, ph.phase.set)
		end
		for _, p in r:prompt(sim.monitor) do
			if p.ask == "monitor" then sim:setMonitor("rules"); r:answer(p.id) end
			if p.ask == "vote" then r:answer(p.id) end
		end
		for _, e in sim:drain() do
			if strategy == "adaptive" and e.k == "deal" and e.ok == false then
				local want = ({ talker = "pitchReader", counterfeit = "inspector", scam = "priceFloor", impostor = "idCheck" })[e.kind]
				if want and not asked[want] then asked[want] = true; sim:requestCheck(want, true) end
			end
		end
		if el >= 65 and not asked.start then
			asked.start = true
			if strategy == "heavy" then for _, c in { "priceFloor", "voucher", "inspector", "escrow" } do sim:requestCheck(c, true) end end
			if strategy == "escrow" then sim:requestCheck("escrow", true) end
			if strategy == "none" then sim:setMonitor("rules"); sim:setLoadout({}) end
		end
	end
	local sb = r.score
	return sb
end
for _, strat in { "none", "preset", "adaptive", "escrow", "heavy" } do
	local b, rr, st, tr, fr = 0, 0, 0, 0, 0
	for seed = 1, 3 do
		local sb = play(seed, strat)
		b += sb.blue.score; rr += sb.red.score; st += sb.blue.stolen; tr += sb.blue.trade; fr += sb.blue.friction
	end
	print(string.format("%-9s Blue %7.0f (trade %6.0f stolen %6.0f friction %6.0f)  Red %7.0f", strat, b / 3, tr / 3, st / 3, fr / 3, rr / 3))
end
