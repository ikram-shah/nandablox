-- The game (docs/market-game.md): Blue's loadout, friction, Red's attacks,
-- the signals each side sees, the bot Red, scoring. Every row of the doc's
-- "beats / caught by" table is a case below.

local lib = require("./lib")
local MarketSim = lib.MarketSim
local Config = lib.Config
local Loadout = (require :: any)("../../src/market/shared/Market/Loadout")
local RedBot = (require :: any)("../../src/market/shared/Market/RedBot")
local Score = (require :: any)("../../src/market/shared/Market/Score")

local function run(sim, seconds: number, evs)
	local stop = sim.now + seconds
	while sim.now < stop - 1e-9 do
		sim:step(0.25)
		for _, e in sim:drain() do
			if evs then
				table.insert(evs, e)
			end
		end
	end
	return evs
end

-- a 50-trader market where the only fraud is the one we open; the loadout
-- decides listings ("rules"); nobody at the inbox unless `watcher`
local function market(list: { string }, opts)
	opts = opts or {}
	local cfg = lib.config(opts.config or {})
	local sim = MarketSim.new({ seed = opts.seed or 7, n = opts.n or 50, config = cfg })
	sim.fraudsPaused = true
	run(sim, 20)
	sim:setMonitor("rules")
	sim:setLoadout(list)
	if opts.watcher then
		sim:addWatcher("w", { auto = true })
	end
	sim:drain()
	return sim
end

-- Open one attack against a loadout and follow it to its outcome.
-- Returns { checks = set of check ids that escalated it, twin, outcome, stolen, s }
local function trial(kind: string, mods, list: { string }, opts)
	local sim = market(list, opts)
	local o = table.clone(mods or {})
	o.good = o.good or "cloth"
	local s = assert(sim:redAttack("red", kind, o))
	local checks, twin, inbox = {}, false, false
	local c = s.case and sim.cases[s.case]
	if c then
		for _, r in c.checks or {} do
			checks[r.check] = true
		end
		twin = c.twin
		inbox = c.stage == "inbox"
	end
	local t = 0
	while not s.outcome and t < 150 do
		run(sim, 1)
		t += 1
	end
	return { checks = checks, twin = twin, inbox = inbox, outcome = s.outcome, stolen = s.stolen or 0, s = s, sim = sim }
end

-- caught by one check alone: the doc's verb for it
local function caughtBy(A, kind: string, mods, check: string, label: string)
	local cfg = check == "inspector" and { INSPECT_SHARE = 1 } or (check == "pitchReader" and { PITCH_SMALLPRINT = 1 } or {})
	local r = trial(kind, mods, { check }, { config = cfg })
	local act = Config.CHECKS
	local want
	for _, c in act do
		if c.id == check then
			want = c.act
		end
	end
	if want == "escalate" then
		A.ok(r.checks[check], label .. ": " .. check .. " sends it to the inbox")
		A.ok(r.inbox, label .. ": it waits for a person")
	elseif want == "reject" then
		A.eq(r.outcome, "rejected", label .. ": " .. check)
	elseif want == "shut" then
		A.eq(r.outcome, "inspected", label .. ": " .. check)
	elseif want == "refund" then
		A.eq(r.outcome, "refunded", label .. ": " .. check)
		A.eq(r.stolen, 0, label .. ": nothing stolen under escrow")
	end
	return r
end

-- beats one check alone: that check never acts on it, and (nobody at the
-- inbox) it is paid out unless something else - two stalls with one name -
-- puts it in front of a person
local function beats(A, kind: string, mods, check: string, label: string)
	local cfg = check == "inspector" and { INSPECT_SHARE = 1 } or (check == "pitchReader" and { PITCH_SMALLPRINT = 1 } or {})
	local r = trial(kind, mods, { check }, { config = cfg })
	A.ok(not r.checks[check], label .. " beats " .. check .. ": not escalated by it")
	A.eq(r.outcome, "paid", label .. " beats " .. check .. ": paid out")
	return r
