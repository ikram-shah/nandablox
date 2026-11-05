-- The market square, built on the client from Layout: ground, plaza and
-- fountain, streets and gates, and one stall per slot, drawn by state.
-- Parts and materials only.

local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)
local Theme = require(script.Parent.Theme)

local World = {}

local root: Folder
local stallsFolder: Folder
local stalls: { [number]: any } = {} -- slot -> drawn stall
local bySeller: { [string]: number } = {} -- seller id -> slot

local WOOD = Color3.fromRGB(120, 84, 56)
local WOOD_DARK = Color3.fromRGB(86, 60, 42)
local WOOD_LIGHT = Color3.fromRGB(168, 126, 86)
local STONE = Color3.fromRGB(176, 164, 150)
local COBBLE = Color3.fromRGB(150, 138, 124)
local PAVING = Color3.fromRGB(196, 182, 160)

local function part(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		if k ~= "Parent" then
			(p :: any)[k] = v
		end
	end
	p.Parent = props.Parent
	return p
end
World.part = part

local function cyl(props)
	props.Shape = Enum.PartType.Cylinder
	return part(props)
end

-- a disc lying flat: a cylinder whose axis is vertical
local function disc(parent, r: number, h: number, y: number, color: Color3, material, x: number?, z: number?)
	return cyl({
		Size = Vector3.new(h, 2 * r, 2 * r),
		CFrame = CFrame.new(x or 0, y, z or 0) * CFrame.Angles(0, 0, math.pi / 2),
		Color = color,
		Material = material,
		Parent = parent,
		CastShadow = false,
	})
end

------------------------------------------------------------------ the square

local function ring(parent, r: number, width: number, y: number, h: number, color: Color3, material, gaps: boolean?)
	local n = math.max(12, math.ceil(2 * math.pi * r / 7))
	local step = 2 * math.pi / n
	for k = 0, n - 1 do
		local th = (k + 0.5) * step
		local skip = false
		if gaps then
			for _, s in Layout.STREETS do
				if math.abs(Layout.delta(th, s)) * r < Layout.STREET_HALF then
					skip = true
				end
			end
		end
		if not skip then
			local len = 2 * r * math.sin(step / 2) + 0.4
			part({
				Size = Vector3.new(len, h, width),
				CFrame = CFrame.new(r * math.cos(th), y, r * math.sin(th)) * CFrame.Angles(0, -th + math.pi / 2, 0),
				Color = color,
				Material = material,
				Parent = parent,
				CastShadow = false,
			})
		end
	end
end

local function lamp(parent, x: number, z: number, h: number?)
	h = h or 11
	local pole = part({
		Size = Vector3.new(0.5, h, 0.5),
		CFrame = CFrame.new(x, h / 2, z),
		Color = Color3.fromRGB(40, 40, 44),
		Material = Enum.Material.Metal,
		Parent = parent,
	})
	part({
		Size = Vector3.new(1.4, 0.4, 1.4),
		CFrame = CFrame.new(x, h + 0.2, z),
		Color = Color3.fromRGB(40, 40, 44),
		Material = Enum.Material.Metal,
		Parent = parent,
	})
	local glow = part({
		Size = Vector3.new(1, 1.3, 1),
		CFrame = CFrame.new(x, h - 0.6, z),
		Color = Color3.fromRGB(255, 214, 150),
		Material = Enum.Material.Neon,
		Parent = parent,
		CastShadow = false,
	})
	local light = Instance.new("PointLight")
	light.Range = 18
	light.Brightness = 0.8
	light.Color = Color3.fromRGB(255, 200, 140)
	light.Shadows = false
	light.Parent = glow
	return pole
end

local function fountain(parent)
	local f = Instance.new("Folder")
	f.Name = "Fountain"
	f.Parent = parent
	local R = Layout.FOUNTAIN_R
	disc(f, R + 0.6, 2.2, 1.1, STONE, Enum.Material.Limestone)
	disc(f, R - 0.4, 2.3, 1.2, Color3.fromRGB(70, 120, 150), Enum.Material.Slate)
	local water = disc(f, R - 0.5, 0.3, 2.0, Color3.fromRGB(90, 170, 210), Enum.Material.Glass)
	water.Transparency = 0.25
	water.Reflectance = 0.15
	cyl({
		Size = Vector3.new(7, 2.2, 2.2),
		CFrame = CFrame.new(0, 4.5, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Color = STONE,
		Material = Enum.Material.Limestone,
		Parent = f,
	})
	disc(f, 4, 0.8, 7.6, STONE, Enum.Material.Limestone)
	local w2 = disc(f, 3.4, 0.3, 7.95, Color3.fromRGB(110, 190, 230), Enum.Material.Glass)
	w2.Transparency = 0.2
	part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.6, 1.6, 1.6),
		CFrame = CFrame.new(0, 9, 0),
		Color = Theme.GOLD,
		Material = Enum.Material.Foil,
		Parent = f,
	})
	-- water
	local spout = part({
		Size = Vector3.new(0.2, 0.2, 0.2),
		CFrame = CFrame.new(0, 9.4, 0),
		Transparency = 1,
		Parent = f,
	})
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Color = ColorSequence.new(Color3.fromRGB(200, 235, 255))
	pe.LightEmission = 0.3
	pe.Size = NumberSequence.new(0.35, 0.1)
	pe.Transparency = NumberSequence.new(0.2, 1)
	pe.Lifetime = NumberRange.new(1.0, 1.4)
	pe.Rate = 70
	pe.Speed = NumberRange.new(9, 12)
	pe.SpreadAngle = Vector2.new(18, 18)
	pe.Acceleration = Vector3.new(0, -24, 0)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Parent = spout
	return f
