-- Layout: stalls clear of the streets, walks that never cross a stall.

local lib = require("./lib")
local Layout = lib.Layout
local MarketSim = lib.MarketSim

local function inStall(p): boolean
	local r, th = Layout.toPolar(p)
	for _, s in Layout.SLOTS do
		if math.abs(r - s.r) < Layout.STALL_DEPTH / 2 - 0.3 then
			local along = math.abs(Layout.delta(th, s.theta)) * s.r
			if along < Layout.STALL_WIDTH / 2 - 0.3 then
				return true
			end
		end
	end
	return false
end

return function(t)
	t.case("enough slots for 1,000 traders", function(A)
		A.ok(#Layout.SLOTS >= MarketSim.sellersFor(1000) * 1.2, "slots: " .. #Layout.SLOTS)
		A.ok(Layout.capacity(3) >= MarketSim.sellersFor(300) * 1.3, "300 traders fit in three aisles, with room")
	end)

	t.case("no stall stands in a street", function(A)
		for _, s in Layout.SLOTS do
			for _, st in Layout.STREETS do
				A.ok(math.abs(Layout.delta(s.theta, st)) * s.r >= Layout.STREET_HALF + Layout.STALL_WIDTH / 2, "slot " .. s.slot)
			end
		end
	end)

	t.case("a walk between any two counters never passes through a stall", function(A)
		local rng = lib.Rng.new(3)
		for _ = 1, 300 do
			local a = Layout.SLOTS[rng:int(1, #Layout.SLOTS)].front
			local b = rng:chance(0.5) and Layout.SLOTS[rng:int(1, #Layout.SLOTS)].front or Layout.randomSpot(rng, 4)
			local pts = Layout.path(a, b)
			A.eq(pts[1], a)
			A.eq(pts[#pts], b)
			local cum = Layout.cumulative(pts)
			local total = cum[#cum]
			for k = 0, 40 do
				local p = Layout.at(pts, cum, k / 40)
				A.ok(not inStall(p), string.format("walk %0.1f,%0.1f -> %0.1f,%0.1f passes a stall at %0.1f,%0.1f", a.x, a.z, b.x, b.z, p.x, p.z))
			end
			A.ok(total >= math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) - 1e-6, "no shorter than straight")
		end
	end)

	t.case("newcomers walk in from the gates without crossing a stall", function(A)
		local rng = lib.Rng.new(4)
		for _ = 1, 100 do
			local a = Layout.gate(rng)
			local b = Layout.randomSpot(rng, 3)
			local pts = Layout.path(a, b)
			local cum = Layout.cumulative(pts)
			for k = 0, 40 do
				A.ok(not inStall(Layout.at(pts, cum, k / 40)), "gate walk")
			end
		end
	end)
end
