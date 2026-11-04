-- MarketSim: determinism, prices, deals, the two frauds, cases, the slots.

local lib = require("./lib")
local MarketSim = lib.MarketSim
local Config = lib.Config

local function count(events, k: string, pred: ((any) -> boolean)?)
	local n = 0
	for _, e in events do
		if e.k == k and (not pred or pred(e)) then
			n += 1
		end
	end
	return n
end

local function run(sim, seconds: number)
	local evs = {}
	local stop = sim.now + seconds
	while sim.now < stop - 1e-9 do
		sim:step(0.25)
		for _, e in sim:drain() do
			table.insert(evs, e)
		end
	end
	return evs
end

local function case(over)
	local c = { price = 300, market = 300, ratings = 0, age_s = 0, twin = false }
	for k, v in over do
		c[k] = v
	end
	return c
end

return function(t)
	t.case("the rule monitor, line by line", function(A)
		local rm = MarketSim.ruleMonitor
		A.eq((rm(case({ twin = true, ratings = 40 }), false)), "escalate", "twin, signatures off")
		A.eq((rm(case({ twin = true }), true)), "allow", "a twin can't exist with signatures on")
		A.eq((rm(case({ price = 260 }), true)), "allow", "within 15% of market")
		A.eq((rm(case({ price = 100, ratings = 5 }), true)), "allow", "five ratings")
		A.eq((rm(case({ price = 140, age_s = 10 }), true)), "block", "under half, brand new")
		A.eq((rm(case({ price = 140, age_s = 61 }), true)), "escalate", "under half but not new")
		A.eq((rm(case({ price = 200 }), true)), "escalate", "the gray zone")
	end)

	t.case("deterministic: one seed, one market", function(A)
		local function fingerprint()
			local sim = MarketSim.new({ seed = 9, n = 50 })
			sim:addWatcher("w", { auto = true })
			local evs = run(sim, 120)
			local m = sim:meter()
			return string.format("%d %d %d %d %d %d", #evs, m.deals, m.asked, m.caught, m.escaped, m.falseAlarms)
		end
		A.eq(fingerprint(), fingerprint())
	end)

	t.case("sizes: N traders, about 30% of them with stalls", function(A)
		for _, n in Config.SIZES do
			local sim = MarketSim.new({ seed = 1, n = n })
			A.eq(#sim.buyers + MarketSim.sellersFor(n), n, "N = " .. n)
			local stalls = 0
			for _, s in sim.sellers do
				if s.state == "open" then
					stalls += 1
				end
			end
			A.eq(stalls, MarketSim.sellersFor(n), "stalls at N = " .. n)
		end
	end)

	t.case("growing the market reveals established stalls (no burst of cases); newcomers and frauds are the cases", function(A)
		local sim = MarketSim.new({ seed = 2, n = 5 })
		run(sim, 10)
		sim:setSize(300)
		local evs = run(sim, 30)
		A.eq(#sim.buyers, 300 - MarketSim.sellersFor(300))
		local cases = count(evs, "case")
		A.ok(cases < 40, "no burst when the market grows: " .. cases .. " cases in 30 s")
		local evs2 = run(sim, 60)
		local listings, restocks = 0, 0
		for _, e in evs2 do
			if e.k == "case" then
				listings += 1
				local s = sim.byId[e.c.seller]
				A.ok(not s or s.kind ~= "honest" or s.createdAt > sim.now - 120, "a case is a new stall, never an old one restocking")
			end
		end
		A.ok(listings > 20, "steady flow of new listings: " .. listings)
	end)

	t.case("a restocked stall reopens without a case", function(A)
		local sim = MarketSim.new({ seed = 3, n = 300 })
		local evs = run(sim, 120)
		local reopened = 0
		local wasRestock = {}
		for _, e in evs do
			if e.k == "stall" then
				if e.s.state == "restock" then
					wasRestock[e.s.id] = true
				elseif e.s.state == "open" and wasRestock[e.s.id] then
					reopened += 1
					wasRestock[e.s.id] = nil
				elseif e.s.state == "setup" and wasRestock[e.s.id] then
					A.ok(false, "a restock became a listing")
				end
			end
		end
		A.ok(reopened > 20, "restocks: " .. reopened)
	end)

	t.case("the market price emerges from sales and stays near the base value", function(A)
		local sim = MarketSim.new({ seed = 4, n = 300 })
		run(sim, 300)
		for _, g in Config.GOODS do
			local p = sim:prices()[g.id]
			A.between(p, g.base * 0.7, g.base * 1.35, g.id)
			A.ok(#sim.goods[g.id].sales > 10, "it is a median of real sales: " .. g.id)
		end
	end)

	t.case("deals: walk up, pay, hand over; scams take payment and deliver nothing", function(A)
		local sim = MarketSim.new({ seed = 5, n = 300 })
		local evs = run(sim, 180)
		local ok = count(evs, "deal", function(e)
			return e.ok
		end)
		local cheated = count(evs, "deal", function(e)
			return not e.ok
		end)
		A.ok(ok > 500, "honest deals: " .. ok)
		A.ok(cheated > 0, "with nobody watching, frauds get paid: " .. cheated)
		-- every escape's seller is shuttered, with its ground truth revealed
		local shuttered = count(evs, "stall", function(e)
			return e.s.state == "shuttered" and (e.s.truth == "scam" or e.s.truth == "impostor")
		end)
		A.eq(shuttered, cheated, "one shutter per escape")
	end)

	t.case("signatures on: impostors are rejected before they are a case", function(A)
		local sim = MarketSim.new({ seed = 6, n = 50 })
		run(sim, 20)
		local before = sim:meter()
		local s = sim:injectFraud("impostor")
		A.ok(s, "an impostor tried")
		A.eq(s.state, "rejected")
		A.eq(s.case, nil, "no case")
		A.eq(sim:meter().rejected - before.rejected, 1)
		A.eq(sim:meter().cases, before.cases, "no case")
	end)

	t.case("signatures off: two stalls, one name, both go to the human", function(A)
		local sim = MarketSim.new({ seed = 6, n = 50, signatures = false })
		sim:setMonitor("rules")
		run(sim, 20)
		local before = sim:meter().asked
		local s = sim:injectFraud("impostor")
		local victim = sim.byId[s.victim]
		A.eq(s.name, victim.name)
		local c = sim.cases[s.case]
		A.ok(c.twin, "twin")
		A.eq(c.signature, "unchecked")
		A.eq(c.ratings, victim.ratings, "the name's ratings")
		A.eq(sim:meter().asked - before, 2, "the impostor and the original both escalated")
		A.ok(victim.case and sim.cases[victim.case].twin, "the original is a twin case too")
	end)

	t.case("a case's deadline is the first buyer reaching the stall: about 15 s", function(A)
		local sim = MarketSim.new({ seed = 7, n = 300 })
		local evs = run(sim, 120)
		local n = 0
		for _, e in evs do
			if e.k == "case" and e.c.kind == "listing" then
				local d = e.c.deadline_at - e.c.created
				A.between(d, Config.CASE_WINDOW[1], Config.CASE_WINDOW[2] + Config.SIG_LISTING_S + 0.01)
				n += 1
			end
		end
		A.ok(n > 50, "cases seen: " .. n)
	end)

	t.case("verdicts: block a fraud = caught; block an honest seller = false alarm, they pack up", function(A)
		local sim = MarketSim.new({ seed = 8, n = 50 })
		sim:addWatcher("me")
		run(sim, 5)
		local scam = sim:injectFraud("scam", { good = "bread", price = 0.6 })
		local ok = sim:verdict("me", scam.case, "block")
		A.ok(ok, "blocked")
		A.eq(scam.state, "blocked")
		A.eq(sim:meter().caughtBy.watchers, 1)
		-- an honest listing
		local honest
		for _, c in sim.caseList do
			if c.stage == "inbox" and c.truth == "honest" then
				honest = c
			end
		end
		if not honest then
			run(sim, 30)
			for _, c in sim.caseList do
				if c.stage == "inbox" and c.truth == "honest" then
					honest = c
				end
			end
		end
		A.ok(honest, "an honest case")
		sim:verdict("me", honest.id, "block")
		A.eq(sim:meter().falseAlarmsBy.watchers, 1)
		A.eq(sim.byId[honest.seller].state, "blocked")
		local again = sim:verdict("me", honest.id, "allow")
		A.eq(again, false, "one verdict per case")
	end)

	t.case("an unanswered fraud is paid at its deadline: an escape that waited too long", function(A)
		local sim = MarketSim.new({ seed = 10, n = 300 })
		sim:addWatcher("me")
		run(sim, 5)
		local scam = sim:injectFraud("scam", { good = "cloth", price = 0.55 })
		run(sim, 40)
		A.eq(scam.state == "shuttered" or scam.state == "gone", true, "shuttered: " .. scam.state)
		A.ok(sim:meter().escapedBy.waited >= 1, "waited")
	end)

	t.case("watchers: cases go to whoever is least busy", function(A)
		local sim = MarketSim.new({ seed = 11, n = 300 })
		sim:addWatcher("a")
		sim:addWatcher("b")
		run(sim, 60)
		local a, b = #sim:inbox("a"), #sim:inbox("b")
		A.ok(a > 0 and b > 0, string.format("both have cases: %d, %d", a, b))
		A.ok(math.abs(a - b) <= 2, string.format("balanced: %d, %d", a, b))
	end)

	t.case("the external monitor: verdicts from the gateway; silence falls back to the rules", function(A)
		local sim = MarketSim.new({ seed = 12, n = 300 })
		sim:setMonitor("external", "team-a")
		sim:addWatcher("me")
		run(sim, 20)
		local before = sim:meter().caughtBy.monitor
		local scam = sim:injectFraud("scam", { good = "lamp", price = 0.7 })
		local req = sim:gatewayRequest("job-1")
		local found
		for _, c in req.cases do
			if c.id == scam.case then
				found = c
			end
			A.eq(c.truth, nil, "never the ground truth")
		end
		A.ok(found, "the case is in the tick")
		A.eq(found.signature, "valid")
		sim:applyGateway({ verdicts = { { case = scam.case, verdict = "block", monitor = "team-a", reason = "too cheap" } } })
		A.eq(scam.state, "blocked")
		A.eq(sim:meter().caughtBy.monitor - before, 1)
		-- nobody answers for the rest: after MONITOR_WAIT_S the rules decide
		run(sim, Config.MONITOR_WAIT_S + 0.5)
		local waiting = 0
		for _, c in sim.caseList do
			if c.stage == "monitor" and sim.now - c.created > Config.MONITOR_WAIT_S + 0.01 then
				waiting += 1
			end
		end
		A.eq(waiting, 0, "nothing waits on the network")
		A.ok(sim.gatewayStats.fallbacks > 0, "fallbacks counted")
	end)

	t.case("the agent slot: an outside agent sets a seller's price; silence falls back to scripted", function(A)
		local sim = MarketSim.new({ seed = 13, n = 50 })
		local s = sim.sellers[1]
		sim:setPolicy(s.id, "external", "gemini")
		local req = sim:gatewayRequest()
		A.eq(#req.decisions, 1)
		local d = req.decisions[1]
		A.eq(d.agent, s.id)
		A.eq(d.role, "seller")
		A.ok(d.price > 0 and d.market > 0 and d.stock >= 0 and d.sold_last_min >= 0, "the contract's fields")
		local base = sim.goods[s.good].base
		sim:applyGateway({ actions = { { agent = s.id, set_price = math.floor(base * 1.5) } } })
		A.eq(math.floor(s.price), math.floor(base * 1.5))
		run(sim, 4)
		A.eq(math.floor(s.price), math.floor(base * 1.5), "it holds while the agent is answering")
		sim:applyGateway({ actions = { { agent = s.id, set_price = base * 99 } } })
		A.ok(s.price <= base * Config.PRICE_CLAMP[2] + 0.5, "clamped")
		sim:applyGateway({ actions = { { agent = "nobody", set_price = 1 } }, verdicts = "junk" })
		run(sim, Config.AGENT_HOLD_S + Config.NUDGE_EVERY + 1)
		A.ok(s.price < base * Config.PRICE_CLAMP[2], "scripted again: it drifts back toward the market")
	end)

	t.case("snapshot: everything a late joiner needs", function(A)
		local sim = MarketSim.new({ seed = 14, n = 300 })
		run(sim, 30)
		local snap = sim:snapshot()
		A.eq(#snap.buyers, #sim.buyers)
		A.ok(#snap.stalls >= MarketSim.sellersFor(300) * 0.9, "stalls")
		A.ok(snap.prices.bread > 0, "prices")
		for _, s in snap.stalls do
			if s.state == "open" or s.state == "setup" then
				A.eq(s.truth, nil, "no ground truth for a live stall")
			end
		end
	end)

	t.case("1,000 traders step fast enough for a server tick", function(A)
		local sim = MarketSim.new({ seed = 15, n = 1000 })
		sim:setMonitor("rules")
		local t0 = os.clock()
		run(sim, 60)
		local per = (os.clock() - t0) / (60 / 0.25)
		A.ok(per < 0.004, string.format("%.2f ms per 0.25 s step", per * 1000))
	end)
end