end

function World.build()
	root = Instance.new("Folder")
	root.Name = "MarketWorld"
	root.Parent = workspace

	local ground = Instance.new("Folder")
	ground.Name = "Ground"
	ground.Parent = root
	-- the land beyond, then the square
	part({
		Size = Vector3.new(900, 2, 900),
		CFrame = CFrame.new(0, -1.05, 0),
		Color = Color3.fromRGB(104, 128, 76),
		Material = Enum.Material.Grass,
		Parent = ground,
		CastShadow = false,
	})
	disc(ground, Layout.EDGE_R + 8, 1, -0.5, COBBLE, Enum.Material.Cobblestone)
	-- aisles: lighter paving rings
	for j = 0, Layout.AISLES - 1 do
		ring(ground, Layout.aisleRadius(j), Layout.AISLE_HALF * 2 - 0.5, 0.02, 0.1, PAVING, Enum.Material.Pavement)
	end
	-- the plaza
	disc(ground, Layout.PLAZA_R, 0.12, 0.03, Color3.fromRGB(210, 196, 172), Enum.Material.Limestone)
	ring(ground, Layout.PLAZA_R, 1.2, 0.12, 0.25, STONE, Enum.Material.Limestone)
	-- streets
	for _, s in Layout.STREETS do
		local len = Layout.EDGE_R + 30 - Layout.PLAZA_R
		local mid = Layout.PLAZA_R + len / 2
		part({
			Size = Vector3.new(len, 0.1, Layout.STREET_HALF * 2),
			CFrame = CFrame.new(mid * math.cos(s), 0.04, mid * math.sin(s)) * CFrame.Angles(0, -s, 0),
			Color = PAVING,
			Material = Enum.Material.Pavement,
			Parent = ground,
			CastShadow = false,
		})
	end
	-- the outer wall, broken by the four gates
	local wall = Instance.new("Folder")
	wall.Name = "Wall"
	wall.Parent = root
	local WR = Layout.EDGE_R + 6
	local n = math.ceil(2 * math.pi * WR / 8)
	for k = 0, n - 1 do
		local th = (k + 0.5) * 2 * math.pi / n
		local onStreet = false
		for _, s in Layout.STREETS do
			if math.abs(Layout.delta(th, s)) * WR < Layout.STREET_HALF + 3 then
				onStreet = true
			end
		end
		if not onStreet then
			part({
				Size = Vector3.new(8.3, 5, 1.6),
				CFrame = CFrame.new(WR * math.cos(th), 2.5, WR * math.sin(th)) * CFrame.Angles(0, -th + math.pi / 2, 0),
				Color = Color3.fromRGB(190, 170, 146),
				Material = Enum.Material.Brick,
				Parent = wall,
			})
		end
	end
	for _, s in Layout.STREETS do
		local c, sn = math.cos(s), math.sin(s)
		local tx, tz = -sn, c
		for _, side in { -1, 1 } do
			local x = WR * c + tx * side * (Layout.STREET_HALF + 1.5)
			local z = WR * sn + tz * side * (Layout.STREET_HALF + 1.5)
			part({
				Size = Vector3.new(3, 14, 3),
				CFrame = CFrame.new(x, 7, z),
				Color = Color3.fromRGB(176, 150, 120),
				Material = Enum.Material.Brick,
				Parent = wall,
			})
		end
		part({
			Size = Vector3.new(3, 2.5, Layout.STREET_HALF * 2 + 6),
			CFrame = CFrame.new(WR * c, 13.5, WR * sn) * CFrame.Angles(0, -s, 0),
			Color = Color3.fromRGB(176, 150, 120),
			Material = Enum.Material.Brick,
			Parent = wall,
		})
	end
	-- lamps along the streets
	local lamps = Instance.new("Folder")
	lamps.Name = "Lamps"
	lamps.Parent = root
	for _, s in Layout.STREETS do
		local c, sn = math.cos(s), math.sin(s)
		-- none at the plaza's edge: they would stand in the foreground of the close shots
		for j = 1, Layout.AISLES do
			local r = Layout.aisleRadius(j - 1) + 15
			-- one lamp per crossing, alternating sides, kept short: they frame
			-- the streets without walling off the view
			local side = (j % 2 == 0) and 1 or -1
			lamp(lamps, r * c - sn * side * (Layout.STREET_HALF - 0.8), r * sn + c * side * (Layout.STREET_HALF - 0.8), 8)
		end
	end
	fountain(root)

	stallsFolder = Instance.new("Folder")
	stallsFolder.Name = "Stalls"
	stallsFolder.Parent = root
	return root
