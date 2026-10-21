-- RedBot and BlueBot, and whole solo rounds with them.

local lib = require("./lib")

local PLAIN = { auth = "plain.v1", registry = "index.v1", transport = "memory.v1" }
local LOCKED = { auth = "hmac.v1", registry = "index.owned.v1", transport = "memory.v1" }

return function(t)
	t.case("bots are on when their team has no humans ('auto')", function(A)
		local g = lib.Game.new({ config = lib.quiet(), seed = 1 })
		A.ok(g:botOn("red") and g:botOn("blue"), "empty server: both")
		g:join("p", "Peter")
		A.ok(g:botOn("red") and g:botOn("blue"), "no team yet: both")
		g:setTeam("p", "blue")
		A.ok(g:botOn("red") and not g:botOn("blue"), "Peter on blue: RedBot only")
		g:setTeam("p", "red")
		A.ok(not g:botOn("red") and g:botOn("blue"), "Peter on red: BlueBot only")
		local forced = lib.Game.new({ config = lib.quiet({ RED_BOT = "off", BLUE_BOT = "on" }), seed = 1 })
		forced:join("q", "Q")
		forced:setTeam("q", "blue")
		A.ok(not forced:botOn("red") and forced:botOn("blue"), "config forces them")
	end)

	t.case("RedBot attacks on schedule and never beyond its tokens", function(A)
		local g = lib.Game.new({ config = lib.quiet({ BLUE_BOT = "off" }), seed = 9 })
		g:start(0)
		lib.runGame(g, g.cfg.RED_BOT_FIRST - 0.2)
		A.eq(g.tokens, 4, "waits for RED_BOT_FIRST")
		lib.runGame(g, g.cfg.RED_BOT_FIRST + 0.3)
		A.eq(g.tokens, 3, "first attack")
		lib.runGame(g, 179)
		A.ok(g.tokens >= 0 and g.tokens <= 1, "about one attack per 28-40 s: " .. g.tokens .. " left")
		A.eq(#g.telemetry:ofKind("threat_appeared"), 4 - g.tokens)
	end)

	t.case("a smart RedBot picks the attack the layers let through", function(A)
		local bot = lib.Bots.RedBot.new(lib.config(), 3)
		for _ = 1, 20 do
			A.eq(bot:choose({ auth = "plain.v1", registry = "index.owned.v1" }), "forge")
			A.eq(bot:choose({ auth = "hmac.v1", registry = "index.v1" }), "spoof")
		end
		local seen = {}
		for _ = 1, 40 do
			seen[bot:choose({ auth = "hmac.v1", registry = "index.owned.v1" })] = true
		end
		A.ok(seen.forge and seen.spoof, "all locked: either, both wasted")
	end)

	t.case("a perfect BlueBot catches everything after its reaction time", function(A)
		local g = lib.Game.new({ config = lib.quiet({ BLUE_BOT_DETECT_PER_SECOND = 1, BLUE_BOT_FALSE_ALARM_PER_SECOND = 0 }), seed = 12, layers = PLAIN })
		g:start(0)
		lib.runGame(g, 181)
		A.eq(g.tally.escapes, 0)
		A.ok(g.tally.catches >= 3, "caught " .. g.tally.catches)
		A.eq(g.score.blue, g.tally.catches)
		for _, f in g.telemetry:ofKind("flag") do
			A.ok(f.latency >= g.cfg.BLUE_BOT_REACTION, "never faster than its reaction")
		end
	end)

	t.case("a blind BlueBot lets every live attack escape", function(A)
		local g = lib.Game.new({ config = lib.quiet({ BLUE_BOT_DETECT_PER_SECOND = 0, BLUE_BOT_FALSE_ALARM_PER_SECOND = 0 }), seed = 12, layers = PLAIN })
		g:start(0)
		lib.runGame(g, 181)
		A.eq(g.tally.catches, 0)
		A.ok(g.tally.escapes >= 3, "escaped " .. g.tally.escapes)
		A.eq(g.wins.red, 1)
	end)

	t.case("with every layer locked, RedBot gets nothing through", function(A)
		local g = lib.Game.new({ config = lib.config({ BLUE_BOT = "off" }), seed = 13, layers = LOCKED })
		g:start(0)
		lib.runGame(g, 181)
		A.eq(g.tally.escapes, 0)
		A.eq(g.tally.blocked, 4, "all four tokens blocked")
	end)

	t.case("solo rounds are a contest: summary over 10 seeds per layer setting", function(A)
		local rows = {}
		for _, case in {
			{ "hmac+index (default)", nil },
			{ "plain+index", PLAIN },
			{ "hmac+owned", { auth = "hmac.v1", registry = "index.owned.v1", transport = "memory.v1" } },
		} do
			local esc, cat, fa, deals, redWins = 0, 0, 0, 0, 0
			for seed = 1, 10 do
				local g = lib.Game.new({ config = lib.config(), seed = seed, layers = case[2] })
				g:start(0)
				lib.runGame(g, 181, 0.2)
				esc += g.tally.escapes
				cat += g.tally.catches
				fa += g.tally.false_alarms
				deals += g.lastDeals or 0
				redWins += g.wins.red
			end
			table.insert(rows, string.format("        %-22s escapes %4.1f  catches %4.1f  false alarms %3.1f  deals %4.1f  red wins %d/10", case[1], esc / 10, cat / 10, fa / 10, deals / 10, redWins))
			if case[2] == PLAIN then
				A.ok(esc > 0 and cat > 0, "wide open: both sides score")
			end
		end
		print(table.concat(rows, "\n"))
	end)
end
