-- The crowd: every trader drawn on the client. The server sends a buyer's
-- walk as (from, to, t0, t1); Layout.path turns that into the same waypoints
-- on every client, and each frame we place every figure where it should be.
-- Sellers stand behind their counters.
--
-- Two levels of detail. Everyone has a cheap simple figure (SimpleFigures:
-- five anchored parts moved with BulkMoveTo). The nearest MAX_RIGS people to
-- the camera are shown as real R15 rigs instead (RigFigures: pooled,
-- AnimationController walk/idle), chosen again a few times a second. Far
-- simple figures update less often, and anyone standing still is not touched.

local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)
local Theme = require(script.Parent.Theme)

local Crowd = {}

local folder: Folder
local buyers: { [string]: any } = {}
local sellers: { [string]: any } = {} -- seller id -> figure standing at its stall
local simple -- SimpleFigures
local rigs -- RigFigures (optional)
local frame = 0

Crowd.MAX_RIGS = 16 -- animated R15 rigs are dear (Animator + 15 parts each): only the closest few
local NEAR, MID = 90, 200
Crowd.RIG_RANGE = 110
local RIG_EVERY = 0.4 -- seconds between re-choosing who is near

local WALKING = { walk = true, stroll = true, cheated = true }
local FACE_STALL = { deal = true, wait = true, queue = true }

function Crowd.init(parent: Instance, simpleProvider, rigProvider)
	folder = Instance.new("Folder")
	folder.Name = "Crowd"
	folder.Parent = parent
	simple = simpleProvider
	simple.init(folder)
	rigs = rigProvider
	if rigs then
		rigs.init(folder)
	end
end

------------------------------------------------------------------ people

-- a person: { fig (simple), rig (or nil), look, role, carry, mood, cf, ... }
local function newPerson(look: number, role: string)
	return { fig = simple.take(look, role), look = look or 1, role = role }
end

local function dropRig(p)
	if p.rig then
		rigs.give(p.rig)
		p.rig = nil
		simple.show(p.fig, true)
		p.dirty = true
	end
end

local function giveRig(p)
	if p.rig or not rigs or not rigs.ready then
		return
	end
	local r = rigs.take(p.look, p.role)
	if not r then
		return
	end
	p.rig = r
	simple.show(p.fig, false)
	rigs.carry(r, p.carry and Theme.GOODS[p.carry] and Theme.GOODS[p.carry].color or nil)
	p.dirty = true
	p.settled = false
end

local function release(p)
	dropRig(p)
	simple.give(p.fig)
end

------------------------------------------------------------------ buyers

local function setPath(b)
	if b.from and b.to and (b.from.x ~= b.to.x or b.from.z ~= b.to.z) then
		b.pts = Layout.path(b.from, b.to)
		b.cum = Layout.cumulative(b.pts)
	else
		b.pts = nil
		b.cum = nil
	end
end

function Crowd.buyer(e)
	local b = buyers[e.id]
	if not b then
		b = newPerson(e.look, "buyer")
		b.id = e.id
		buyers[e.id] = b
	end
	b.from, b.to, b.t0, b.t1, b.state, b.target = e.from, e.to, e.t0, e.t1, e.state, e.target
	if b.carry ~= e.carry then
		b.carry = e.carry
		simple.carry(b.fig, e.carry)
		if b.rig then
			rigs.carry(b.rig, e.carry and Theme.GOODS[e.carry] and Theme.GOODS[e.carry].color or nil)
		end
	end
	b.mood = e.state == "cheated" and "cheated" or nil
	simple.mood(b.fig, b.mood)
	b.settled = false
	setPath(b)
end

function Crowd.buyerGone(id: string)
	local b = buyers[id]
	if b then
		release(b)
		buyers[id] = nil
	end
end

------------------------------------------------------------------ sellers

local STANDING = { open = true, setup = true, restock = true, blocked = true, shuttered = true }

function Crowd.seller(s)
	local f = sellers[s.id]
	if not STANDING[s.state] then
		if f then
			release(f)
			sellers[s.id] = nil
		end
		return
	end
	if not f then
		f = newPerson(s.look or 1, "seller")
		sellers[s.id] = f
	end
	-- a blocked or shuttered seller turns their back on the square
	local L = Layout.SLOTS[s.slot]
	local p = Vector3.new(L.back.x, 0, L.back.z)
	local face = Vector3.new(L.facing.x, 0, L.facing.z)
	if s.state == "blocked" or s.state == "shuttered" then
		face = -face
	end
	f.cf = CFrame.lookAt(p, p + face)
	f.pos = p
	f.mood = (s.state == "blocked" or s.state == "shuttered") and "cheated" or nil
	f.dirty = true