end

------------------------------------------------------------------ stalls

local function signGui(p: BasePart, face, pps: number, bg: Color3, maxDist: number?)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = pps
	g.LightInfluence = 0.2
	g.MaxDistance = maxDist or 160
	g.Adornee = p
	g.Parent = p
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = bg
	f.BorderSizePixel = 0
	f.Parent = g
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextScaled = true
	t.Font = Theme.HEAVY
	t.TextColor3 = Theme.INK
	t.Parent = f
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.04, 0)
	pad.PaddingRight = UDim.new(0.04, 0)
	pad.PaddingTop = UDim.new(0.08, 0)
	pad.PaddingBottom = UDim.new(0.08, 0)
	pad.Parent = f
	return t, f
end

local function goodsOn(folder, good: string, cf: CFrame, look: number)
	local g = Theme.GOODS[good]
	local col = g.color
	local rng = Random.new(look)
	if good == "bread" then
		for i = 0, 5 do
			local x = -3.4 + i * 1.35
			part({
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.2, 0.7, 0.8),
				CFrame = cf * CFrame.new(x, 0.35, rng:NextNumber(-0.3, 0.3)) * CFrame.Angles(0, rng:NextNumber(-0.4, 0.4), 0),
				Color = col:Lerp(Color3.fromRGB(150, 90, 40), rng:NextNumber(0, 0.5)),
				Material = Enum.Material.Sand,
				Parent = folder,
			})
		end
	elseif good == "cloth" then
		for i = 0, 3 do
			local c = Color3.fromHSV((look * 0.17 + i * 0.23) % 1, 0.55, 0.8)
			cyl({
				Size = Vector3.new(1.9, 0.9, 0.9),
				CFrame = cf * CFrame.new(-3 + i * 2, 0.45, 0),
				Color = c,
				Material = Enum.Material.Fabric,
				Parent = folder,
			})
		end
	elseif good == "lamp" then
		for i = 0, 3 do
			local base = cf * CFrame.new(-3 + i * 2, 0, 0)
			part({
				Size = Vector3.new(0.7, 0.3, 0.7),
				CFrame = base * CFrame.new(0, 0.15, 0),
				Color = Color3.fromRGB(150, 110, 50),
				Material = Enum.Material.Metal,
				Parent = folder,
			})
			part({
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(0.9, 0.9, 0.9),
				CFrame = base * CFrame.new(0, 0.75, 0),
				Color = Color3.fromRGB(255, 210, 130),
				Material = Enum.Material.Neon,
				Parent = folder,
				CastShadow = false,
			})
		end
	else -- spice: bowls of colour
		local colors = { Color3.fromRGB(214, 92, 40), Color3.fromRGB(230, 170, 40), Color3.fromRGB(160, 40, 40), Color3.fromRGB(110, 120, 50) }
		for i = 0, 3 do
			local base = cf * CFrame.new(-3 + i * 2, 0, 0)
			cyl({
				Size = Vector3.new(0.6, 1.4, 1.4),
				CFrame = base * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.pi / 2),
				Color = Color3.fromRGB(110, 76, 50),
				Material = Enum.Material.Wood,
				Parent = folder,
			})
			part({
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.2, 0.6, 1.2),
				CFrame = base * CFrame.new(0, 0.6, 0),
				Color = colors[i + 1],
				Material = Enum.Material.Sand,
				Parent = folder,
			})
		end
	end
