-- The crowd: every trader drawn on the client. The server sends a buyer's
-- walk as (from, to, t0, t1); Layout.path turns that into the same waypoints
-- on every client, and each frame we place every figure where it should be.
-- Sellers stand behind their counters.
--
-- A figure is built by a `Figures` provider (simple parts now, pooled R15
-- rigs later) and moved with workspace:BulkMoveTo, the cheapest way to move
-- hundreds of parts a frame. Far figures update less often (LOD).

local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)
local Theme = require(script.Parent.Theme)

local Crowd = {}

local folder: Folder
local buyers: { [string]: any } = {}
local sellers: { [string]: any } = {} -- seller id -> figure standing at its stall
local figures -- the provider
local frame = 0

local WALKING = { walk = true, stroll = true, cheated = true }

function Crowd.init(parent: Instance, provider)
	folder = Instance.new("Folder")
	folder.Name = "Crowd"
	folder.Parent = parent
	figures = provider
	figures.init(folder)
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
		b = { id = e.id, look = e.look, fig = figures.take(e.look, "buyer") }
		buyers[e.id] = b
	end
	b.from, b.to, b.t0, b.t1, b.state, b.target = e.from, e.to, e.t0, e.t1, e.state, e.target
	if b.carry ~= e.carry then
		b.carry = e.carry
		figures.carry(b.fig, e.carry)
	end
	figures.mood(b.fig, e.state == "cheated" and "cheated" or nil)
	setPath(b)
end

function Crowd.buyerGone(id: string)
	local b = buyers[id]
	if b then
		figures.give(b.fig)
		buyers[id] = nil
	end
end

------------------------------------------------------------------ sellers

local STANDING = { open = true, setup = true, restock = true, blocked = true, shuttered = true }

function Crowd.seller(s)
	local f = sellers[s.id]
	if s.state == "gone" or s.state == "rejected" or not STANDING[s.state] then
		if f then
			figures.give(f.fig)
			sellers[s.id] = nil
		end
		return
	end
	if not f then
		f = { fig = figures.take(s.look or 1, "seller"), slot = s.slot }
		sellers[s.id] = f
		local L = Layout.SLOTS[s.slot]
		local p = Vector3.new(L.back.x, 0, L.back.z)
		f.cf = CFrame.lookAt(p, p + Vector3.new(L.facing.x, 0, L.facing.z))
	end
	-- a blocked or shuttered seller turns their back on the square
	local L = Layout.SLOTS[s.slot]
	local p = Vector3.new(L.back.x, 0, L.back.z)
	if s.state == "blocked" or s.state == "shuttered" then
		f.cf = CFrame.lookAt(p, p - Vector3.new(L.facing.x, 0, L.facing.z))
	else
		f.cf = CFrame.lookAt(p, p + Vector3.new(L.facing.x, 0, L.facing.z))
	end
	f.dirty = true
end

function Crowd.clear()
	for id in buyers do
		Crowd.buyerGone(id)
	end
	for id, f in sellers do
		figures.give(f.fig)
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

function Crowd.count(): (number, number)
	local nb, ns = 0, 0
	for _ in buyers do
		nb += 1
	end
	for _ in sellers do
		ns += 1
	end
	return nb, ns
end

-- place everyone for simulated time `now`; cam = the camera's position
-- LOD by distance: near figures update every frame, middle ones every 2nd,
-- far ones every 4th (staggered by `look`, so the work spreads evenly). A
-- figure that is standing still is placed once and left alone.
local NEAR, MID = 90, 200

function Crowd.update(now: number, cam: Vector3, dt: number)
	frame += 1
	for _, b in buyers do
		local d = b.lastP and (b.lastP - cam).Magnitude or 0
		local every = d < NEAR and 1 or (d < MID and 2 or 4)
		local far = every > 1
		local still = b.settled and b.settledT == b.t0
		if not still and (every == 1 or (frame + (b.look or 0)) % every == 0) then
			local p, d, moving = where(b, now)
			b.lastP = p
			local facing = b.facing
			if d and d.Magnitude > 1e-3 then
				facing = d.Unit
			elseif b.state == "deal" or b.state == "wait" or b.state == "queue" then
				-- face the stall
				if b.target then
					local f = sellers[b.target]
					if f then
						local dir = (f.cf.Position - p) * Vector3.new(1, 0, 1)
						if dir.Magnitude > 1e-3 then
							facing = dir.Unit
						end
					end
				end
			end
			b.facing = facing or Vector3.new(0, 0, -1)
			figures.place(b.fig, CFrame.lookAt(p, p + b.facing), moving, b.state, far)
			-- standing (browsing, waiting, dealing): nothing changes until the next segment
			b.settled = not moving and now >= b.t0
			b.settledT = b.t0
		end
	end
	for _, f in sellers do
		if f.dirty then
			f.dirty = false
			figures.place(f.fig, f.cf, false, "seller", false)
		end
	end
	figures.flush(dt, cam)
end

return Crowd
