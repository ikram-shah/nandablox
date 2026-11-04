-- The market's floor plan, shared by the simulation (walk times) and the
-- client (where to draw, how people walk). Pure Luau, plain {x, z} tables.
--
-- A round square: the fountain in a plaza at the centre, then concentric
-- aisles. Each aisle has a ring of stalls on either side facing into it, and
-- four radial streets (N, E, S, W) cut through every ring. People walk along
-- an aisle's arc, or down a street to another aisle, so nobody walks through
-- a stall. Given two points, `path` is deterministic, so the server only ever
-- sends (from, to, t0, t1) and every client draws the same walk.

local Layout = {}

Layout.PLAZA_R = 21
Layout.FOUNTAIN_R = 9
Layout.AISLE0 = 34
Layout.AISLE_STEP = 30
Layout.AISLES = 5
Layout.AISLE_HALF = 6 -- stall fronts sit this far either side of the aisle's centre line
Layout.STALL_DEPTH = 6
Layout.STALL_WIDTH = 10
Layout.STALL_PITCH = 12.5
Layout.STREET_HALF = 6
Layout.STREETS = { 0, math.pi / 2, math.pi, 3 * math.pi / 2 }
Layout.ARC_STEP = math.rad(7)

local TAU = 2 * math.pi
-- the angle the small market clusters around (and the camera starts from)
Layout.HOME = math.rad(-60)
local GOLDEN = 0.6180339887498949

function Layout.aisleRadius(j: number): number
	return Layout.AISLE0 + Layout.AISLE_STEP * j
end

Layout.EDGE_R = Layout.aisleRadius(Layout.AISLES - 1) + 20 -- just outside the last ring of stalls

local function wrap(a: number): number
	a = a % TAU
	if a < 0 then
		a += TAU
	end
	return a
end

-- signed shortest angle from a to b
local function delta(a: number, b: number): number
	local d = (b - a) % TAU
	if d > math.pi then
		d -= TAU
	end
	return d
end
Layout.delta = delta

local function polar(r: number, th: number)
	return { x = r * math.cos(th), z = r * math.sin(th) }
end
Layout.polar = polar

local function toPolar(p): (number, number)
	return math.sqrt(p.x * p.x + p.z * p.z), wrap(math.atan2(p.z, p.x))
end
Layout.toPolar = toPolar

------------------------------------------------------------------------ stalls

-- Every stall slot, in fill order: aisle 0 first, and within an aisle spread
-- evenly around the circle (golden-ratio order), so a small market is not all
-- on one side.
local function buildSlots()
	local slots = {}
	for j = 0, Layout.AISLES - 1 do
		local A = Layout.aisleRadius(j)
		local here = {}
		for _, side in { -1, 1 } do -- -1: inner ring (faces outward), 1: outer ring (faces inward)
			local r = A + side * (Layout.AISLE_HALF + Layout.STALL_DEPTH / 2)
			local n = math.floor(TAU * r / Layout.STALL_PITCH)
			for k = 0, n - 1 do
				local th = (k + 0.5 + (side > 0 and 0.25 or 0)) * TAU / n
				local clear = true
				for _, s in Layout.STREETS do
					if math.abs(delta(th, s)) * r < Layout.STREET_HALF + Layout.STALL_WIDTH / 2 + 0.5 then
						clear = false
					end
				end
				if clear then
					table.insert(here, { aisle = j, side = side, r = r, theta = wrap(th) })
				end
			end
		end
		table.sort(here, function(a, b)
			return a.theta < b.theta
		end)
		local keyed = {}
		if j == 0 then
			-- the first aisle fills outward from HOME (the side the camera
			-- starts on), so a small market is a cosy cluster in view, and
			-- grows around the ring as it gets bigger
			for i, s in here do
				keyed[i] = { s = s, key = math.abs(delta(Layout.HOME, s.theta)) + (s.side > 0 and 0.01 or 0) }
			end
		else
			-- later aisles: spread evenly around the circle (golden ratio)
			for i, s in here do
				keyed[i] = { s = s, key = (i * GOLDEN) % 1 }
			end
		end
		table.sort(keyed, function(a, b)
			return a.key < b.key
		end)
		for _, k in keyed do
			table.insert(slots, k.s)
		end
	end
	for i, s in slots do
		s.slot = i
		s.pos = polar(s.r, s.theta)
		local A = Layout.aisleRadius(s.aisle)
		-- the buyer stands here, at the counter
		s.front = polar(A - s.side * (Layout.AISLE_HALF - 1.6), s.theta)
		-- the seller stands here, behind the counter
		s.back = polar(s.r + s.side * 1.2, s.theta)
		-- unit vector the stall faces (toward the aisle)
		s.facing = { x = -s.side * math.cos(s.theta), z = -s.side * math.sin(s.theta) }
	end
	return slots
end

Layout.SLOTS = buildSlots()

