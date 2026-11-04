-- The demo's claims, proved headless (docs/market-design.md, "The demo").
-- Each row: 3 seeds, 60 s warm-up, then 3 simulated minutes, one modelled
-- watcher (12 calls a minute, right 95% / 80% / 60% on ordinary / gray / twin
-- cases). Prints the table that goes in MARKET_DEMO.md.

local lib = require("./lib")

local SEEDS = { 1, 2, 3 }
local BUDGET = lib.Config.BUDGET

local rows = {} -- label -> numbers
local order = {}
local function row(label: string, opts)
	if rows[label] then
		return rows[label]
	end
	local r = lib.mean(opts, SEEDS)
	r.label = label
	r.opts = opts
	rows[label] = r
	table.insert(order, r)
	return r
end

local function all()
	row("L1   5 traders, monitor off", { n = 5, monitor = "off" })
	row("     50 traders, monitor off", { n = 50, monitor = "off" })
	row("     300 traders, monitor off", { n = 300, monitor = "off" })
	row("L2   300 traders, rule monitor", { n = 300, monitor = "rules" })
	row("     300, rules, signatures OFF", { n = 300, monitor = "rules", signatures = false })
	row("L3   300, rules, sigs off, 2 watchers", { n = 300, monitor = "rules", signatures = false, watchers = 2 })
	row("     1000 traders, rule monitor", { n = 1000, monitor = "rules" })
end

local function printTable()
	print("")
	print("  setting                                calls/min  per watcher  decided  caught  escaped  false al.  deals/min")
	print("  -------------------------------------  ---------  -----------  -------  ------  -------  ---------  ---------")
	for _, r in order do
		print(string.format(
			"  %-37s  %9.1f  %11.1f  %7.1f  %6.1f  %7.1f  %9.1f  %9.0f",
			r.label, r.calls, r.perWatcher, r.decided, r.caught, r.escaped, r.falseAlarms, r.deals
		))
	end
	print(string.format("  (per minute; budget %d calls per watcher per minute; mean of seeds %s)", BUDGET, table.concat(SEEDS, ", ")))
	print("")
end

return function(t)
	t.case("the table", function(A)
		all()
		printTable()
	end)

	t.case("L1: five traders, monitor off: one watcher keeps up", function(A)
		local r = rows["L1   5 traders, monitor off"]
		A.ok(r.calls > 0.5, "some cases: " .. r.calls)
		A.ok(r.perWatcher < BUDGET, string.format("under budget: %.1f", r.perWatcher))
		A.ok(r.escaped <= 0.5, string.format("almost nothing escapes: %.2f/min", r.escaped))
	end)

	t.case("300 traders, monitor off: judgment calls far exceed 12, frauds escape while they wait", function(A)
		local r = rows["     300 traders, monitor off"]
		A.ok(r.perWatcher > 3 * BUDGET, string.format("calls/min %.1f > 3x budget", r.perWatcher))
		A.ok(r.escaped > 1, string.format("escapes %.1f/min", r.escaped))
		A.ok(r.decided <= BUDGET + 0.5, "the watcher cannot decide more than 12 a minute")
	end)

	t.case("L2: the rule monitor brings it near or under 12 while catches hold", function(A)
		local off = rows["     300 traders, monitor off"]
		local on = rows["L2   300 traders, rule monitor"]
		A.ok(on.perWatcher <= BUDGET * 1.15, string.format("calls/min %.1f near or under 12", on.perWatcher))
		A.ok(on.perWatcher < off.perWatcher / 3, "a big drop")
		A.ok(on.caught >= off.caught, string.format("catches hold: %.1f vs %.1f", on.caught, off.caught))
		A.ok(on.escaped < off.escaped / 2, string.format("escapes fall: %.1f vs %.1f", on.escaped, off.escaped))
	end)

	t.case("signatures off: twins push the judgment calls back up", function(A)
		local on = rows["L2   300 traders, rule monitor"]
		local off = rows["     300, rules, signatures OFF"]
		A.ok(off.perWatcher > BUDGET, string.format("over budget again: %.1f", off.perWatcher))
		A.ok(off.perWatcher > 1.8 * on.perWatcher, string.format("%.1f vs %.1f", off.perWatcher, on.perWatcher))
		A.ok(off.rejected == 0 and on.rejected > 0, "signatures were rejecting impostors for free")
	end)

	t.case("the lever's cost: signature checks slow trade", function(A)
		local on = rows["L2   300 traders, rule monitor"]
		local off = rows["     300, rules, signatures OFF"]
		A.ok(off.deals > on.deals * 1.05, string.format("deals/min %.0f (off) vs %.0f (on)", off.deals, on.deals))
	end)

	t.case("honest newcomers produce some false alarms", function(A)
		local on = rows["L2   300 traders, rule monitor"]
		A.ok(on.falseAlarms > 0.2, string.format("false alarms %.2f/min", on.falseAlarms))
	end)

	t.case("L3: a second watcher splits the inbox", function(A)
		local one = rows["     300, rules, signatures OFF"]
		local two = rows["L3   300, rules, sigs off, 2 watchers"]
		A.ok(two.perWatcher < one.perWatcher * 0.75, string.format("%.1f vs %.1f per watcher", two.perWatcher, one.perWatcher))
		A.ok(two.perWatcher <= BUDGET, "each back under budget")
		A.ok(two.decided > one.decided * 1.4, "twice the decisions")
	end)
end
