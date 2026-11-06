-- Visible deals: a coin arcs from the buyer to the counter, then the goods
-- arc back to the buyer. A scam takes the coin and nothing comes back: a red
-- cross pops over the buyer instead. Verdicts flash the stall: green allowed,
-- red blocked. Pooled parts, animated on the client; only near the camera.

local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)
local Theme = require(script.Parent.Theme)

local Effects = {}

local folder: Folder
local pool = {}
local flying = {}
local camPos = Vector3.zero
Effects.RANGE = 160 -- only draw deals this close to the camera
Effects.MAX = 24 -- in flight at once

function Effects.init(parent: Instance)
	folder = Instance.new("Folder")
	folder.Name = "Effects"
	folder.Parent = parent
end

local function take(kind: string): Part
	local p = table.remove(pool)
	if not p then
		p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
	end
	if kind == "coin" then
		p.Shape = Enum.PartType.Cylinder
		p.Size = Vector3.new(0.18, 0.9, 0.9)
		p.Color = Theme.GOLD
		p.Material = Enum.Material.Neon
	elseif kind == "cross" then
		p.Shape = Enum.PartType.Block
		p.Size = Vector3.new(1.4, 1.4, 0.2)
		p.Color = Theme.BAD
		p.Material = Enum.Material.Neon
	else
		p.Shape = Enum.PartType.Block
		p.Size = Vector3.new(0.9, 0.8, 0.9)
		p.Material = Enum.Material.SmoothPlastic
	end
	p.Transparency = 0
	p.Parent = folder
	return p
end

local function give(p: Part)
	p.Parent = nil
	table.insert(pool, p)
end

local function fly(p: Part, from: Vector3, to: Vector3, t0: number, dur: number, height: number, spin: boolean?)
	table.insert(flying, { p = p, from = from, to = to, t0 = t0, dur = dur, h = height, spin = spin })
end

-- a deal at the counter of `slot`; `buyerPos` where the buyer stands
-- a little "✕ counterfeit" over a buyer who just paid for a picture
local function fakeTag(at: Vector3)
	local a = Instance.new("Part")
	a.Anchored = true
	a.CanCollide = false
	a.CanQuery = false
	a.CanTouch = false
	a.Transparency = 1
	a.Size = Vector3.new(0.2, 0.2, 0.2)
	a.CFrame = CFrame.new(at)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.new(0, 150, 0, 30)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 120
	bb.Parent = a
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromScale(1, 1)
	l.BackgroundColor3 = Theme.BAD
	l.TextColor3 = Theme.WHITE
	l.Font = Theme.HEAVY
	l.TextSize = 18
	l.Text = "✕ counterfeit"
	l.Parent = bb
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 15)
	c.Parent = l
	a.Parent = folder
	task.delay(2.2, function()
		a:Destroy()
	end)
end

function Effects.deal(slot: number, buyerPos: Vector3?, good: string?, ok: boolean, counterfeit: boolean?)
	if #flying >= Effects.MAX then
		return
	end
	local L = Layout.SLOTS[slot]
	if not L then
		return
	end
	local counter = Vector3.new(L.pos.x + L.facing.x * (Layout.STALL_DEPTH / 2 - 1.2), 3.6, L.pos.z + L.facing.z * (Layout.STALL_DEPTH / 2 - 1.2))
	if (counter - camPos).Magnitude > Effects.RANGE then
		return
	end
	local hand = buyerPos and (buyerPos + Vector3.new(0, 3.8, 0)) or Vector3.new(L.front.x, 3.8, L.front.z)
	local now = os.clock()
	fly(take("coin"), hand, counter, now, 0.45, 2.2, true)
	if ok then
		local parcel = take("parcel")
		parcel.Color = good and Theme.GOODS[good] and Theme.GOODS[good].color or Theme.PAPER
		parcel.Transparency = 1
		fly(parcel, counter, hand, now + 0.5, 0.45, 2.0)
	else
		if counterfeit then
			-- what comes back is a picture: a flat frame in the good's colour
			local pic = take("parcel")
			pic.Size = Vector3.new(1.1, 0.85, 0.12)
			pic.Color = good and Theme.GOODS[good] and Theme.GOODS[good].color or Theme.PAPER
			pic.Transparency = 1
			fly(pic, counter, hand, now + 0.5, 0.45, 2.0)
		end
		local cross = take("cross")
		cross.Transparency = 1
		local above = hand + Vector3.new(0, 3.2, 0)
		fly(cross, above, above + Vector3.new(0, 1.5, 0), now + (counterfeit and 0.95 or 0.55), 1.1, 0)
		if counterfeit then
			task.delay(0.95, function()
				fakeTag(above + Vector3.new(0, 2.4, 0))
			end)
		end
	end
end

function Effects.update(cam: Vector3)
	camPos = cam
	local now = os.clock()
	local i = 1
	while i <= #flying do
		local f = flying[i]
		local u = (now - f.t0) / f.dur
		if u < 0 then
			i += 1
		elseif u >= 1 then
			give(f.p)
			flying[i] = flying[#flying]
			flying[#flying] = nil
		else
			local pos = f.from:Lerp(f.to, u) + Vector3.new(0, math.sin(u * math.pi) * f.h, 0)
			f.p.Transparency = (f.h == 0) and u * 0.8 or 0
			local cf = CFrame.new(pos)
			if f.spin then
				cf = cf * CFrame.Angles(0, u * 12, math.pi / 2)
			elseif f.h == 0 then
				cf = CFrame.lookAt(pos, cam) * CFrame.Angles(0, 0, math.rad(45))
			end
			f.p.CFrame = cf
			i += 1
		end
	end
end

return Effects