end

local function count(t): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

return function(t)
	------------------------------------------------------------------ the loadout

	t.case("the six checks with the doc's friction: floor 0, voucher 1, ID 2, reader 1 + compute, inspector 3, escrow 4", function(A)
		local want = { priceFloor = 0, voucher = 1, idCheck = 2, pitchReader = 1, inspector = 3, escrow = 4 }
		A.eq(#Config.CHECKS, 6)
		for _, c in Config.CHECKS do
			A.eq(c.friction, want[c.id], c.id)
		end
		A.eq(Loadout.check("pitchReader").compute, true, "the reader costs compute $")
		A.eq(Loadout.friction(Loadout.from({ "priceFloor", "voucher", "idCheck", "pitchReader", "inspector", "escrow" })), 11)
		local acts = {}
		for _, c in Config.CHECKS do
			acts[c.id] = c.act
		end
		A.eq(acts.priceFloor, "escalate")
		A.eq(acts.voucher, "escalate")
		A.eq(acts.idCheck, "reject")
		A.eq(acts.pitchReader, "escalate")
		A.eq(acts.inspector, "shut")
		A.eq(acts.escrow, "refund")
	end)

	t.case("the signature lever is the ID check; the rules monitor is the preset price floor + voucher", function(A)
		local sim = MarketSim.new({ seed = 1, n = 50 })
		A.eq(sim.loadout.idCheck, true, "signatures on by default = ID check in the loadout")
		sim:setSignatures(false)
		A.eq(sim.loadout.idCheck, false)
		A.eq(sim.signatures, false)
		sim:setCheck("idCheck", true)
		A.eq(sim.signatures, true, "and the other way round")
		sim:setMonitor("rules")
		A.eq(table.concat(Loadout.list(sim.loadout), ","), "priceFloor,voucher,idCheck")
		A.eq(sim:friction(), 3)
		-- a loadout that already has a listing check keeps it
		sim:setLoadout({ "pitchReader" })
		sim:setMonitor("off")
		sim:setMonitor("rules")
		A.eq(table.concat(Loadout.list(sim.loadout), ","), "pitchReader")
	end)

	------------------------------------------------------------------ beats / caught by

	t.case("scam stall: beats ID check, pitch reader; caught by price floor, voucher, inspector, escrow", function(A)
		beats(A, "scam", nil, "idCheck", "scam")
		beats(A, "scam", nil, "pitchReader", "scam")
		caughtBy(A, "scam", nil, "priceFloor", "scam")
		caughtBy(A, "scam", nil, "voucher", "scam")
		caughtBy(A, "scam", nil, "inspector", "scam")
		caughtBy(A, "scam", nil, "escrow", "scam")
	end)

	t.case("impostor: beats price floor, voucher, inspector; caught by ID check, a human spotting two stalls with one name", function(A)
		for _, chk in { "priceFloor", "voucher", "inspector" } do
			local cfg = chk == "inspector" and { INSPECT_SHARE = 1 } or {}
			local r = trial("impostor", nil, { chk }, { config = cfg })
			A.ok(not r.checks[chk], "impostor beats " .. chk)
			A.ok(r.outcome ~= "inspected" and r.outcome ~= "rejected", "impostor beats " .. chk .. ": " .. tostring(r.outcome))
		end
		caughtBy(A, "impostor", nil, "idCheck", "impostor")
		-- with no ID check, the twin is visible: both stalls go to a person, who blocks it
		local r = trial("impostor", nil, {}, { watcher = true, seed = 3 })
		A.ok(r.twin and r.inbox, "two stalls, one name: in the inbox with no check at all")
		A.ok(r.outcome == "blocked" or r.outcome == "paid", "a person decides: " .. tostring(r.outcome))
		-- a person who blocks it: blocked
		local sim = market({})
		sim:addWatcher("me")
		local s = assert(sim:redAttack("red", "impostor", {}))
		A.ok(sim:verdict("me", s.case, "block"))
		A.eq(s.outcome, "blocked")
		-- escrow does not catch it: its goods arrive (it steals the name's custom)
		local e = trial("impostor", nil, { "escrow" })
		A.eq(e.outcome, "paid", "escrow: the goods arrived")
		A.ok(e.stolen > 0, "and the sale is stolen from the name's owner")
	end)

	t.case("counterfeit: beats price floor, ID check; caught by voucher, inspector, escrow, pitch reader (sometimes)", function(A)
		beats(A, "counterfeit", nil, "priceFloor", "counterfeit")
		beats(A, "counterfeit", nil, "idCheck", "counterfeit")
		caughtBy(A, "counterfeit", nil, "voucher", "counterfeit")
		caughtBy(A, "counterfeit", nil, "inspector", "counterfeit")
		caughtBy(A, "counterfeit", nil, "escrow", "counterfeit")
		caughtBy(A, "counterfeit", nil, "pitchReader", "counterfeit (reader notices the small print)")
		-- sometimes: the reader notices the small print about PITCH_SMALLPRINT of the time
		local sim = market({ "pitchReader" }, { n = 300 })
		MarketSim.ledgerFor(sim, "red").purse = 1e9 -- (forty stalls: more than a stake buys)
		local hit, n = 0, 0
		for i = 1, 40 do
			local s = sim:redAttack("red", "counterfeit", {})
			if s then
				n += 1
				-- (an allowed listing's case closes at once; an escalated one waits)
				if s.case then
					for _, r in sim.cases[s.case].checks or {} do
						if r.check == "pitchReader" then
							hit += 1
						end
					end
				end
			end
		end
		A.ok(n >= 30, "trials: " .. n)
		A.between(hit / n, 0.25, 0.75, "sometimes")
	end)

	t.case("smooth talker: beats price floor, ID check, inspector; caught by voucher, escrow, pitch reader", function(A)
		beats(A, "talker", nil, "priceFloor", "talker")
		beats(A, "talker", nil, "idCheck", "talker")
		local r = beats(A, "talker", nil, "inspector", "talker")
		A.eq(r.s.inspectedOk, true, "the inspector visited and was talked round")
		caughtBy(A, "talker", nil, "voucher", "talker")
		caughtBy(A, "talker", nil, "escrow", "talker")
		local p = caughtBy(A, "talker", nil, "pitchReader", "talker")
		A.ok(type(p.s.pitch) == "string" and Loadout.says(p.s.pitch) ~= nil, "a scripted pitch the reader catches by keyword: " .. tostring(p.s.pitch))
		-- with the default small-print odds, a talker is still caught every time (it is the pitch, not the small print)
		local sim = market({ "pitchReader" }, { n = 300 })
		for i = 1, 10 do
			local s = assert(sim:redAttack("red", "talker", {}))
			A.ok(sim.cases[s.case].checks[1].check == "pitchReader", "always")
		end
	end)

	t.case("bought vouch: beats voucher; caught by whatever else matches", function(A)
		for _, kind in { "scam", "counterfeit", "talker" } do
			beats(A, kind, { vouch = true }, "voucher", kind .. " + vouch")
		end
		local r = trial("scam", { vouch = true }, { "voucher", "priceFloor" })
		A.ok(r.checks.priceFloor and not r.checks.voucher, "a vouched scam is still too cheap")
		caughtBy(A, "counterfeit", { vouch = true }, "escrow", "counterfeit + vouch")
		caughtBy(A, "talker", { vouch = true }, "pitchReader", "talker + vouch")
		caughtBy(A, "scam", { vouch = true }, "inspector", "scam + vouch")
	end)

	t.case("stolen ID: beats ID check; caught by whatever else matches", function(A)
		local r = trial("impostor", { stolenId = true }, { "idCheck" })
		A.ok(r.outcome ~= "rejected", "not rejected: " .. tostring(r.outcome))
		A.ok(r.twin, "but two stalls with one name still meet a person")
		local sim = market({ "idCheck" })
		sim:addWatcher("me")
		local s = assert(sim:redAttack("red", "impostor", { stolenId = true }))
		A.eq(sim.cases[s.case].signature, "valid", "the stolen key signs")
		A.ok(sim:verdict("me", s.case, "block"))
		A.eq(s.outcome, "blocked")
		-- a stolen ID on a stall that signs its own name buys nothing
		local w = trial("scam", { stolenId = true }, { "idCheck", "priceFloor" })
		A.ok(w.checks.priceFloor, "the price floor still sees the scam")
	end)

	t.case("no column covers every row; buying every check seizes the market", function(A)
		local all = { "priceFloor", "voucher", "idCheck", "pitchReader", "inspector", "escrow" }
		-- each check alone lets something through
		local probes = {
			{ "scam", {} }, { "impostor", {} }, { "counterfeit", {} }, { "talker", {} },
			{ "scam", { vouch = true } }, { "impostor", { stolenId = true } },
		}
		for _, chk in all do
			local through = false
			for _, p in probes do
				local cfg = chk == "inspector" and { INSPECT_SHARE = 1 } or {}
				local r = trial(p[1], p[2], { chk }, { config = cfg })
				if not r.checks[chk] and r.outcome == "paid" then
					through = true
					break
				end
			end
			A.ok(through, chk .. " alone lets something through")
		end
		A.eq(Loadout.band(Loadout.friction(Loadout.from(all))).name, "seized")
	end)

	------------------------------------------------------------------ friction

	t.case("friction thresholds: 0-6 healthy, 7-9 slow, 10+ seized", function(A)
		for f = 0, 6 do
			A.eq(Loadout.band(f).name, "healthy", "F=" .. f)
			A.eq(Loadout.band(f).stay, 1)
		end
		for f = 7, 9 do
			A.eq(Loadout.band(f).name, "slow", "F=" .. f)
			A.ok(Loadout.band(f).stay < 1, "honest sellers start leaving at " .. f)
		end
		for _, f in { 10, 11, 14 } do
			A.eq(Loadout.band(f).name, "seized", "F=" .. f)
		end
		-- every unit slows listings and trades
		for f = 1, 12 do
			A.ok(Loadout.band(f).payS > Loadout.band(f - 1).payS, "payments slower at " .. f)
			A.ok(Loadout.band(f).listS > Loadout.band(f - 1).listS, "listings slower at " .. f)
		end
	end)

	t.case("trade health: ~1 at zero friction, falls with friction; slow loses honest sellers; seized all but stops", function(A)
		local function measure(list)
			local h, sellers = 0, 0
			for seed = 1, 2 do
				local sim = MarketSim.new({ seed = seed, n = 300 })
				sim.fraudsPaused = true
				sim:setMonitor("rules")
				sim:setLoadout(list)
				run(sim, 150)
				h += sim:tradeHealth()
				local k = 0
				for _, s in sim.sellers do
					if s.kind == "honest" and (s.state == "open" or s.state == "restock" or s.state == "setup") then
						k += 1
					end
				end
				sellers += k
			end
			return h / 2, sellers / 2
		end
		local want = MarketSim.sellersFor(300)
		local h0, s0 = measure({})
		local h6, s6 = measure({ "idCheck", "escrow" })
		local h8, s8 = measure({ "voucher", "inspector", "escrow" })
		local h10 = measure({ "voucher", "idCheck", "inspector", "escrow" })
		print(string.format("      trade health at 300: F0 %.2f (%d stalls), F6 %.2f (%d), F8 %.2f (%d), F10 %.2f; %d stalls wanted", h0, s0, h6, s6, h8, s8, h10, want))
		A.between(h0, 0.85, 1.15, "zero friction is the baseline")
		A.ok(h6 < h0 and h6 > 0.6, "healthy: a little slower")
		A.ok(h8 < h6, "slow")
		A.ok(s8 < 0.85 * want, "honest sellers leave at 8: " .. s8)
		A.ok(s6 > 0.9 * want, "but not at 6: " .. s6)
		A.ok(h10 < 0.3, "seized: " .. h10)
	end)

	t.case("a loadout change takes 30 s to take effect (the council's ID vote too)", function(A)
		A.eq(Config.LOADOUT_DELAY_S, 30)
		local sim = market({ "idCheck" })
		local t0 = sim.now
		sim:requestCheck("escrow", true)
		sim:requestCheck("idCheck", false)
		A.eq(sim.loadout.escrow, false, "not yet")
		A.eq(sim:friction(), 2)
		local g = sim:gameState()
		A.eq(#g.pending, 2, "two changes on their way")
		-- 10 s in: an impostor is still rejected, a scam still gets paid
		run(sim, 10)
		local imp = assert(sim:redAttack("red", "impostor", {}))
		A.eq(imp.outcome, "rejected", "the ID check still runs")
		run(sim, 19.5)
		A.eq(sim.loadout.escrow, false, "29.5 s: still not")
		run(sim, 0.75)
		A.ok(sim.now - t0 >= 30 and sim.loadout.escrow, "30 s: escrow is in")
		A.eq(sim.loadout.idCheck, false, "and the ID check is out")
		A.eq(sim.signatures, false)
		A.eq(sim:friction(), 4)
		A.eq(#sim:gameState().pending, 0)
		-- asking again for what is in effect cancels a change on its way
		sim:requestCheck("escrow", false)
		sim:requestCheck("escrow", true)
		A.eq(#sim:gameState().pending, 0)
	end)

	------------------------------------------------------------------ signals

	t.case("signals: each Red fraud resolves to exactly one of the five coarse outcomes; Red sees its own log", function(A)
		local seen = {}
		local labels = {}
		for _, o in Config.OUTCOMES do
			labels[o.id] = true
		end
		local per = {}
		local loadouts = {
			{ "idCheck" }, { "priceFloor", "voucher" }, { "inspector" }, { "escrow" }, {},
		}
		for i, list in loadouts do
			local sim = market(list, { seed = 40 + i, n = 300, watcher = true, config = { INSPECT_SHARE = 1 } })
			sim:setUnlocked(nil)
			sim:setRedBot(true, 12)
			local evs = run(sim, 240, {})
			sim:setRedBot(false)
			run(sim, Config.FRAUD_LIFETIME + 30, evs) -- everything open finishes
			for _, e in evs do
				if e.k == "outcome" then
					A.ok(labels[e.outcome], "a known outcome: " .. tostring(e.outcome))
					local key = i .. ":" .. e.seller
					A.eq(per[key], nil, "exactly one outcome for " .. key)
					per[key] = e.outcome
					seen[e.outcome] = true
				end
			end
			-- every bot stall has its outcome, and its ledger agrees
			local l = sim.red.bot
			A.ok(l and l.stalls > 10, "the bot opened stalls")
			local sum = 0
			for _, v in l.outcomes do
				sum += v
			end
			A.eq(sum, l.stalls, "one outcome per stall in the ledger")
			A.ok(#l.log > 0 and l.log[#l.log].outcome ~= nil, "Red's log")
		end
		for _, o in Config.OUTCOMES do
			A.ok(seen[o.id], "seen: " .. o.label)
		end
	end)

	t.case("signals: Blue sees escapes with their type; catches with what caught them", function(A)
		local sim = market({}, { n = 300 })
		local c = assert(sim:redAttack("red", "counterfeit", {}))
		local tk = assert(sim:redAttack("red", "talker", {}))
		local sc = assert(sim:redAttack("red", "scam", {}))
		local evs = run(sim, 90, {})
		local texts = {}
		for _, e in sim.escapeLog do
			texts[e.kind] = e.text
		end
		A.ok(texts.counterfeit and string.match(texts.counterfeit, "^counterfeit delivered to buyer %d+$"), tostring(texts.counterfeit))
		A.ok(texts.talker and string.match(texts.talker, "^buyer %d+ talked into buying a print$"), tostring(texts.talker))
		A.ok(texts.scam and string.find(texts.scam, "delivered nothing", 1, true), tostring(texts.scam))
		local dealKinds = {}
		for _, e in evs do
			if e.k == "deal" and not e.ok then
				dealKinds[e.kind] = e.text
			end
		end
		A.ok(dealKinds.counterfeit and dealKinds.talker and dealKinds.scam, "the deal event carries the type")
		_ = c
		_ = tk
		_ = sc
		local sim2 = market({ "escrow" }, { n = 300 })
		local s2 = assert(sim2:redAttack("red", "scam", {}))
		run(sim2, 60)
		A.eq(s2.outcome, "refunded")
		A.eq(sim2.catchLog[#sim2.catchLog].by, "escrow")
		A.eq(sim2.catchLog[#sim2.catchLog].kind, "scam")
	end)

	t.case("signs: free, for any check whether or not it runs, and Red sees them", function(A)
		local sim = market({ "priceFloor" })
		local f = sim:friction()
		A.ok(sim:setSign("escrow", true), "a sign for a check Blue does not run")
		A.ok(sim:setSign("priceFloor", true))
		A.eq(sim:setSign("dragons", true), false, "only checks")
		A.eq(sim:friction(), f, "signs are free")
		A.eq(table.concat(sim:gameState().signs, ","), "priceFloor,escrow")
		A.eq(sim.loadout.escrow, false, "a sign is not a check")
		local r = trial("scam", nil, { "voucher" })
		_ = r
		sim:setSign("escrow", false)
		A.eq(table.concat(sim:gameState().signs, ","), "priceFloor")
	end)

	------------------------------------------------------------------ the bot Red

	t.case("bot Red: success rates, mostly the best, sometimes something else", function(A)
		local rng = lib.Rng.new(5)
		local bot = RedBot.new(Config, rng)
		for _ = 1, 10 do
			bot:record("talker", true)
			bot:record("scam", false)
		end
		A.ok(bot:rate("talker") > 0.8 and bot:rate("scam") < 0.2)
		local picks = {}
		for _ = 1, 400 do
			local a = bot:choose(nil)
			picks[a.id] = (picks[a.id] or 0) + 1
		end
		A.between(picks.talker / 400, 0.75, 0.9, "exploits the best")
		A.ok(count(picks) >= 5, "explores the others")
		-- only what is unlocked
		for _ = 1, 50 do
			local a = bot:choose({ scam = true, impostor = true })
			A.ok(a.kind == "scam" or a.kind == "impostor", a.id)
			A.ok(not a.vouch and not a.stolenId, "no modifiers until they unlock")
		end
	end)

	local function drift(list: { string }, opts)
		local sim = market(list, { seed = opts.seed, n = 300, watcher = opts.watcher, config = opts.config })
		sim:setUnlocked(nil)
		sim:setRedBot(true, 10)
		local early, late = {}, {}
		run(sim, opts.minutes * 60)
		local h = sim.bot.history
		local cut = math.floor(#h / 3)
		for i, id in h do
			local bucket = i <= cut and early or (i > #h - cut and late or nil)
			if bucket then
				bucket[id] = (bucket[id] or 0) + 1
			end
		end
		return early, late, cut, sim
	end

	t.case("bot Red drifts to the gap: talker + vouch against floor, voucher, ID, inspector", function(A)
		local early, late, cut, sim = drift({ "priceFloor", "voucher", "idCheck", "inspector" }, {
			seed = 11, minutes = 10, watcher = true, config = { INSPECT_SHARE = 1 },
		})
		local e, l = (early["talker+vouch"] or 0) / cut, (late["talker+vouch"] or 0) / cut
		print(string.format("      gap talker+vouch: first third %.0f%%, last third %.0f%% of %d attacks", e * 100, l * 100, #sim.bot.history))
		A.ok(l > 0.5, "mostly the gap by the end: " .. l)
		A.ok(l > e, "more than at the start")
		local best, bestR = nil, -1
		for _, r in sim.bot:rates() do
			if r.rate > bestR then
				best, bestR = r.id, r.rate
			end
		end
		A.eq(best, "talker+vouch", "its best rate")
	end)

	t.case("bot Red drifts to a different gap for a different loadout: impostor + stolen ID against escrow + ID, nobody at the inbox", function(A)
		local early, late, cut, sim = drift({ "idCheck", "escrow" }, { seed = 12, minutes = 10 })
		local e, l = (early["impostor+id"] or 0) / cut, (late["impostor+id"] or 0) / cut
		print(string.format("      gap impostor+id: first third %.0f%%, last third %.0f%% of %d attacks", e * 100, l * 100, #sim.bot.history))
		A.ok(l > 0.5, "mostly the gap by the end: " .. l)
		A.ok(l > e, "more than at the start")
	end)

	------------------------------------------------------------------ money (Nandabux)

	t.case("Red's purse: a stake, a deposit and rent per stall, purchases; the deposit back if uncaught, forfeit (Blue's fine) if caught", function(A)
		A.eq(Config.RED_STAKE, 15000, "150 NB")
		local sim = market({}, { n = 300 })
		local s = assert(sim:redAttack("red", "talker", { vouch = true, good = "lamp" }))
		local l = sim.red.red
		A.eq(l.bought, 400 + 600, "ads + vouch")
		A.eq(l.purse, Config.RED_STAKE - 1000 - Config.STALL_DEPOSIT, "paid out of the purse, deposit held")
		local live = 0
		while not s.outcome and live < 150 do
			run(sim, 0.25)
			live += 0.25
		end
		A.eq(s.outcome, "paid", "nothing caught it")
		A.near(l.rent, Config.RENT_PER_MIN * live / 60, 3, "rent per minute while it traded")
		A.near(l.purse, Config.RED_STAKE - 1000 - l.rent + l.stolen, 1, "deposit back, loot kept")
		A.eq(l.lost, 0)
		-- caught: the deposit is forfeit, and it is Blue's fine
		local sim2 = market({ "escrow" }, { n = 300 })
		local f0 = sim2:getTotals().blueFines
		local s2 = assert(sim2:redAttack("red", "scam", { stolenId = true }))
		run(sim2, 60)
		A.eq(s2.outcome, "refunded")
		local l2 = sim2.red.red
		A.eq(l2.lost, Config.STALL_DEPOSIT, "deposit forfeit")
		A.eq(sim2:getTotals().blueFines - f0, Config.STALL_DEPOSIT, "Blue's fine")
		A.eq(l2.bought, 1000, "the stolen ID was money wasted")
		local sc = Score.ledger(l2)
		A.near(sc.score, l2.stolen - l2.rent - l2.bought - l2.lost, 1)
		A.ok(sc.score < 0, "a caught stall loses money")
		-- a purse that can't pay doesn't open a stall
		local sim3 = market({}, { n = 300 })
		MarketSim.ledgerFor(sim3, "poor").purse = 500
		local none, why = sim3:redAttack("poor", "scam", {})
		A.eq(none, nil)
		A.eq(why, "can't afford it")
	end)

	t.case("Blue's treasury: fees on honest deals - refunds + fines - check costs; no friction penalty of its own", function(A)
		local b = Score.blue({ blueFees = 10000, blueRefunds = 1800, blueFines = 1000, blueCosts = 2500, compute = 300 })
		A.eq(b.score, 10000 - 1800 + 1000 - 2500)
		local r = Score.red({ redStolen = 5000, redRent = 300, redPurchases = 1000, redLost = 600 })
		A.eq(r.score, 3100)
		A.eq(Score.winner(b.score, r.score), "blue")
		-- in a market: fees are FEE_SHARE of honest value; refunds REFUND_FACTOR x stolen
		local sim = market({ "idCheck" }, { n = 300 })
		local a = sim:getTotals()
		local sc = assert(sim:redAttack("red", "scam", { good = "cloth" }))
		run(sim, 60)
		local z = sim:getTotals()
		A.near(z.blueFees - a.blueFees, (z.honestValue - a.honestValue) * Config.FEE_SHARE, 1, "fees")
		A.ok(sc.stolen and sc.stolen > 0, "the scam was paid")
		A.near(z.blueRefunds - a.blueRefunds, (z.stolen - a.stolen) * Config.REFUND_FACTOR, 1, "buyer protection")
		A.eq(z.blueCosts - a.blueCosts, 0, "an ID check costs friction, not money")
		-- the checks that cost money, per minute
		local sim2 = market({ "inspector", "escrow" }, { n = 300 })
		local c0 = sim2:getTotals().blueCosts
		run(sim2, 60)
		A.near(sim2:getTotals().blueCosts - c0, Config.CHECK_COST_PER_MIN.inspector + Config.CHECK_COST_PER_MIN.escrow, 2, "wages + overhead, a minute")
		local sim3 = market({ "pitchReader" }, { n = 300 })
		local k0 = sim3:getTotals().blueCosts
		run(sim3, 30)
		A.ok(sim3:getTotals().blueCosts > k0, "every listing the reader reads costs compute")
		A.ok(sim3:gameState().compute > 0, "Blue sees its compute spend")
	end)

	t.case("a false alarm costs Blue: the blocked honest seller packs up, and its fees go with it", function(A)
		local function fees(blockHonest: boolean)
			local sim = MarketSim.new({ seed = 21, n = 300 })
			sim.fraudsPaused = true
			sim:setMonitor("off") -- every listing reaches the watcher
			sim:addWatcher("me")
			run(sim, 20)
			local f0 = sim:getTotals().blueFees
			for _ = 1, 120 do
				run(sim, 1)
				for _, c in sim.caseList do
					if c.stage == "inbox" then
						sim:verdict("me", c.id, blockHonest and "block" or "allow")
					end
				end
			end
			return sim:getTotals().blueFees - f0, sim:meter().falseAlarms
		end
		local keep = fees(false)
		local lose, alarms = fees(true)
		print(string.format("      fees over 2 min at 300: allow every newcomer %.0f NB, block every one %.0f NB (%d false alarms)", keep / 100, lose / 100, alarms))
		A.ok(alarms > 20, "false alarms: " .. alarms)
		A.ok(lose < keep * 0.95, "blocking honest sellers costs fees")
	end)

	------------------------------------------------------------------ balance

	local Ghost = (require :: any)("../../src/market/shared/Market/Ghost")
	t.case("balance, seeded, a full round against the bot Red: no checks loses, every check loses, floor + voucher + inspector wins", function(A)
		for seed = 1, 3 do
			local none = Ghost.play(seed, Ghost.NONE)
			local all = Ghost.play(seed, Ghost.ALL)
			local ok = Ghost.play(seed, Ghost.SENSIBLE)
			print(string.format(
				"      seed %d (NB, Blue vs Red): no checks %.0f vs %.0f · every check %.0f vs %.0f · floor+voucher+inspector %.0f vs %.0f",
				seed, none.blue / 100, none.red / 100, all.blue / 100, all.red / 100, ok.blue / 100, ok.red / 100
			))
			A.eq(none.winner, "red", "seed " .. seed .. ": no checks, refunds eat the fees")
			A.eq(all.winner, "red", "seed " .. seed .. ": every check, the market seizes")
			A.eq(ok.winner, "blue", "seed " .. seed .. ": a sensible loadout wins")
			A.ok(all.honestDeals < ok.honestDeals * 0.5, "seized: fees dry up")
			A.ok(none.refunds > none.fees * 0.5, "no checks: refunds eat the fees")
		end
	end)
end
