-- Test runner for the pure-Luau core (tools/test.sh runs this with Lune).
-- Each tests/test_*.luau returns a function(t) that registers cases with
-- t.case(name, fn); fn gets the assertion helpers below.

local fs = require("@lune/fs")
local process = require("@lune/process")

local filter = process.args[1]

local function fmt(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local A = {}
function A.eq(got: any, want: any, msg: string?)
	if got ~= want then
		error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", fmt(want), fmt(got)), 2)
	end
end
function A.ok(cond: any, msg: string?)
	if not cond then
		error(msg or "expected a truthy value", 2)
	end
end
function A.near(got: number, want: number, tol: number, msg: string?)
	if math.abs(got - want) > tol then
		error(string.format("%sexpected %s ± %s, got %s", msg and (msg .. ": ") or "", fmt(want), fmt(tol), fmt(got)), 2)
	end
end
function A.between(got: number, lo: number, hi: number, msg: string?)
	if got < lo or got > hi then
		error(string.format("%sexpected %s in [%s, %s]", msg and (msg .. ": ") or "", fmt(got), fmt(lo), fmt(hi)), 2)
	end
end

local files = {}
for _, name in fs.readDir("tests") do
	if string.match(name, "^test_.*%.luau$") and (not filter or string.find(name, filter, 1, true)) then
		table.insert(files, name)
	end
end
table.sort(files)

local passed, failed = 0, {}
for _, file in files do
	local mod = (require :: any)("./" .. string.gsub(file, "%.luau$", ""))
	local cases = {}
	mod({
		case = function(name: string, fn)
			table.insert(cases, { name = name, fn = fn })
		end,
	})
	for _, c in cases do
		local ok, err = pcall(c.fn, A)
		if ok then
			passed += 1
			print(string.format("  ok    %s :: %s", file, c.name))
		else
			table.insert(failed, string.format("%s :: %s\n        %s", file, c.name, tostring(err)))
			print(string.format("  FAIL  %s :: %s\n        %s", file, c.name, tostring(err)))
		end
	end
end

print(string.format("\n%d passed, %d failed (%d files)", passed, #failed, #files))
if #failed > 0 then
	process.exit(1)
end