end

local function crate(folder, cf: CFrame, s: number?)
	s = s or 1.4
	part({
		Size = Vector3.new(s, s, s),
		CFrame = cf * CFrame.new(0, s / 2, 0),
		Color = WOOD_LIGHT,
		Material = Enum.Material.WoodPlanks,
		Parent = folder,
	})
end

-- build the fixed parts of a stall at a slot; the state-dependent parts are
-- swapped by World.setStall
local function buildStall(slot: number)
	local L = Layout.SLOTS[slot]
	local pos = Vector3.new(L.pos.x, 0, L.pos.z)
	local face = Vector3.new(L.facing.x, 0, L.facing.z)
	local cf = CFrame.lookAt(pos, pos + face) -- -Z faces the aisle
	local W, D = Layout.STALL_WIDTH, Layout.STALL_DEPTH
	local m = Instance.new("Model")
	m.Name = "Stall" .. slot
	local fixed = Instance.new("Folder")
	fixed.Name = "Fixed"
	fixed.Parent = m
	-- floor
	part({ Size = Vector3.new(W, 0.3, D), CFrame = cf * CFrame.new(0, 0.15, 0), Color = WOOD_DARK, Material = Enum.Material.WoodPlanks, Parent = fixed })
	-- back wall
	part({ Size = Vector3.new(W, 7, 0.4), CFrame = cf * CFrame.new(0, 3.5, D / 2 - 0.2), Color = WOOD, Material = Enum.Material.WoodPlanks, Parent = fixed })
	-- posts
	for _, x in { -W / 2 + 0.3, W / 2 - 0.3 } do
		part({ Size = Vector3.new(0.45, 8.5, 0.45), CFrame = cf * CFrame.new(x, 4.25, -D / 2 + 0.3), Color = WOOD_DARK, Material = Enum.Material.Wood, Parent = fixed })
		part({ Size = Vector3.new(0.45, 7.5, 0.45), CFrame = cf * CFrame.new(x, 3.75, D / 2 - 0.3), Color = WOOD_DARK, Material = Enum.Material.Wood, Parent = fixed })
	end
	-- counter
	local counter = part({ Size = Vector3.new(W - 1, 3, 1.4), CFrame = cf * CFrame.new(0, 1.5, -D / 2 + 1.2), Color = WOOD, Material = Enum.Material.WoodPlanks, Parent = fixed })
	part({ Size = Vector3.new(W - 0.6, 0.25, 1.8), CFrame = cf * CFrame.new(0, 3.1, -D / 2 + 1.2), Color = WOOD_LIGHT, Material = Enum.Material.Wood, Parent = fixed })
	-- the sign board above the front, both faces
	local board = part({ Size = Vector3.new(W - 1.5, 1.6, 0.3), CFrame = cf * CFrame.new(0, 9.6, -D / 2 + 0.1), Color = Color3.fromRGB(246, 236, 214), Material = Enum.Material.Wood, Parent = fixed })
	local nameLabel, nameBg = signGui(board, Enum.NormalId.Front, 18, Color3.fromRGB(246, 236, 214), 220)
	-- the price tag on the counter front
	local tag = part({ Size = Vector3.new(2.6, 1.1, 0.1), CFrame = cf * CFrame.new(W / 2 - 2.2, 2.1, -D / 2 + 0.47), Color = Color3.fromRGB(250, 248, 240), Parent = fixed })
	local priceLabel = signGui(tag, Enum.NormalId.Front, 30, Color3.fromRGB(250, 248, 240), 90)
	-- a little shelf on the back wall
	part({ Size = Vector3.new(W - 1.2, 0.2, 1), CFrame = cf * CFrame.new(0, 4.2, D / 2 - 0.9), Color = WOOD_LIGHT, Material = Enum.Material.Wood, Parent = fixed })

	local dyn = Instance.new("Folder")
	dyn.Name = "State"
	dyn.Parent = m
	m.Parent = stallsFolder
	return {
		slot = slot,
		model = m,
		fixed = fixed,
		dyn = dyn,
		cf = cf,
		counter = counter,
		board = board,
		nameLabel = nameLabel,
		nameBg = nameBg,
		priceLabel = priceLabel,
		shown = nil,
	}