end

function Crowd.clear()
	for id in buyers do
		Crowd.buyerGone(id)
	end
	for id, f in sellers do
		release(f)
		sellers[id] = nil
	end
end

------------------------------------------------------------------ the frame

local function where(b, now: number): (Vector3, Vector3?, boolean)
	if b.pts and WALKING[b.state] then
		local span = b.t1 - b.t0
		local f = span > 0 and (now - b.t0) / span or 1
		f = math.clamp(f, 0, 1)
		local p, d = Layout.at(b.pts, b.cum, f)
		return Vector3.new(p.x, 0, p.z), Vector3.new(d.x, 0, d.z), f < 1
	end
	local p = b.to or b.from
	return Vector3.new(p.x, 0, p.z), nil, false
end

function Crowd.count(): (number, number, number)
	local nb, ns = 0, 0
	for _ in buyers do
		nb += 1
	end
	for _ in sellers do
		ns += 1
	end
	return nb, ns, rigs and rigs.count() or 0
end

-- who is nearest the camera gets a rig
local rigClock = 0
local scratch = {}
local function chooseRigs(cam: Vector3)
	table.clear(scratch)
	for _, b in buyers do
		local p = b.lastP or (b.to and Vector3.new(b.to.x, 0, b.to.z))
		if p then
			b.dist = (p - cam).Magnitude
			table.insert(scratch, b)
		end
	end
	for _, f in sellers do
		f.dist = (f.pos - cam).Magnitude
		table.insert(scratch, f)
	end
	table.sort(scratch, function(a, b)
		return a.dist < b.dist
	end)
	-- hysteresis: a rig stays with its person until they are well out of
	-- range; free rigs go to the nearest people without one (no churn)
	local held = 0
	for _, p in scratch do
		if p.rig then
			if p.dist > Crowd.RIG_RANGE * 1.4 then
				dropRig(p)
			else
				held += 1
			end
		end
	end
	for _, p in scratch do
		if held >= Crowd.MAX_RIGS or p.dist > Crowd.RIG_RANGE then
			break
		end
		if not p.rig then
			giveRig(p)
			if p.rig then
				held += 1
			end
		end
	end
end

local function placeOne(p, cf: CFrame, moving: boolean)
	if p.rig then
		rigs.place(p.rig, cf, moving, p.mood == "cheated")
	else
		simple.place(p.fig, cf, moving)
	end
end

-- place everyone for simulated time `now`; cam = the camera's position
function Crowd.update(now: number, cam: Vector3, dt: number)
	frame += 1
	if rigs and rigs.ready then
		rigClock -= dt
		if rigClock <= 0 then
			rigClock = RIG_EVERY
			chooseRigs(cam)
		end
	end
	for _, b in buyers do
		-- a figure standing still is placed once, until its next segment
		if not b.settled then
			local d = b.dist or (b.lastP and (b.lastP - cam).Magnitude) or 0
			local every = (b.rig or d < NEAR) and 1 or (d < MID and 2 or 4)
			if every == 1 or (frame + b.look) % every == 0 then
				local p, dir, moving = where(b, now)
				b.lastP = p
				local facing = b.facing
				if dir and dir.Magnitude > 1e-3 then
					facing = dir.Unit
				elseif FACE_STALL[b.state] and b.target then
					local f = sellers[b.target]
					if f then
						local v = (f.pos - p) * Vector3.new(1, 0, 1)
						if v.Magnitude > 1e-3 then
							facing = v.Unit
						end
					end
				end
				b.facing = facing or Vector3.new(0, 0, -1)
				placeOne(b, CFrame.lookAt(p, p + b.facing), moving)
				if not moving and now >= b.t0 then
					b.settled = true
				end
			end
		elseif b.dirty then
			b.dirty = false
			b.settled = false
		end
	end
	for _, f in sellers do
		if f.dirty then
			f.dirty = false
			placeOne(f, f.cf, false)
		end
	end
	simple.flush(dt, cam)
	if rigs then
		rigs.flush()
	end
end

return Crowd