-- how many slots the first `aisles` aisles hold
function Layout.capacity(aisles: number): number
	local n = 0
	for _, s in Layout.SLOTS do
		if s.aisle < aisles then
			n += 1
		end
	end
	return n
end

------------------------------------------------------------------------ places

-- which zone a point is in: "plaza", an aisle index, or "out" (on a street or
-- beyond the market)
local function zone(r: number): any
	if r <= Layout.PLAZA_R + 0.5 then
		return "plaza"
	end
	for j = 0, Layout.AISLES - 1 do
		if math.abs(r - Layout.aisleRadius(j)) <= Layout.AISLE_HALF + 0.5 then
			return j
		end
	end
	return "out"
end
Layout.zone = function(p)
	return zone((toPolar(p)))
end

-- a random place to stand: somewhere in an aisle or the plaza
function Layout.randomSpot(rng, aisles: number, near: number?)
	-- a small market: stay among its stalls, within `near` radians of HOME
	if near then
		local r = Layout.aisleRadius(0) + rng:range(-2.5, 2.5)
		return polar(r, Layout.HOME + rng:range(-near, near))
	end
	if rng:chance(0.12) then
		local r = rng:range(Layout.FOUNTAIN_R + 3, Layout.PLAZA_R - 1)
		return polar(r, rng:range(0, TAU))
	end
	local j = rng:int(0, math.max(0, aisles - 1))
	local r = Layout.aisleRadius(j) + rng:range(-2.5, 2.5)
	return polar(r, rng:range(0, TAU))
end

-- where newcomers walk in from: the outer end of a street
function Layout.gate(rng)
	local s = rng:pick(Layout.STREETS) + rng:range(-0.02, 0.02)
	return polar(Layout.EDGE_R + rng:range(0, 10), s)
end

------------------------------------------------------------------------ paths

local function arc(out, r0: number, th0: number, r1: number, th1: number)
	local d = delta(th0, th1)
	local steps = math.max(1, math.ceil(math.abs(d) / Layout.ARC_STEP))
	for i = 1, steps do
		local f = i / steps
		table.insert(out, polar(r0 + (r1 - r0) * f, th0 + d * f))
	end
end

-- The waypoints from p to q (both included). Within one aisle: along its
-- arc. Otherwise: along the aisle to the best street, down the street, and
-- along the other aisle. The plaza is open ground.
function Layout.path(p, q)
	local rp, tp = toPolar(p)
	local rq, tq = toPolar(q)
	local zp, zq = zone(rp), zone(rq)
	local out = { p }
	if zp == "plaza" and zq == "plaza" then
		table.insert(out, q)
		return out
	end
	if zp == zq and type(zp) == "number" then
		arc(out, rp, tp, rq, tq)
		out[#out] = q
		return out
	end
	-- pick the street that costs least
	local best, bestCost = Layout.STREETS[1], math.huge
	for _, s in Layout.STREETS do
		local c = 0
		if zp ~= "plaza" then
			c += math.abs(delta(tp, s)) * rp
		end
		if zq ~= "plaza" then
			c += math.abs(delta(s, tq)) * rq
		end
		if c < bestCost then
			best, bestCost = s, c
		end
	end
	local s = best
	-- leg 1: to the street
	local r1 = rp
	if zp == "plaza" then
		r1 = Layout.PLAZA_R
		table.insert(out, polar(r1, s))
	else
		arc(out, rp, tp, rp, s)
	end
	-- leg 2: down the street
	local r2 = (zq == "plaza") and Layout.PLAZA_R or rq
	if math.abs(r2 - r1) > 0.01 then
		table.insert(out, polar(r2, s))
	end
	-- leg 3: to q
	if zq == "plaza" then
		table.insert(out, q)
	else
		arc(out, r2, s, rq, tq)
		out[#out] = q
	end
	return out
end

function Layout.length(points): number
	local d = 0
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		d += math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
	end
	return d
end

-- where along `points` a walker is at fraction f (0..1), and which way it faces
function Layout.at(points, cum, f: number)
	local total = cum[#cum]
	if total <= 0 or f <= 0 then
		local a, b = points[1], points[math.min(2, #points)]
		return points[1], { x = b.x - a.x, z = b.z - a.z }
	end
	local want = math.min(1, f) * total
	for i = 2, #points do
		if cum[i] >= want then
			local a, b = points[i - 1], points[i]
			local seg = cum[i] - cum[i - 1]
			local g = seg > 0 and (want - cum[i - 1]) / seg or 1
			return { x = a.x + (b.x - a.x) * g, z = a.z + (b.z - a.z) * g }, { x = b.x - a.x, z = b.z - a.z }
		end
	end
	local a, b = points[#points - 1] or points[1], points[#points]
	return points[#points], { x = b.x - a.x, z = b.z - a.z }
end

function Layout.cumulative(points)
	local cum = { 0 }
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		cum[i] = cum[i - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
	end
	return cum
end

return Layout
