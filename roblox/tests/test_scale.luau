-- The town at 5, 25 and 100 agents (RedBlue/Scale.luau, TownSim's crowd,
-- RedBot at scale), and the promise that the default game did not change.

local lib = require("./lib")
local Scale = (require :: any)("../src/shared/NandaTown/RedBlue/Scale")

-- events, threats and deals in `seconds` of a demo-mode round at `size`
local function demoRound(size: number, seconds: number, seed: number?, layers: { [string]: string }?)
	local g = lib.Game.new({ config = lib.Config, seed = seed or 1, layers = layers })
	g:start(0)
	g:setSize(size)
	local evs = lib.runGame(g, seconds)
	local town = lib.count(evs, function(e)
		return e.layer ~= "game"
	end)
	local threats = 0
	for _ in g.sim.threats do
		threats += 1
	end
	return { game = g, events = town, threats = threats, deals = g.sim.stats.dealsSettled, evs = evs }
end

-- the fingerprint of one default round (recorded on main at 80cffdb)
local function fingerprint(seed: number)
	local g = lib.Game.new({ config = lib.Config, seed = seed })
	g:start(0)
	local evs = lib.runGame(g, 200)
	local h = 0
	for _, e in evs do
		local s = e.kind .. "|" .. tostring(e.subject) .. "|" .. tostring(e.at)
		for i = 1, #s do
			h = (h * 31 + string.byte(s, i)) % 2147483647
		end
	end
	return #evs, h
end