end

local function awning(folder, cf: CFrame, good: string)
	local cols = Theme.GOODS[good].awning
	local W, D = Layout.STALL_WIDTH, Layout.STALL_DEPTH
	local stripes = 8
	local w = (W + 0.6) / stripes
	-- sloped from the back wall down over the counter
	local slope = CFrame.Angles(math.rad(-16), 0, 0)
	for i = 0, stripes - 1 do
		part({
			Size = Vector3.new(w, 0.2, D + 1.6),
			CFrame = cf * CFrame.new(-W / 2 - 0.3 + (i + 0.5) * w, 8.4, 0) * slope,
			Color = cols[i % 2 + 1],
			Material = Enum.Material.Fabric,
			Parent = folder,
		})
		-- the scalloped valance
		part({
			Size = Vector3.new(w, 0.8, 0.12),
			CFrame = cf * CFrame.new(-W / 2 - 0.3 + (i + 0.5) * w, 7.65, -D / 2 - 0.75),
			Color = cols[i % 2 + 1],
			Material = Enum.Material.Fabric,
			Parent = folder,
			CastShadow = false,
		})
	end
end

local function boards(folder, cf: CFrame, color: Color3)
	local W, D = Layout.STALL_WIDTH, Layout.STALL_DEPTH
	for i = 0, 4 do
		part({
			Size = Vector3.new(W + 0.2, 1.1, 0.25),
			CFrame = cf * CFrame.new(0, 1 + i * 1.5, -D / 2 - 0.05) * CFrame.Angles(0, 0, math.rad((i % 2 == 0) and 3 or -2)),
			Color = color,
			Material = Enum.Material.WoodPlanks,
			Parent = folder,
		})
	end
	for _, a in { 30, -30 } do
		part({
			Size = Vector3.new(W + 1.5, 0.7, 0.25),
			CFrame = cf * CFrame.new(0, 4, -D / 2 - 0.3) * CFrame.Angles(0, 0, math.rad(a)),
			Color = color:Lerp(Color3.new(0, 0, 0), 0.2),
			Material = Enum.Material.WoodPlanks,
			Parent = folder,
		})
	end
end

