-- The square's landmarks: the clock tower with the price board on its face
-- (beyond the north gate, at the end of the street, so the overview sees it),
-- and the watchers' balcony over the south gate. Parts and materials only.

local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)
local Theme = require(script.Parent.Theme)

local Landmarks = {}

local STONE = Color3.fromRGB(196, 178, 152)
local STONE_DARK = Color3.fromRGB(150, 132, 110)
local ROOF = Color3.fromRGB(150, 70, 52)
local WOOD = Color3.fromRGB(110, 76, 50)

local handH, handM
local priceRows = {}
local towerCF: CFrame

local function part(parent, props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

-- a frame on `face` of `p`, pixels per stud `pps`
local function surface(p: BasePart, face, pps: number)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = pps
	g.LightInfluence = 0
	g.Brightness = 1.2
	g.MaxDistance = 1000
	g.Parent = p
	return g
end

------------------------------------------------------------------ clock tower

local function tower(parent)
	local th = math.pi / 2 -- north: +z
	local r = Layout.EDGE_R + 20
	local base = Vector3.new(r * math.cos(th), 0, r * math.sin(th))
	-- faces the square
	local cf = CFrame.lookAt(base, Vector3.new(0, 0, 0))
	towerCF = cf
	local m = Instance.new("Model")
	m.Name = "ClockTower"
	m.Parent = parent
	local W, H = 16, 58
	part(m, { Size = Vector3.new(W + 3, 3, W + 3), CFrame = cf * CFrame.new(0, 1.5, 0), Color = STONE_DARK, Material = Enum.Material.Cobblestone })
	part(m, { Size = Vector3.new(W, H, W), CFrame = cf * CFrame.new(0, H / 2, 0), Color = STONE, Material = Enum.Material.Limestone })
	-- string courses
	for _, y in { 14, 30, 46 } do
		part(m, { Size = Vector3.new(W + 1, 1, W + 1), CFrame = cf * CFrame.new(0, y, 0), Color = STONE_DARK, Material = Enum.Material.Limestone })
	end
	-- arched door
	part(m, { Size = Vector3.new(5, 9, 0.6), CFrame = cf * CFrame.new(0, 4.5, -W / 2 - 0.1), Color = WOOD, Material = Enum.Material.WoodPlanks })
	-- the roof
	local roof = Instance.new("WedgePart")
	roof.Anchored = true
	roof.CanCollide = false
	for i = 0, 3 do
		local w = roof:Clone()
		w.Size = Vector3.new(W + 2, 12, (W + 2) / 2)
		w.CFrame = cf * CFrame.new(0, H + 6, 0) * CFrame.Angles(0, i * math.pi / 2, 0) * CFrame.new(0, 0, -(W + 2) / 4)
		w.Color = ROOF
		w.Material = Enum.Material.Slate
		w.Parent = m
	end
	part(m, { Size = Vector3.new(0.6, 6, 0.6), CFrame = cf * CFrame.new(0, H + 15, 0), Color = Theme.GOLD, Material = Enum.Material.Foil })

	-- the clock face (toward the square)
	local face = part(m, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 11, 11),
		CFrame = cf * CFrame.new(0, 52, -W / 2 - 0.2) * CFrame.Angles(0, math.pi / 2, 0),
		Color = Color3.fromRGB(250, 244, 228),
		Material = Enum.Material.SmoothPlastic,
	})
	part(m, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 12, 12),
		CFrame = cf * CFrame.new(0, 52, -W / 2 - 0.05) * CFrame.Angles(0, math.pi / 2, 0),
		Color = Theme.GOLD,
		Material = Enum.Material.Foil,
	})
	for i = 0, 11 do
		local a = i * math.pi / 6
		part(m, {
			Size = Vector3.new(0.35, 1, 0.2),
			CFrame = cf * CFrame.new(math.sin(a) * 4.5, 52 + math.cos(a) * 4.5, -W / 2 - 0.6) * CFrame.Angles(0, 0, -a),
			Color = Theme.INK,
		})
	end
	local hub = cf * CFrame.new(0, 52, -W / 2 - 0.75)
	handH = part(m, { Size = Vector3.new(0.5, 3, 0.15), CFrame = hub, Color = Theme.INK })
	handM = part(m, { Size = Vector3.new(0.35, 4.4, 0.15), CFrame = hub, Color = Theme.INK })
	handH:SetAttribute("Hub", hub)
	_ = face

	-- the price board: a big slate on the tower, under the clock
	local board = part(m, {
		Size = Vector3.new(W - 1, 22, 0.6),
		CFrame = cf * CFrame.new(0, 26, -W / 2 - 0.35),
		Color = Color3.fromRGB(34, 40, 38),
		Material = Enum.Material.Slate,
	})
	part(m, { Size = Vector3.new(W + 0.2, 23, 0.4), CFrame = cf * CFrame.new(0, 26, -W / 2 - 0.15), Color = WOOD, Material = Enum.Material.Wood })
	local g = surface(board, Enum.NormalId.Front, 24)
	local list = Instance.new("Frame")
	list.Size = UDim2.fromScale(1, 1)
	list.BackgroundTransparency = 1
	list.Parent = g
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 16)
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = list
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 70)
	title.BackgroundTransparency = 1
	title.Font = Theme.HEAVY
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(250, 240, 210)
	title.Text = "TODAY'S PRICES"
	title.LayoutOrder = 0
	title.Parent = list
	for i, good in { "bread", "cloth", "lamp", "spice" } do
		local row = Instance.new("TextLabel")
		row.Size = UDim2.new(1, 0, 0, 84)
		row.BackgroundTransparency = 1
		row.Font = Theme.BOLD
		row.TextScaled = true
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = Color3.fromRGB(240, 236, 226)
		row.RichText = true
		row.Text = good
		row.LayoutOrder = i
		row.Parent = list
		priceRows[good] = row
	end
