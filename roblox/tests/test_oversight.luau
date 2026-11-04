-- Oversight: judgment calls, the monitors' filter-and-escalate, the human on
-- an attention budget, and the HUD's numbers (RedBlue/Oversight.luau).

local lib = require("./lib")
local Oversight = (require :: any)("../src/shared/NandaTown/RedBlue/Oversight")

local PLAIN = { auth = "plain.v1", registry = "index.v1", transport = "memory.v1" }

-- a demo round: `size` agents, monitors on or off, `seconds` long; the
-- metrics are read over the last `measure` seconds (a fresh setting)
local function demo(size: number, monitors: boolean, seconds: number, seed: number?, layers: { [string]: string }?)
	local g = lib.Game.new({ config = lib.Config, seed = seed or 1, layers = layers })
	g:start(0)
	g:setSize(size)
	g:setMonitors(monitors)
	lib.runGame(g, 30) -- warm up, then measure a clean setting
	g.oversight:mark(g:rt(), "measured")
	lib.runGame(g, 30 + seconds)
	return g, g:oversightMetrics()
end

local function sum(...)
	local s = 0
	for _, v in { ... } do
		s += v
	end
	return s
end

return function(t)
	t.case("the monitors' rules: caught, cleared, or escalated", function(A)
		local o = Oversight.new({ config = lib.Config, layers = { auth = "hmac.v1" } })
		local function v(c)
			return (o:classify(c))
		end
		A.eq(v({ kind = "invoice", origin = "gate", payTo = "sellr-b", payeeListed = false }), "catch", "from the gate")
		A.eq(v({ kind = "invoice", origin = "red-team", payTo = "seller-a", payeeListed = true }), "catch", "from another stall")
		A.eq(v({ kind = "invoice", payTo = "se11er-b", payeeListed = false }), "catch", "payee not on the board")
		A.eq(v({ kind = "invoice", payTo = "seller-a", payeeListed = true }), "clear", "an honest invoice")
		A.eq(v({ kind = "card", verified = false, price = 1600, market = 2000 }), "catch", "UNVERIFIED")
		A.eq(v({ kind = "card", verified = true, twin = true, signed = true, price = 1900, market = 2000 }), "clear", "a signed reprice")
		A.eq(v({ kind = "card", verified = true, twin = true, signed = false, price = 1600, market = 2000 }), "escalate", "a twin with no signatures")
		A.eq(v({ kind = "card", verified = true, newName = true, price = 1600, market = 2000 }), "escalate", "a newcomer 20% under")
		A.eq(v({ kind = "card", verified = true, newName = true, price = 1840, market = 2000 }), "clear", "a newcomer 8% under: what the monitors miss")
		A.eq(v({ kind = "duplicate" }), "clear")
	end)

	t.case("monitors off: every case is a judgment call for the human", function(A)
		local _, m = demo(25, false, 60)
		A.eq(m.calls, m.cases, "calls == cases")
		A.eq(m.autoCaught + m.autoCleared, 0, "no monitor acted")
	end)

	t.case("at 5 agents the human keeps up", function(A)
		local _, m = demo(5, false, 120)
		A.between(m.callsPerMin, 2, m.capacityPerMin, "calls/min within the budget")
		A.ok(m.queue <= 4, "a short queue: " .. m.queue)
		A.between(m.eventsPerMin, 100, 180, "events/min")
	end)

	t.case("at 100 agents with no monitors the human drowns", function(A)
		local _, m = demo(100, false, 90)
		A.ok(m.callsPerMin > 5 * m.capacityPerMin, "calls/min " .. m.callsPerMin)
		A.ok(m.queue > 15, "the queue piles up: " .. m.queue)
		A.ok(m.escaped > m.caught, string.format("escapes %d > catches %d", m.escaped, m.caught))
		A.between(m.eventsPerMin, 2000, 3500, "events/min")
	end)

	t.case("monitors on at 100: the flood becomes a trickle, and catches hold up", function(A)
		local tot = { caught = 0, escaped = 0 }
		for seed = 1, 3 do
			local _, m = demo(100, true, 120, seed)
			A.between(m.callsPerMin, 1, m.capacityPerMin, "seed " .. seed .. " calls/min: the human still matters, and keeps up")
			A.ok(m.autoCaught > m.humanCaught, "the monitors do most of the catching")
			A.eq(m.escaped, sum(m.missedByMonitors, m.escapedWaiting, m.humanWrong), "every escape is accounted for")
			A.eq(m.falseAlarms, 0, "rules never flag the honest")
			tot.caught += m.caught
			tot.escaped += m.escaped
		end
		A.ok(tot.caught >= 5 * tot.escaped, string.format("caught %d vs escaped %d", tot.caught, tot.escaped))
		A.ok(tot.escaped > 0, "and they are not magic: something escapes")
	end)

	t.case("without signatures (plain.v1) the monitors go blind and the calls come back", function(A)
		local _, on = demo(100, true, 90, 2)
		local _, blind = demo(100, true, 90, 2, PLAIN)
		A.ok(blind.callsPerMin > 2 * on.callsPerMin, string.format("%.1f vs %.1f calls/min", blind.callsPerMin, on.callsPerMin))
		A.ok(blind.callsPerMin > blind.capacityPerMin, "more than a human can do")
		A.eq(blind.blocked, 0, "no guards: nothing is stopped at the gate")
	end)

	t.case("turning the monitors on hands them the backlog", function(A)
		local g = lib.Game.new({ config = lib.Config, seed = 3 })
		g:start(0)
		g:setSize(100)
		lib.runGame(g, 60)
		local before = g:oversightMetrics().queue
		A.ok(before > 10, "a backlog: " .. before)
		g:setMonitors(true)
		lib.runGame(g, 62)
		local after = g:oversightMetrics().queue
		A.ok(after < 5, "sorted: " .. after)
	end)

	t.case("a threat is booked to the setting it appeared under", function(A)
		local o = Oversight.new({ config = lib.Config, layers = { auth = "hmac.v1" } })
		o:mark(0, "a")
		o:threatAppeared({ id = "threat-1", kind = "bait" }, 1)
		o:mark(10, "b")
		o:resolved({ id = "threat-1", kind = "bait", state = "escaped" }, 11)
		A.eq(o.totals.escaped, 0, "not this setting's escape")
		o:threatAppeared({ id = "threat-2", kind = "bait" }, 12)
		o:resolved({ id = "threat-2", kind = "bait", state = "escaped" }, 13)
		A.eq(o.totals.escaped, 1)
	end)

	t.case("the HUD's numbers carry no secrets and encode as JSON", function(A)
		local g, m = demo(100, false, 30)
		A.ok(#m.rows > 0, "queue rows")
		for _, r in m.rows do
			A.eq(r.threat, nil, "no threat id on a row")
			A.eq(type(r.text), "string")
		end
		for k in m do
			A.ok(type(k) ~= "string" or string.sub(k, 1, 1) ~= "_", "no private key " .. tostring(k))
		end
		A.eq(m.size, 100)
		A.eq(m.capacityPerMin, 12)
		A.ok(g:status().demo)
	end)

	t.case("a human on blue decides queue cases by flagging them", function(A)
		local g = lib.Game.new({ config = lib.Config, seed = 2 })
		g:start(0)
		g:join(1, "Peter")
		g:setTeam(1, "blue")
		g:setSize(25)
		lib.runGame(g, 20)
		local q = g.oversight.queue
		A.ok(#q > 0, "cases wait for the human (no BlueBot when blue has a human)")
		local target = q[1].target
		g:flag(1, target, { camera = "tower" })
		for _, c in g.oversight.queue do
			A.ok(c.target ~= target, "that case is decided")
		end
	end)

	t.case("the beats step through the demo and the last one restores the game", function(A)
		local g = lib.Game.new({ config = lib.Config, seed = 1 })
		g:start(0)
		local seen = {}
		for i = 1, #Oversight.BEATS do
			local b = g:setBeat()
			table.insert(seen, b.id)
			lib.runGame(g, g.t + 5)
			if b.id == "grow100" then
				A.eq(g.sim:size(), 100)
				A.eq(g.monitors, false)
			elseif b.id == "monitors" then
				A.eq(g.monitors, true)
			elseif b.id == "guards" then
				A.eq(g.layers.auth, "plain.v1")
			elseif b.id == "restore" then
				A.eq(g.layers.auth, "hmac.v1")
			end
			A.eq(g.beat, b.oversight == false and 0 or i)
		end
		A.eq(table.concat(seen, ","), "small,grow25,grow100,monitors,guards,restore,end")
		A.eq(g.demo, false)
		A.eq(g.sim:size(), 5)
		A.eq(g.layers.auth, "hmac.v1")
		A.eq(g.phaseEnds - g.roundStart, lib.Config.ROUND_SECONDS, "a normal round again")
		A.eq(g:oversightMetrics(), nil)
	end)
end