local function shutter(folder, cf: CFrame)
	local W, D = Layout.STALL_WIDTH, Layout.STALL_DEPTH
	part({
		Size = Vector3.new(W - 0.6, 7.6, 0.2),
		CFrame = cf * CFrame.new(0, 3.9, -D / 2 + 0.3),
		Color = Color3.fromRGB(70, 72, 78),
		Material = Enum.Material.CorrodedMetal,
		Parent = folder,
	})
	for i = 0, 9 do
		part({
			Size = Vector3.new(W - 0.5, 0.12, 0.3),
			CFrame = cf * CFrame.new(0, 0.6 + i * 0.75, -D / 2 + 0.2),
			Color = Color3.fromRGB(55, 56, 60),
			Material = Enum.Material.Metal,
			Parent = folder,
			CastShadow = false,
		})
	end
end

local STATE_SIGN = {
	setup = { "setting up", Color3.fromRGB(220, 214, 200) },
	blocked = { "BLOCKED", Color3.fromRGB(232, 84, 72) },
	shuttered = { "CLOSED", Color3.fromRGB(90, 90, 96) },
	rejected = { "REJECTED", Color3.fromRGB(232, 84, 72) },
}

-- draw a stall in its current state (s = MarketSim:publicSeller)
function World.setStall(s)
	local slot = s.slot
	if s.state == "gone" then
		local d = stalls[slot]
		if d and d.shown == s.id then
			d.model.Parent = nil
			d.shown = nil
		end
		bySeller[s.id] = nil
		return
	end
	local d = stalls[slot]
	if not d then
		d = buildStall(slot)
		stalls[slot] = d
	end
	d.model.Parent = stallsFolder
	bySeller[s.id] = slot
	-- the agent slot: a stall run by an outside agent wears a badge
	local external = s.policy == "external" and (s.state == "open" or s.state == "restock" or s.state == "setup")
	if external and not d.badge then
		local bb = Instance.new("BillboardGui")
		bb.Name = "AgentBadge"
		bb.Size = UDim2.new(0, 190, 0, 34)
		bb.StudsOffsetWorldSpace = Vector3.new(0, -3.2, 0) -- just under the sign, in the street shot
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.MaxDistance = 1000
		bb.Adornee = d.board
		local l = Instance.new("TextLabel")
		l.Size = UDim2.fromScale(1, 1)
		l.BackgroundColor3 = Theme.BLUE
		l.TextColor3 = Theme.WHITE
		l.Font = Theme.HEAVY
		l.TextSize = 18
		l.Parent = bb
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 17)
		c.Parent = l
		bb.Parent = d.model
		d.badge = bb
		d.badgeLabel = l
	end
	if d.badge then
		d.badge.Enabled = external
		d.badgeLabel.Text = "run by " .. tostring(s.label or "an outside agent")
	end
	local key = s.id .. ":" .. s.state .. ":" .. (s.good or "") .. ":" .. tostring(s.hasStock ~= false)
	d.nameLabel.Text = s.name
	local price = Theme.money(s.price)
	d.priceLabel.Text = price
	d.seller = s
	if d.key == key then
		return
	end
	d.key = key
	d.shown = s.id
	d.dyn:ClearAllChildren()
	local cf = d.cf
	local D = Layout.STALL_DEPTH
	local onCounter = cf * CFrame.new(0, 3.22, -D / 2 + 1.2)
	local st = s.state
	local sign = STATE_SIGN[st]
	if sign then
		d.nameBg.BackgroundColor3 = sign[2]
		d.nameLabel.TextColor3 = (st == "setup") and Theme.INK or Theme.WHITE
		if st ~= "setup" then
			d.nameLabel.Text = s.name .. " · " .. sign[1]
		end
	else
		d.nameBg.BackgroundColor3 = Color3.fromRGB(246, 236, 214)
		d.nameLabel.TextColor3 = Theme.INK
	end
	local stocked = s.hasStock ~= false
	if st == "open" then
		awning(d.dyn, cf, s.good)
		if stocked then
			goodsOn(d.dyn, s.good, onCounter, s.look or 1)
			-- spare stock on the shelf and crates in back
			goodsOn(d.dyn, s.good, cf * CFrame.new(0, 4.3, D / 2 - 0.9), (s.look or 1) + 7)
			crate(d.dyn, cf * CFrame.new(-2.4, 0.3, 1.0), 1.3)
			crate(d.dyn, cf * CFrame.new(2.2, 0.3, 1.0), 1.2)
		end
	elseif st == "restock" then
		awning(d.dyn, cf, s.good)
		crate(d.dyn, cf * CFrame.new(-2.5, 0.3, 0.8))
		crate(d.dyn, cf * CFrame.new(-1, 0.3, 1.2), 1.2)
		crate(d.dyn, cf * CFrame.new(-2.4, 1.7, 0.8), 1.1)
	elseif st == "setup" then
		-- awning furled; honest sellers have crates and goods ready, fraud storefronts are bare
		part({ Size = Vector3.new(Layout.STALL_WIDTH, 0.8, 0.8), CFrame = cf * CFrame.new(0, 8.4, D / 2 - 0.6), Color = Theme.GOODS[s.good].awning[1], Material = Enum.Material.Fabric, Parent = d.dyn })
		if stocked then
			goodsOn(d.dyn, s.good, onCounter, s.look or 1)
			crate(d.dyn, cf * CFrame.new(-2.4, 0.3, 1.0), 1.4)
			crate(d.dyn, cf * CFrame.new(2.2, 0.3, 1.0), 1.4)
			crate(d.dyn, cf * CFrame.new(-2.2, 1.7, 1.0), 1.1)
		end
	elseif st == "blocked" then
		boards(d.dyn, cf, Color3.fromRGB(150, 112, 76))
	elseif st == "shuttered" then
		shutter(d.dyn, cf)
	elseif st == "rejected" then
		boards(d.dyn, cf, Color3.fromRGB(170, 70, 60))
	end
