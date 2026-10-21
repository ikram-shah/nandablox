-- Game: scoring, tokens, permissions, rounds, privacy of events, telemetry.

local lib = require("./lib")

local function game(over, layers)
	-- bots off unless a test turns them on, so scores are only what we do
	local cfg = lib.quiet({ RED_BOT = "off", BLUE_BOT = "off" })
	for k, v in over or {} do
		cfg[k] = v
	end
	local g = lib.Game.new({ config = cfg, seed = 3, layers = layers })
	g:join("red1", "Rita")
	g:setTeam("red1", "red")
	g:join("blue1", "Bo")
	g:setTeam("blue1", "blue")
	g:start(0)
	lib.runGame(g, 30)
	return g
end

local PLAIN = { auth = "plain.v1", registry = "index.v1", transport = "memory.v1" }

return function(t)
	t.case("an escape scores red +10", function(A)
		local g = game(nil, PLAIN)
		local ok, why, th = g:attack("red1", "forge", "seller-a")
		A.ok(ok, why)
		local evs = lib.runGame(g, g.t + g.cfg.FORGE_WINDOW + 1)
		A.eq(th.state, "escaped")
		A.eq(g.score.red, g.cfg.ESCAPE_POINTS)
		A.eq(g.score.red, 10)
		local esc = lib.first(evs, function(e)
			return e.kind == "threat_escaped"
		end)
		A.ok(esc and esc.subject == th.id and esc.detail.points == 10)
	end)

	t.case("a catch scores blue +1; a false alarm -1 and stalls a deal", function(A)
		local g = game(nil, PLAIN)
		local _, _, th = g:attack("red1", "forge", "seller-a")
		lib.runGame(g, g.t + 2)
		A.eq(g:flag("blue1", th.msgId, { camera = "tower" }), "catch")
		A.eq(g.score.blue, 1)
		lib.runGame(g, g.t + 20)
		A.eq(g.score.red, 0, "no escape after a catch")
		local honest = nil
		for _ = 1, 100 do
			honest = g.sim:honestTargets()[1]
			if honest then
				break
			end
			lib.runGame(g, g.t + 0.1)
		end
		A.ok(honest, "an honest courier on the road")
		local evs = {}
		A.eq(g:flag("blue1", honest, { camera = "overview" }), "false_alarm")
		for _, e in g:drain() do
			table.insert(evs, e)
		end
		A.eq(g.score.blue, 0, "1 - 1")
		A.ok(lib.first(evs, function(e)
			return e.kind == "false_alarm" and e.subject == honest
		end))
		A.ok(lib.first(evs, function(e)
			return e.kind == "message_delayed" and e.subject == honest and e.detail.fault == "false_alarm"
		end), "the honest envelope is held")
	end)

	t.case("flags: misses and stale targets cost nothing; spam is rate-limited", function(A)
		local g = game(nil, PLAIN)
		A.eq(g:flag("blue1", "nothing-here"), "miss")
		g.t += 1
		A.eq(g:flag("blue1", ""), "miss")
		A.eq(g:flag("blue1", ""), "cooldown")
		A.eq(g.score.blue, 0)
	end)

	t.case("red has 4 tokens a round, with a cooldown between attacks", function(A)
		local g = game()
		A.eq(g.tokens, 4)
		for i = 1, 4 do
			local ok, why = g:attack("red1", i % 2 == 0 and "forge" or "spoof")
			A.ok(ok, "attack " .. i .. ": " .. why)
			if i < 4 then
				local again, why2 = g:attack("red1", "forge")
				A.ok(not again and why2 == "cooldown", "cooldown after attack " .. i)
			end
			lib.runGame(g, g.t + g.cfg.ATTACK_COOLDOWN + 0.1)
		end
		local ok, why = g:attack("red1", "forge")
		A.ok(not ok)
		A.eq(why, "no_tokens")
		A.eq(g.tokens, 0)
	end)

	t.case("only red attacks and only blue flags", function(A)
		local g = game(nil, PLAIN)
		local ok, why = g:attack("blue1", "forge")
		A.ok(not ok and why == "not_red")
		g:join("lurker", "Lu")
		local ok2, why2 = g:attack("lurker", "spoof")
		A.ok(not ok2 and why2 == "not_red", "no team, no attack")
		local _, _, th = g:attack("red1", "forge")
		A.eq(g:flag("red1", th.msgId), "not_blue")
		A.eq(g:flag("lurker", th.msgId), "not_blue")
		A.eq(g.tokens, 3)
		local okBad, whyBad = g:attack("red1", "nuke")
		A.ok(not okBad and whyBad == "bad_attack")
	end)

	t.case("under the defaults a forge is blocked: a token gone, no points", function(A)
		local g = game()
		local ok, _, th = g:attack("red1", "forge")
		A.ok(ok)
		A.eq(th.state, "blocked")
		lib.runGame(g, g.t + 20)
		A.eq(g.score.red, 0)
		A.eq(g.score.blue, 0)
		A.eq(g.tally.blocked, 1)
	end)

	t.case("rounds: 180 s of play, 12 s of results, then a fresh round", function(A)
		local g = game(nil, PLAIN)
		g:attack("red1", "forge")
		local evs = lib.runGame(g, 179.9)
		A.eq(g.phase, "play")
		A.eq(g.round, 1)
		A.eq(lib.count(evs, function(e)
			return e.kind == "round_finished"
		end), 0)
		evs = lib.runGame(g, 180.2)
		A.eq(g.phase, "results")
		local fin = lib.first(evs, function(e)
			return e.kind == "round_finished"
		end)
		A.ok(fin, "round_finished")
		A.eq(fin.detail.red, 10)
		A.eq(fin.detail.winner, "red")
		A.ok(fin.detail.deals > 5, "the town traded")
		A.eq(g.wins.red, 1)
		evs = lib.runGame(g, 191.9)
		A.eq(g.phase, "results", "still on the results")
		A.eq(#lib.ofKind(evs, "message_sent"), 0, "the town is quiet between rounds")
		evs = lib.runGame(g, 192.2)
		A.eq(g.phase, "play")
		A.eq(g.round, 2)
		A.eq(g.tokens, 4, "tokens reset")
		A.eq(g.score.red, 0, "scores reset")
		A.eq(g.layers.auth, "plain.v1", "layers persist across rounds")
		A.ok(lib.first(evs, function(e)
			return e.kind == "round_started" and e.detail.round == 2
		end))
		A.ok(lib.first(evs, function(e)
			return e.kind == "account_opened"
		end), "a fresh town")
	end)

	t.case("a clean round goes to blue, even at 0-0", function(A)
		local g = game()
		lib.runGame(g, 181)
		A.eq(g.wins.blue, 1)
	end)

	t.case("events sent to clients never carry private fields", function(A)
		local g = game(nil, PLAIN)
		g:attack("red1", "forge")
		local evs = lib.runGame(g, 60)
		local leaked = 0
		local had = 0
		for _, e in evs do
			if e._threat then
				had += 1
			end
			local p = lib.Game.public(e)
			for k in p do
				if type(k) == "string" and string.sub(k, 1, 1) == "_" then
					leaked += 1
				end
			end
		end
		A.ok(had > 0, "the server copy has threat ids")
		A.eq(leaked, 0, "the public copy has none")
	end)

	t.case("telemetry: threat appeared -> flag latency, camera mode, false alarms", function(A)
		local g = game(nil, PLAIN)
		g:setCamera("blue1", "tower")
		local _, _, th = g:attack("red1", "forge")
		lib.runGame(g, g.t + 3.0)
		g:flag("blue1", th.msgId)
		local rec = g.telemetry
		local appeared = rec:ofKind("threat_appeared")
		A.eq(#appeared, 1)
		A.eq(appeared[1].threat, th.id)
		A.eq(appeared[1].attack, "forge")
		local flags = rec:ofKind("flag")
		A.eq(#flags, 1)
		A.eq(flags[1].result, "catch")
		A.eq(flags[1].camera, "tower")
		A.near(flags[1].latency, 3.0, 0.15, "seconds from threat to flag")
		local cams = rec:ofKind("camera")
		A.eq(cams[1].mode, "tower")
		lib.runGame(g, g.t + 1)
		while not g.sim:honestTargets()[1] do
			lib.runGame(g, g.t + 0.1)
		end
		g:flag("blue1", g.sim:honestTargets()[1])
		A.eq(rec:ofKind("flag")[2].result, "false_alarm")
		g:click("blue1")
		A.eq(#rec:ofKind("click"), 1)
	end)

	t.case("telemetry sink gets every record (the server prints them as JSON lines)", function(A)
		local got = {}
		local cfg = lib.quiet({ RED_BOT = "on", BLUE_BOT = "on" })
		local g = lib.Game.new({ config = cfg, seed = 5, sink = function(r)
			table.insert(got, r)
		end })
		g:start(0)
		lib.runGame(g, 185)
		A.ok(#got >= 4, "records arrived")
		A.eq(got[1].kind, "round_started")
		A.ok(lib.first(got, function(r)
			return r.kind == "round_summary"
		end), "a round summary")
		local serde = require("@lune/serde")
		for _, r in got do
			A.ok(#serde.encode("json", r) > 10, "encodes as JSON")
		end
	end)

	t.case("a late joiner's snapshot rebuilds the town as it is now", function(A)
		local g = game(nil, PLAIN)
		g:attack("red1", "spoof", "seller-a")
		lib.runGame(g, g.t + 1)
		local snap = g:snapshotEvents()
		A.eq(snap[1].kind, "round_started")
		A.eq(lib.count(snap, function(e)
			return e.kind == "account_opened"
		end), 6)
		A.eq(lib.count(snap, function(e)
			return (e.kind == "card_registered" or e.kind == "card_unverified") and e.subject == "seller-a"
		end), 2, "both seller-a cards, the honest one and the impostor")
		for _, e in snap do
			A.ok(e.snapshot, "marked as snapshot")
			A.eq(e._threat, nil, "nothing private")
		end
	end)
end
