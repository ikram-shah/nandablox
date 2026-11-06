-- The counterfeit stall, the running totals, and the timed 5:00 round.

local lib = require("./lib")
local MarketSim = lib.MarketSim
local Config = lib.Config
local Round = (require :: any)("../../src/market/shared/Market/Round")

local function run(sim, seconds: number, evs)
	evs = evs or {}
	local stop = sim.now + seconds
	while sim.now < stop - 1e-9 do
		sim:step(0.25)
		for _, e in sim:drain() do
			table.insert(evs, e)
		end
	end
	return evs
end

local function find(evs, pred)
	for _, e in evs do
		if pred(e) then
			return e
		end
	end
	return nil
end

-- a market with only the fraud we inject: the scripted fraud agents rest
local function quiet(seed: number, n: number, monitor: string)
	local sim = MarketSim.new({ seed = seed, n = n })
	sim:setMonitor(monitor)
	sim.fraudsPaused = true
	run(sim, 20)
	sim:drain()
	return sim
end

return function(t)
	t.case("counterfeit: priced just under market, listed as a print, framed prints on the counter", function(A)
		local sim = quiet(3, 50, "off")
		sim:addWatcher("w")
		local s = sim:injectFraud("counterfeit", { good = "spice" })
		A.ok(s, "a free slot")
		A.eq(s.kind, "counterfeit")
		local m = sim.goods.spice.market
		A.between(s.price / m, Config.COUNTERFEIT_PRICE[1] - 0.01, Config.COUNTERFEIT_PRICE[2] + 0.01, "price vs market")
		local evs = sim:drain()
		local ce = find(evs, function(e)
			return e.k == "case" and e.c.seller == s.id
		end)
		A.ok(ce, "it is a case")
		A.eq(ce.c.listing, "spice (print)")
		A.eq(ce.c.display, "prints")
		A.eq(ce.c.truth, nil, "no ground truth on the card")
		local st = find(evs, function(e)
			return e.k == "stall" and e.s.id == s.id
		end)
		A.eq(st.s.display, "prints", "the stall shows prints")
		A.eq(st.s.truth, nil, "no ground truth while it trades")
	end)

	t.case("counterfeit escapes the price floor: allowed, then sells prints (a red ✕ counterfeit per sale)", function(A)
		local sim = quiet(4, 50, "rules")
		-- the loadout replaces the rule monitor: the price floor alone (its
		-- preset's voucher would send an unvouched counterfeit to the inbox)
		sim:setLoadout({ "priceFloor", "idCheck" })
		local before = sim:getTotals()
		local s = sim:injectFraud("counterfeit", { good = "bread", owner = "p1" })
		local evs = sim:drain()
		local done = find(evs, function(e)
			return e.k == "caseEnd" and e.seller == s.id
		end)
		A.ok(done, "the monitor decided at once")
		A.eq(done.verdict, "allow", "the price floor lets it through")
		A.eq(done.by, "monitor")
		A.eq(done.truth, "counterfeit")
		run(sim, 90, evs)
		local fakes = 0
		for _, e in evs do
			if e.k == "deal" and e.seller == s.id then
				A.eq(e.ok, false, "a print is not the good")
				A.eq(e.counterfeit, true)
				fakes += 1
			end
		end
		A.between(fakes, 1, Config.COUNTERFEIT_SALES, "prints sold")
		local after = sim:getTotals()
		A.eq(after.escaped - before.escaped, 1, "one escape per stall, however many prints")
		A.ok(after.stolen > before.stolen, "stolen value counted")
		A.eq(sim:stolenFor("p1"), after.stolen - before.stolen, "the red player's tally")
		local m = sim:meter()
		A.ok(m.escaped >= 1, "the meter counts the escape")
	end)

	t.case("counterfeit is caught when a watcher blocks it", function(A)
		local sim = quiet(5, 50, "off")
		sim:addWatcher("w")
		local s = sim:injectFraud("counterfeit")
		local c = sim.cases[s.case]
		A.ok(c and c.stage == "inbox", "in the inbox")
		A.ok(sim:verdict("w", c.id, "block"))
		A.eq(s.state, "blocked")
		local m = sim:meter()
		A.eq(m.caught, 1)
		A.eq(m.falseAlarms, 0)
		A.eq(sim:getTotals().caught, 1)
	end)

	t.case("the keyword line (off by default) escalates a print listing; in the loadout the pitch reader does, and a watcher catches it", function(A)
		A.eq(Config.RULE_KEYWORD_PRINT, false, "off by default")
		local rm = MarketSim.ruleMonitor
		local c = { price = 760, market = 800, ratings = 0, age_s = 0, twin = false, listing = "spice (print)" }
		A.eq((rm(c, true)), "allow", "flag off: the price rule allows it")
		A.eq((rm(c, true, nil, true)), "escalate", "flag on: escalated")
		A.eq((rm(lib.config({ RULE_KEYWORD_PRINT = true }) and c, true, lib.config({ RULE_KEYWORD_PRINT = true }))), "escalate", "flag on via config")
		A.eq((rm({ price = 760, market = 800, ratings = 0, age_s = 0, twin = false, listing = "spice" }, true, nil, true)), "allow", "an honest listing")
		local photo = { price = 760, market = 800, ratings = 0, age_s = 0, twin = false, listing = "lamps (PHOTO)" }
		A.eq((rm(photo, true, nil, true)), "escalate", "photo, any case")
		-- in a market, the line's successor is the loadout's pitch reader (here
		-- certain to notice the small print)
		local sim = MarketSim.new({ seed = 6, n = 50, config = lib.config({ PITCH_SMALLPRINT = 1 }) })
		sim:setMonitor("rules")
		sim.fraudsPaused = true
		run(sim, 20)
		sim:drain()
		sim:setLoadout({ "pitchReader", "idCheck" })
		sim:addWatcher("w", { auto = true })
		local s = sim:injectFraud("counterfeit")
		local cc = sim.cases[s.case]
		A.ok(cc and cc.stage == "inbox", "escalated to the watcher")
		A.eq(cc.reason, "small print says \"print\"")
		run(sim, 12)
		A.eq(cc.stage, "done")
		A.eq(cc.verdict, "block", "the modelled watcher blocks it")
		A.eq(sim:meter().caught, 1)
	end)

	t.case("counterfeits are off by default; a share makes the fraud agents use them", function(A)
		local sim = MarketSim.new({ seed = 7, n = 300 })
		sim:setMonitor("rules")
		local evs = run(sim, 120)
		A.ok(not find(evs, function(e)
			return e.k == "stall" and e.s.display == "prints"
		end), "none by default")
		sim:setCounterfeitShare(1)
		local fakes = 0
		for _, s in sim.sellers do
			_ = s
		end
		local evs2 = run(sim, 60)
		local seen = {}
		for _, e in evs2 do
			if e.k == "stall" and e.s.display == "prints" and not seen[e.s.id] then
				seen[e.s.id] = true
				fakes += 1
			end
		end
		A.ok(fakes >= 4, "counterfeit stalls appear: " .. fakes)
	end)

	t.case("running totals survive mark(); honest deals carry their value", function(A)
		local sim = MarketSim.new({ seed = 8, n = 50 })
		sim:addWatcher("w", { auto = true })
		run(sim, 60)
		local a = sim:getTotals()
		sim:mark("reset the meter")
		run(sim, 30)
		local b = sim:getTotals()
		A.ok(b.honestDeals > a.honestDeals and a.honestDeals > 0, "deals keep counting")
		A.ok(b.honestValue > a.honestValue, "value keeps counting")
		A.ok(b.asked >= a.asked, "asked keeps counting")
		A.ok(sim:meter().deals < b.honestDeals, "the meter restarted, the totals did not")
	end)

	t.case("the phase table: the doc's 5:00 round, data-driven, with a scoreboard; phases unlock Red's attacks", function(A)
		A.ok(Round.validate(Config.ROUND_PHASES))
		local names, unlocks = {}, {}
		for _, p in Config.ROUND_PHASES do
			table.insert(names, string.format("%d %s", p.at, p.name))
			local u = p.set and p.set.unlock
			table.insert(unlocks, type(u) == "table" and table.concat(u, "+") or tostring(u))
		end
		A.eq(table.concat(names, ", "), "0 Calm, 60 Rush, 120 Lever, 180 Talkers, 240 Crew, 300 Scoreboard")
		A.eq(table.concat(unlocks, ", "), "scam, impostor, counterfeit+vouch, talker+stolenId, all, nil")
		A.eq(Config.ROUND_PHASES[1].set.n, 5, "Calm: 5 traders")
		A.eq(Config.ROUND_PHASES[2].set.n, 300, "Rush: 300 traders")
		A.eq(Config.ROUND_PHASES[3].prompt.ask, "vote", "Lever: the council votes on ID checks")
		A.eq(Config.ROUND_PHASES[4].set.llmShoppers, true, "Talkers: LLM shoppers")
		A.eq(Config.ROUND_PHASES[5].set.watchers, 2, "Crew: a second watcher")
		A.eq((Round.validate({ { at = 5, name = "x", scoreboard = true } })), false, "must start at 0")
		A.eq((Round.validate({ { at = 0, name = "a" }, { at = 10, name = "b" } })), false, "must end in a scoreboard")
		-- retuning is data: a 3-phase, 90 s round works the same way
		local cfg = lib.config({
			ROUND_PHASES = {
				{ at = 0, name = "A", set = { n = 50 } },
				{ at = 30, name = "B", set = { monitor = "rules" } },
				{ at = 90, name = "End", scoreboard = true },
			},
		})
		local sim = MarketSim.new({ seed = 1, n = 5, config = cfg })
		sim:addWatcher("w", { auto = true })
		local r = Round.new(cfg)
		r:start(sim.now, sim:getTotals())
		local entered = {}
		while not r.done do
			sim:step(0.25)
			for _, ph in r:update(sim.now, sim:getTotals(), #sim.watchers) do
				table.insert(entered, ph.phase.name)
				Round.apply(sim, ph.phase.set)
			end
		end
		A.eq(table.concat(entered, ","), "A,B,End")
		A.eq(sim.n, 50)
		A.eq(sim.monitor, "rules")
		A.eq(r.length, 90)
	end)

	t.case("a full 5:00 round headless with the bot Red: phases unlock attacks, the market grows, Blue sets a loadout, the scoreboard replays it", function(A)
		local sim = MarketSim.new({ seed = 20261106, n = 5 })
		sim:addWatcher("you", { auto = true })
		local r = Round.new(Config)
		r:start(sim.now, sim:getTotals())
		local entered, firstPromptAt, prompts = {}, nil, {}
		local firstKind = {} -- attack kind -> first time (s into the round) the bot opened one
		local scripted = 0
		local talkerEscapes, readerAt = 0, nil
		local watchersAt = {}
		while not r.done do
			sim:step(0.25)
			local el = r:elapsed(sim.now)
			for _, ph in r:update(sim.now, sim:getTotals(), #sim.watchers, sim:gameState()) do
				table.insert(entered, ph.phase.name)
				Round.apply(sim, ph.phase.set)
			end
			for _, p in r:prompt(sim.monitor) do
				if not prompts[p.ask] then
					prompts[p.ask] = el
				end
				if p.ask == "monitor" and not firstPromptAt then
					firstPromptAt = el
					-- Blue stops judging every case: the checks decide (the preset)
					sim:setMonitor("rules")
					r:answer(p.id)
				elseif p.ask == "vote" then
					r:answer(p.id) -- the council keeps ID checks
				end
			end
			for _, e in sim:drain() do
				if e.k == "stall" and e.s.state == "setup" or e.k == "rejected" then
					local s = sim.byId[e.k == "stall" and e.s.id or e.seller]
					if s and s.kind ~= "honest" then
						if s.owner == "bot" then
							firstKind[s.kind] = firstKind[s.kind] or el
						elseif not s.owner then
							scripted += 1
						end
					end
				end
				if e.k == "deal" and e.ok == false and e.kind == "talker" then
					talkerEscapes += 1
					-- a person reads the escapes and buys the pitch reader
					if not readerAt then
						readerAt = el
						sim:requestCheck("pitchReader", true)
					end
				end
			end
			watchersAt[math.floor(el / 60)] = #sim.watchers
		end
		A.eq(table.concat(entered, ","), "Calm,Rush,Lever,Talkers,Crew,Scoreboard")
		A.eq(scripted, 0, "in a round all fraud is Red's (here the bot's)")
		A.ok(firstKind.scam and firstKind.scam < 60, "scams from Calm")
		A.ok(firstKind.impostor and firstKind.impostor >= 60, "impostors from Rush: " .. tostring(firstKind.impostor))
		A.ok(firstKind.counterfeit == nil or firstKind.counterfeit >= 120, "counterfeits from Lever")
		A.ok(firstKind.talker == nil or firstKind.talker >= 180, "talkers from Talkers")
		A.eq(sim.n, 300, "the market grew")
		A.eq(watchersAt[4], 2, "Crew: two watchers")
		A.eq(watchersAt[1], 1)
		A.ok(firstPromptAt and firstPromptAt >= 60 and firstPromptAt < 150, "the prompt fires after Rush, at " .. tostring(firstPromptAt))
		A.ok(prompts.vote and prompts.vote >= 120 and prompts.vote < 121, "the council vote at 2:00")
		local sb = r.score
		A.ok(sb, "a scoreboard")
		A.ok(sb.honestDeals > 100, "honest deals " .. sb.honestDeals)
		A.ok(sb.frauds > 10, "the bot attacked: " .. sb.frauds)
		A.ok(sb.caught > 0)
		A.ok(sb.peak > 2 * Config.BUDGET, "peak calls/min over 2x budget: " .. sb.peak)
		A.between(#sb.chart, 150, 151, "a sample every 2 s")
		A.eq(#sb.series, #sb.chart, "the game's series beside it")
		A.eq(#sb.marks, 6)
		-- the series replays Blue's loadout against trade health and fraud
		local first, last = sb.series[1], sb.series[#sb.series]
		A.eq(table.concat(first.lo, ","), "idCheck", "Calm: the ID check alone")
		A.ok(table.find(last.lo, "priceFloor") and table.find(last.lo, "voucher"), "the preset by the end: " .. table.concat(last.lo, ","))
		A.ok(last.f >= 3, "friction rose: " .. last.f)
		A.ok(type(last.h) == "number" and last.h > 0, "trade health recorded")
		A.ok(last.st == sb.stolen and last.c <= sb.caught, "stolen and caught so far")
		A.near(sb.blue.score, sb.blue.fees - sb.blue.refunds + sb.blue.fines - sb.blue.costs, 2.01, "Blue's treasury adds up")
		A.near(sb.red.score, sb.red.stolen - sb.red.rent - sb.red.bought - sb.red.lost, 2.01, "Red's purse adds up")
		A.ok(sb.red.rent > 0, "Red paid rent")
		if readerAt then
			A.ok(readerAt >= 180, "talker escapes appear in Talkers")
			A.ok(table.find(last.lo, "pitchReader"), "the reader landed 30 s after Blue asked")
		end
		print(string.format(
			"      round (seed 20261106, auto watcher, checks at %.0f s): %d honest deals, %d frauds (caught %d, escaped %d), stolen %s, talker escapes %d (reader asked at %s), Blue %d, Red %d, last loadout %s (F%d, health %.2f)",
			firstPromptAt, sb.honestDeals, sb.frauds, sb.caught, sb.escaped, tostring(sb.stolen), talkerEscapes, tostring(readerAt),
			sb.blue.score, sb.red.score, table.concat(last.lo, "+"), last.f, last.h
		))
	end)
end