end

function World.stallOf(sellerId: string)
	local slot = bySeller[sellerId]
	return slot and stalls[slot]
end

function World.slotOf(sellerId: string): number?
	return bySeller[sellerId]
end

local beaconPart: Part? = nil
local beaconRing: Part? = nil
local beaconHighlight: Highlight? = nil
local beaconSlot: number? = nil

function World.highlightSlot(slot: number?)
	beaconSlot = slot
	if not slot or not Layout.SLOTS[slot] then
		if beaconPart then
			beaconPart.Parent = nil
		end
		if beaconRing then
			beaconRing.Parent = nil
		end
		if beaconHighlight then
			beaconHighlight.Adornee = nil
		end
		return
	end
	local L = Layout.SLOTS[slot]
	if not beaconPart then
		beaconPart = cyl({
			Name = "InspectBeacon",
			Size = Vector3.new(36, 3.2, 3.2),
			Color = Color3.fromRGB(255, 220, 90),
			Material = Enum.Material.Neon,
			Transparency = 0.65,
			CastShadow = false,
		})
		beaconRing = cyl({
			Name = "InspectRing",
			Size = Vector3.new(0.35, 13, 13),
			Color = Color3.fromRGB(255, 220, 90),
			Material = Enum.Material.Neon,
			Transparency = 0.25,
			CastShadow = false,
		})
		local h = Instance.new("Highlight")
		h.FillColor = Color3.fromRGB(255, 220, 90)
		h.FillTransparency = 0.72
		h.OutlineColor = Color3.fromRGB(255, 235, 120)
		h.OutlineTransparency = 0
		h.Parent = root
		beaconHighlight = h
	end
	beaconPart.CFrame = CFrame.new(L.pos.x, 18, L.pos.z) * CFrame.Angles(0, 0, math.pi / 2)
	beaconPart.Parent = root
	beaconRing.CFrame = CFrame.new(L.pos.x, 0.22, L.pos.z) * CFrame.Angles(0, 0, math.pi / 2)
	beaconRing.Parent = root
	local d = stalls[slot]
	if beaconHighlight then
		beaconHighlight.Adornee = d and d.model or nil
	end
end

function World.focusedSlot(): number?
	return beaconSlot
end

function World.clearStalls()
	for _, d in stalls do
		d.model.Parent = nil
		d.shown = nil
		d.key = nil
	end
	bySeller = {}
end

return World