return function(t)
	t.case("the default five-agent game is event-for-event what main played", function(A)
		local golden = { { 445, 1177445400 }, { 435, 796724916 }, { 453, 1940043516 } }
		for seed, want in golden do
			local n, h = fingerprint(seed)
			A.eq(n, want[1], "seed " .. seed .. " events")
			A.eq(h, want[2], "seed " .. seed .. " fingerprint")
		end
	end)

	t.case("population: 5 is the original cast, 25 and 100 add a crowd", function(A)
		local p5 = Scale.population(lib.Config, 5)
		A.eq(p5.size, 5)
		A.eq(table.concat(p5.sellers, ","), table.concat(lib.Config.SELLERS, ","))
		A.eq(table.concat(p5.buyers, ","), table.concat(lib.Config.BUYERS, ","))
		A.eq(next(p5.crowd), nil, "no crowd at 5")
		for _, n in { 25, 100 } do
			local p = Scale.population(lib.Config, n)
			A.eq(p.size, n)
			A.eq(#p.sellers, math.floor(n * 0.4 + 0.5), n .. " sellers")
			local seen = {}
			for _, name in p.sellers do
				A.ok(not seen[name], "unique " .. name)
				seen[name] = true
				A.between(p.price[name], 1895, 2195, name .. " price")
			end
			for _, name in p.buyers do
				A.ok(not seen[name], "unique " .. name)
				seen[name] = true
			end
		end
		A.eq(Scale.nextSize(lib.Config, 5), 25)
		A.eq(Scale.nextSize(lib.Config, 25), 100)
		A.eq(Scale.nextSize(lib.Config, 100), 5)
	end)

	t.case("traffic grows in proportion to the town", function(A)
		local r5 = demoRound(5, 125)
		local r25 = demoRound(25, 125)
		local r100 = demoRound(100, 125)
		A.between(r25.events / r5.events, 3.2, 6.5, "events 25 vs 5")
		A.between(r100.events / r5.events, 13, 26, "events 100 vs 5")
		A.between(r100.deals / math.max(r5.deals, 1), 10, 30, "deals 100 vs 5")
		-- ~132 events a minute at five agents (the paper's number)
		A.between(r5.events / 2, 100, 170, "events/min at 5")
	end)

	t.case("red's attack rate scales with the town", function(A)
		local r5 = demoRound(5, 125)
		local r25 = demoRound(25, 125)
		local r100 = demoRound(100, 125)
		A.between(r5.threats, 2, 6, "threats in 2 min at 5")
		A.between(r25.threats / r5.threats, 3, 7, "threats 25 vs 5")
		A.between(r100.threats / r5.threats, 12, 28, "threats 100 vs 5")
		-- every kind shows up at scale, the new fly-by-night stall included
		local kinds = {}
		for _, th in r100.game.sim.threats do
			kinds[th.kind] = (kinds[th.kind] or 0) + 1
		end
		A.ok((kinds.forge or 0) > 0 and (kinds.spoof or 0) > 0 and (kinds.bait or 0) > 0, "forge, spoof and bait all used")
		-- spoofs undercut the honest market, not each other (no $0.02 widgets)
		for _, c in r100.game.sim.cards do
			if c.threat then
				A.ok(c.price >= 1000, "a fake at a believable price: " .. c.price)
			end
		end
	end)

	t.case("the town grows live, and money is conserved at 100", function(A)
		local g = lib.Game.new({ config = lib.Config, seed = 4 })
		g:start(0)
		g:setSize(5) -- oversight on, a fresh round at 5
		local before = lib.runGame(g, 20)
		local start = lib.ledgerTotal(g.sim)
		g:setSize(100)
		local evs = lib.runGame(g, 80)
		local joined = {}
		for _, e in evs do
			if e.kind == "participant_joined" and e.detail.crowd then
				A.ok(not joined[e.subject], "joins once: " .. e.subject)
				joined[e.subject] = true
			end
		end
		local n = 0
		for _ in joined do
			n += 1
		end
		A.eq(n, 95, "95 newcomers")
		A.eq(g.sim:size(), 100)
		local opened = 0
		for _, e in evs do
			if e.kind == "account_opened" then
				opened += e.detail.balance_cents
			end
		end
		A.eq(lib.ledgerTotal(g.sim), start + opened, "money conserved as the town grows")
		A.ok(#before > 0)
		-- a smaller town is a fresh round
		local round = g.round
		g:setSize(25)
		A.eq(g.round, round + 1)
		A.eq(g.sim:size(), 25)
	end)

	t.case("a fly-by-night stall passes every layer and pays red with an empty crate", function(A)
		local STRONG = { auth = "hmac.v1", registry = "index.owned.v1", transport = "memory.v1" }
		local sim = lib.TownSim.new({ config = lib.quiet(), layers = STRONG, seed = 9, size = 25 })
		sim:start()
		lib.run(sim, 20)
		local total = lib.ledgerTotal(sim)
		local th = sim:bait(0.25)
		A.eq(th.state, "live", "no layer stops it")
		local evs = lib.run(sim, 120)
		local card = lib.first(evs, function(e)
			return e.kind == "card_registered" and e.subject == th.claimed
		end)
		A.ok(card == nil or card.detail.verified, "listed as verified")
		A.eq(th.state, "escaped", "a buyer bit")
		local bad = lib.first(evs, function(e)
			return e.kind == "receipt_attested" and e.subject == th.claimed
		end)
		A.ok(bad and bad.detail.value == "bad", "the crate was empty")
		A.eq(lib.ledgerTotal(sim), total, "money conserved")
	end)

	t.case("the sampler draws the five, cards and attacks, and a few of the crowd", function(A)
		local r = demoRound(100, 90)
		local f = Scale.Filter.new(lib.Config, r.game.sim.pop)
		local shown = {}
		for _, e in r.evs do
			if f:keep(e) then
				table.insert(shown, e)
			end
		end
		A.between(f.shown / f.total, 0.1, 0.5, "a fraction is drawn")
		for _, e in r.evs do
			if e.layer == "game" or e._threat or string.sub(e.kind, 1, 5) == "card_" or e.kind == "participant_joined" then
				A.ok(f:decide(e), "always drawn: " .. e.kind)
			end
		end
		-- an unlit crowd buyer's deal is not drawn; a core buyer's is
		local dark = Scale.buyerName(#lib.Config.BUYERS + lib.Config.CROWD_LIT + 5)
		A.eq(f:decide({ kind = "registry_lookup", observer = dark, layer = "registry", detail = {} }), false)
		A.eq(f:decide({ kind = "registry_lookup", observer = "buyer-1", layer = "registry", detail = {} }), true)
		A.eq(f:decide({ kind = "escrow_released", subject = "order-" .. dark .. "-2", observer = "town", layer = "payments", detail = { to = "seller-a" } }), false)
	end)

	t.case("crowd slots never overlap each other or the five", function(A)
		local taken = {}
		local function key(x: number, z: number)
			return string.format("%d,%d", math.floor(x + 0.5), math.floor(z + 0.5))
		end
		for _, role in { "seller", "buyer" } do
			local n = role == "seller" and 40 or 60
			for k = 1, n do
				local x, z = Scale.slot(role, k)
				A.ok(not taken[key(x, z)], role .. " slot " .. k .. " is free")
				taken[key(x, z)] = true
				for _, core in { { -20, -16 }, { 20, -16 }, { -40, 26 }, { 0, 26 }, { 40, 26 } } do
					A.ok(math.abs(x - core[1]) > 5 or math.abs(z - core[2]) > 5, role .. " slot " .. k .. " clear of the five")
				end
				A.ok(z < 3 or z > 13, role .. " slot " .. k .. " off the road")
			end
		end
	end)
end