end

function Landmarks.prices(p, last)
	for good, row in priceRows do
		local v = p[good]
		if v then
			local arrow = ""
			if last and last[good] then
				if v > last[good] + 2 then
					arrow = ' <font color="#8EE08E">▲</font>'
				elseif v < last[good] - 2 then
					arrow = ' <font color="#F08A7A">▼</font>'
				end
			end
			row.Text = string.format("%s  %s   %s%s", Theme.GOODS[good].icon, good, Theme.money(v), arrow)
		end
	end
end

-- the clock shows the market's own time: one turn of the minute hand per
-- simulated minute, so the audience can see time pass
function Landmarks.clock(simT: number)
	if not handH then
		return
	end
	local hub = handH:GetAttribute("Hub")
	local mA = (simT % 60) / 60 * 2 * math.pi
	local hA = (simT % 720) / 720 * 2 * math.pi + math.pi * 0.3
	handM.CFrame = hub * CFrame.Angles(0, 0, -mA) * CFrame.new(0, 2.2, 0)
	handH.CFrame = hub * CFrame.Angles(0, 0, -hA) * CFrame.new(0, 1.5, -0.05)
end

------------------------------------------------------------------ balcony

local function balcony(parent)
	local th = 3 * math.pi / 2 -- south: -z
	local r = Layout.EDGE_R + 6
	local c = Vector3.new(r * math.cos(th), 0, r * math.sin(th))
	local cf = CFrame.lookAt(c, Vector3.new(0, 0, 0))
	local m = Instance.new("Model")
	m.Name = "Balcony"
	m.Parent = parent
	local W = 44
	-- the gallery over the gate: a house front with a balcony
	part(m, { Size = Vector3.new(W, 22, 8), CFrame = cf * CFrame.new(0, 11, 6), Color = Color3.fromRGB(214, 196, 168), Material = Enum.Material.Plaster })
	part(m, { Size = Vector3.new(W + 2, 1, 10), CFrame = cf * CFrame.new(0, 22.5, 6), Color = STONE_DARK, Material = Enum.Material.Limestone })
	-- the gate arch through it
	part(m, { Size = Vector3.new(Layout.STREET_HALF * 2, 10, 8.4), CFrame = cf * CFrame.new(0, 5, 6), Color = Color3.fromRGB(60, 50, 44), Material = Enum.Material.Slate, Transparency = 0 })
	-- the balcony floor, rail and banners
	part(m, { Size = Vector3.new(W - 6, 0.8, 5), CFrame = cf * CFrame.new(0, 13, -0.5), Color = STONE_DARK, Material = Enum.Material.Limestone })
	part(m, { Size = Vector3.new(W - 6, 0.4, 0.4), CFrame = cf * CFrame.new(0, 16.4, -2.8), Color = Color3.fromRGB(50, 46, 44), Material = Enum.Material.Metal })
	for x = -(W - 6) / 2, (W - 6) / 2, 2 do
		part(m, { Size = Vector3.new(0.2, 3.2, 0.2), CFrame = cf * CFrame.new(x, 14.9, -2.8), Color = Color3.fromRGB(50, 46, 44), Material = Enum.Material.Metal })
	end
	for i, x in { -16, -6, 6, 16 } do
		part(m, {
			Size = Vector3.new(4, 7, 0.15),
			CFrame = cf * CFrame.new(x, 9.8, -3),
			Color = (i % 2 == 0) and Color3.fromRGB(40, 80, 150) or Color3.fromRGB(176, 52, 60),
			Material = Enum.Material.Fabric,
		})
	end
	-- windows
	for _, x in { -15, -5, 5, 15 } do
		part(m, { Size = Vector3.new(3.5, 5, 0.3), CFrame = cf * CFrame.new(x, 16.5, 1.9), Color = Color3.fromRGB(40, 50, 60), Material = Enum.Material.Glass })
	end
	-- the sign
	local sign = part(m, { Size = Vector3.new(22, 3, 0.4), CFrame = cf * CFrame.new(0, 20.2, 1.8), Color = Color3.fromRGB(34, 40, 38), Material = Enum.Material.Slate })
	local g = surface(sign, Enum.NormalId.Front, 30)
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Theme.HEAVY
	t.TextScaled = true
	t.TextColor3 = Color3.fromRGB(250, 240, 210)
	t.Text = "THE WATCHERS"
	t.Parent = g
	Landmarks.balconyCF = cf * CFrame.new(0, 13.4, -0.5)
end

function Landmarks.build(parent: Instance)
	local f = Instance.new("Folder")
	f.Name = "Landmarks"
	f.Parent = parent
	tower(f)
	balcony(f)
	return f
end

function Landmarks.towerCFrame(): CFrame
	return towerCF
end

return Landmarks
