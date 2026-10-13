-- Builds the static town square: plaza, roads, one civic building per layer the
-- run touches, and a block character per participant. Returns handles the
-- replay animates. Layout (studs, camera looks north from the south):
--
--            review wall (trust)   courthouse (data_facts)   notice board (registry)
--   gate (auth)          [seller stalls: negotiation]                 bank + vault (payments)
--                        ======== road (transport) ========
--                        [buyers]

local Util = require(script.Parent.Util)

local Town = {}

local STONE = Color3.fromRGB(236, 228, 210)
local DARK = Color3.fromRGB(45, 45, 52)

-- Which side of the square a role stands on.
local BACK_ROLES = { seller = true, supplier = true, manufacturer = true, auctioneer = true, issuer = true, acceptor = true }
local FRONT_ROLES = { buyer = true, bidder = true, voter = true, proposer = true, customer = true }

local function spread(n: number, width: number, maxGap: number): { number }
	local xs = {}
	if n <= 0 then
		return xs
	end
	local gap = math.min(maxGap, width / math.max(n - 1, 1))
	local x0 = -gap * (n - 1) / 2
	for i = 1, n do
		xs[i] = x0 + gap * (i - 1)
	end
	return xs
end

local function highlight(model: Instance, color: Color3): Highlight
	local h = Instance.new("Highlight")
	h.Name = "Flash"
	h.FillColor = color
	h.OutlineColor = color
	h.FillTransparency = 1
	h.OutlineTransparency = 1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = model
	h.Parent = model
	return h
end

-- One billboard per building: an optional info panel stacked on top of a title
-- plate ("BANK" / "payments · ledger.v1"). Its bottom edge sits `offsetY` studs
-- above the anchor, so the panel can never overlap its own title.
local TITLE_H = 46
local function signpost(anchor: BasePart, offsetY: number, title: string, sub: string, color: Color3, panel: { [string]: any }?)
	local w = math.max(230, panel and panel.w or 0)
	local ph = panel and (panel.h + 6) or 0
	local b = Util.billboard(anchor, w, TITLE_H + ph, offsetY, "Signpost")
	b.SizeOffset = Vector2.new(0, 0.5)
	local f = Instance.new("Frame")
	f.Name = "Title"
	f.AnchorPoint = Vector2.new(0.5, 1)
	f.Position = UDim2.fromScale(0.5, 1)
	f.Size = UDim2.fromOffset(230, TITLE_H)
	f.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
	f.BackgroundTransparency = 0.1
	f.Parent = b
	Util.corner(f, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 2
	stroke.Parent = f
	Util.label(f, { Text = title, Size = UDim2.new(1, 0, 0.58, 0), TextSize = 22, Font = Util.FONT_HEAVY, TextColor3 = color })
	Util.label(f, {
		Text = sub,
		Size = UDim2.new(1, 0, 0.42, 0),
		Position = UDim2.fromScale(0, 0.55),
		TextSize = 14,
		Font = Util.FONT,
		TextColor3 = Color3.fromRGB(220, 220, 220),
	})
	if not panel then
		return b, nil, nil
	end
	local pf = Instance.new("Frame")
	pf.Name = "Panel"
	pf.AnchorPoint = Vector2.new(0.5, 0)
	pf.Position = UDim2.fromScale(0.5, 0)
	pf.Size = UDim2.fromOffset(panel.w, panel.h)
	pf.BackgroundColor3 = Color3.fromRGB(250, 248, 240)
	pf.BackgroundTransparency = 0.05
	pf.Parent = b
	Util.corner(pf, 6)
	local pstroke = Instance.new("UIStroke")
	pstroke.Color = panel.color or color
	pstroke.Thickness = 3
	pstroke.Parent = pf
	local header = Util.label(pf, {
		Name = "Header",
		Text = panel.header,
		Size = UDim2.new(1, -12, 0, 20),
		Position = UDim2.fromOffset(6, 2),
		TextSize = 15,
		Font = Util.FONT_HEAVY,
		TextColor3 = Color3.fromRGB(40, 40, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local body = Util.label(pf, {
		Name = "Body",
		Text = panel.text or "",
		Size = UDim2.new(1, -12, 1, -24),
		Position = UDim2.fromOffset(6, 22),
		TextSize = 15,
		Font = Util.FONT_BOLD,
		TextColor3 = Color3.fromRGB(30, 30, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
	})
	return b, body, header
end

-- Title-only plate (roads, market).
local function titleBoard(anchor: BasePart, title: string, sub: string, color: Color3, offsetY: number): BillboardGui
	local b = signpost(anchor, offsetY, title, sub, color, nil)
	b.SizeOffset = Vector2.new(0, 0)
	return b
end

local function columns(parent: Instance, x0: number, x1: number, z: number, n: number, h: number, baseY: number)
	for i = 0, n - 1 do
		local x = x0 + (x1 - x0) * i / math.max(n - 1, 1)
		local c = Util.part({
			Name = "Column",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(h, 2.2, 2.2),
			CFrame = CFrame.new(x, baseY + h / 2, z) * CFrame.Angles(0, 0, math.rad(90)),
			Color = Color3.fromRGB(248, 245, 238),
			Parent = parent,
		})
		c.Material = Enum.Material.Marble
	end
end

------------------------------------------------------------------------ buildings

local function buildBank(root: Instance, layers: { [string]: string })
	local m = Instance.new("Model")
	m.Name = "Bank (payments)"
	m.Parent = root
	local x, z = 64, -6
	Util.box(m, "Steps", Vector3.new(30, 1.2, 24), x, z, Color3.fromRGB(205, 200, 190))
	local hall = Util.box(m, "Hall", Vector3.new(26, 14, 16), x, z - 2, STONE, { baseY = 1.2, Material = Enum.Material.Limestone })
	columns(m, x - 11, x + 11, z + 7.5, 5, 14, 1.2)
	local roof = Util.part({
		Name = "Pediment",
		Shape = Enum.PartType.Wedge,
		Size = Vector3.new(28, 6, 9),
		CFrame = CFrame.new(x, 1.2 + 14 + 0.5 + 3, z + 4) * CFrame.Angles(0, math.rad(180), 0),
		Color = STONE,
		Parent = m,
	})
	roof.Material = Enum.Material.Limestone
	Util.part({ Name = "Pediment2", Shape = Enum.PartType.Wedge, Size = Vector3.new(28, 6, 9), CFrame = CFrame.new(x, 1.2 + 14 + 0.5 + 3, z - 5), Color = STONE, Parent = m })
	local slab = Util.box(m, "Entablature", Vector3.new(28, 1, 19), x, z - 0.5, STONE, { baseY = 15.2 })
	Util.sign(slab, Enum.NormalId.Back, "BANK", { bg = STONE, color = Color3.fromRGB(120, 90, 20), pps = 12 })
	-- the vault: a steel strongroom on the plaza side, coins pile on its open top
	local vault = Util.box(m, "Vault", Vector3.new(11, 7, 9), x - 22, z + 10, Color3.fromRGB(85, 90, 100), { Material = Enum.Material.DiamondPlate })
	local door = Util.part({
		Name = "VaultDoor",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 5.2, 5.2),
		CFrame = CFrame.new(x - 22, 3.5, z + 14.7) * CFrame.Angles(0, math.rad(90), 0),
		Color = Color3.fromRGB(200, 165, 60),
		Material = Enum.Material.Metal,
		Parent = m,
	})
	door.Reflectance = 0.2
	local _, body = signpost(hall, 14, "BANK + VAULT", "payments · " .. (layers.payments or "ledger"), Util.LAYER_COLORS.payments,
		{ w = 210, h = 122, header = "LEDGER (must add up)" })
	return {
		model = m,
		anchor = Vector3.new(x - 22, 7, z + 10),
		vault = vault,
		vaultTop = Vector3.new(x - 22, 7.4, z + 10),
		panel = body,
		flash = highlight(m, Util.LAYER_COLORS.payments),
	}
end

local function buildCourthouse(root: Instance, layers: { [string]: string })
	local m = Instance.new("Model")
	m.Name = "Courthouse (data_facts)"
	m.Parent = root
	local x, z = 0, -56
	Util.box(m, "Steps1", Vector3.new(44, 1, 22), x, z + 2, Color3.fromRGB(210, 205, 195))
	Util.box(m, "Steps2", Vector3.new(40, 1, 19), x, z + 1, Color3.fromRGB(220, 215, 205), { baseY = 1 })
	local hall = Util.box(m, "Hall", Vector3.new(36, 15, 12), x, z - 2, STONE, { baseY = 2, Material = Enum.Material.Limestone })
	columns(m, x - 16, x + 16, z + 7, 7, 15, 2)
	local slab = Util.box(m, "Entablature", Vector3.new(38, 1.6, 17), x, z + 0.5, STONE, { baseY = 17 })
	Util.sign(slab, Enum.NormalId.Back, "COURTHOUSE  ·  EVIDENCE", { bg = STONE, color = Color3.fromRGB(60, 60, 70), pps = 14 })
	Util.part({ Name = "Pediment", Shape = Enum.PartType.Wedge, Size = Vector3.new(38, 6, 8.5), CFrame = CFrame.new(x, 18.6 + 3, z + 4.75) * CFrame.Angles(0, math.rad(180), 0), Color = STONE, Parent = m })
	Util.part({ Name = "Pediment2", Shape = Enum.PartType.Wedge, Size = Vector3.new(38, 6, 8.5), CFrame = CFrame.new(x, 18.6 + 3, z - 3.75), Color = STONE, Parent = m })
	local _, body, header = signpost(hall, 16, "COURTHOUSE", "data_facts · " .. (layers.data_facts or "evidence") .. " · verdict", Util.LAYER_COLORS.data_facts,
		{ w = 250, h = 44, header = "VERDICT", text = "court in session…", color = Color3.fromRGB(120, 120, 130) })
	return {
		model = m,
		anchor = Vector3.new(x, 3, z + 9),
		panel = body,
		header = header,
		flash = highlight(m, Color3.fromRGB(255, 255, 255)),
	}
end

local function buildNoticeBoard(root: Instance, layers: { [string]: string })
	local m = Instance.new("Model")
	m.Name = "Notice board (registry)"
	m.Parent = root
	local x, z = -44, -40
	for _, dx in { -8, 8 } do
		Util.box(m, "Post", Vector3.new(1.2, 13, 1.2), x + dx, z, Color3.fromRGB(110, 75, 45), { Material = Enum.Material.Wood })
	end
	local board = Util.box(m, "Board", Vector3.new(18, 9, 0.8), x, z + 0.5, Color3.fromRGB(170, 120, 75), { baseY = 3.5, Material = Enum.Material.Wood })
	Util.box(m, "Roof", Vector3.new(20, 0.8, 3), x, z + 0.5, Color3.fromRGB(120, 60, 40), { baseY = 13 })
	local _, body = signpost(board, 7, "NOTICE BOARD", "registry · " .. (layers.registry or "index"), Util.LAYER_COLORS.registry,
		{ w = 210, h = 84, header = "AGENT CARDS" })
	return {
		model = m,
		board = board,
		anchor = Vector3.new(x, 8, z + 1.2),
		panel = body,
		pinned = 0,
		flash = highlight(m, Util.LAYER_COLORS.registry),
	}
end

local function buildGate(root: Instance, layers: { [string]: string })
	local m = Instance.new("Model")
	m.Name = "Gate (auth)"
	m.Parent = root
	local x, z = -70, 2
	for _, dz in { -7, 7 } do
		Util.box(m, "Tower", Vector3.new(4, 14, 4), x, z + dz, Color3.fromRGB(150, 140, 130), { Material = Enum.Material.Cobblestone })
	end
	local lintel = Util.box(m, "Lintel", Vector3.new(4, 3, 18), x, z, Color3.fromRGB(150, 140, 130), { baseY = 14, Material = Enum.Material.Cobblestone })
	-- two guards
	for _, dz in { -3, 3 } do
		Util.box(m, "Guard", Vector3.new(2, 5, 2), x + 3, z + dz, Color3.fromRGB(40, 50, 90))
		Util.box(m, "GuardHead", Vector3.new(1.6, 1.6, 1.6), x + 3, z + dz, Color3.fromRGB(230, 200, 170), { baseY = 5 })
	end
	local title, body = signpost(lintel, 2.5, "GATE + GUARDS", "auth · " .. (layers.auth or "?"), Util.LAYER_COLORS.auth,
		{ w = 230, h = 44, header = "FORGED SIGNATURES STOPPED", text = "none so far" })
	return {
		model = m,
		anchor = Vector3.new(x + 3, 4, z),
		panel = body,
		stopped = 0,
		title = title,
		flash = highlight(m, Util.LAYER_COLORS.auth),
	}
end

local function buildReviewWall(root: Instance, layers: { [string]: string })
	local m = Instance.new("Model")
	m.Name = "Review wall (trust)"
	m.Parent = root
	local x, z = 44, -40
	local wall = Util.box(m, "Wall", Vector3.new(20, 10, 1.5), x, z, Color3.fromRGB(165, 85, 60), { Material = Enum.Material.Brick })
	Util.box(m, "Cap", Vector3.new(21, 0.8, 2.2), x, z, Color3.fromRGB(220, 210, 190), { baseY = 10 })
	local _, body = signpost(wall, 6.5, "REVIEW WALL  ★", "trust · " .. (layers.trust or "reputation"), Util.LAYER_COLORS.trust,
		{ w = 230, h = 104, header = "RECEIPTS & REPUTATION" })
	return {
		model = m,
		wall = wall,
		anchor = Vector3.new(x, 6, z + 1),
		panel = body,
		pinned = 0,
		flash = highlight(m, Util.LAYER_COLORS.trust),
	}
end

local function buildStall(root: Instance, name: string, x: number, z: number, color: Color3)
	local m = Instance.new("Model")
	m.Name = "Stall " .. name
	m.Parent = root
	-- counter in front of the seller, a striped backboard behind
	Util.box(m, "Counter", Vector3.new(12, 3.2, 3), x, z + 4.5, Color3.fromRGB(150, 105, 65), { Material = Enum.Material.WoodPlanks })
	-- stall colours stay neutral (red/white) so the seller's role colour stands out
	local red = Color3.fromRGB(200, 45, 45)
	Util.box(m, "CounterTop", Vector3.new(12.6, 0.4, 3.4), x, z + 4.5, Color3.fromRGB(235, 230, 220), { baseY = 3.2 })
	for i = 0, 5 do
		Util.box(m, "Stripe", Vector3.new(2, 11, 0.6), x - 5 + i * 2, z - 3.5, (i % 2 == 0) and red or Color3.fromRGB(250, 250, 245))
	end
	Util.box(m, "Awning", Vector3.new(13, 0.6, 2.4), x, z - 2.8, red, { baseY = 11 })
	return { model = m, anchor = Vector3.new(x, 4, z + 4.5), flash = highlight(m, Util.LAYER_COLORS.negotiation) }
end

------------------------------------------------------------------------ agents

local function buildAgent(root: Instance, p: { [string]: any }, pos: Vector3, facing: Vector3)
	local color = Util.roleColor(p.role)
	local m = Instance.new("Model")
	m.Name = p.name
	m.Parent = root
	local look = CFrame.lookAt(pos, pos + facing)
	local body = Util.part({ Name = "Body", Size = Vector3.new(6, 7.3, 3.6), CFrame = look * CFrame.new(0, 3.65, 0), Color = color, Parent = m })
	local head = Util.part({ Name = "Head", Size = Vector3.new(4.7, 4.7, 4.7), CFrame = look * CFrame.new(0, 9.65, 0), Color = Color3.fromRGB(245, 215, 180), Parent = m })
	for _, dx in { -1, 1 } do
		Util.part({ Name = "Eye", Size = Vector3.new(0.65, 0.9, 0.2), CFrame = look * CFrame.new(dx, 10.2, -2.4), Color = Color3.new(0, 0, 0), Parent = m })
	end
	Util.part({ Name = "Hat", Size = Vector3.new(5.1, 1.1, 5.1), CFrame = look * CFrame.new(0, 12.55, 0), Color = color, Parent = m })
	m.PrimaryPart = body

	-- One billboard holds the whole HUD stack: bubble / stars / name+balance.
	local gui = Util.billboard(head, 260, 160, 0, "AgentHud")
	gui.SizeOffset = Vector2.new(0, 0.5)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0)
	local stack = Instance.new("Frame")
	stack.BackgroundTransparency = 1
	stack.Size = UDim2.fromScale(1, 1)
	stack.Parent = gui
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 3)
	list.Parent = stack

	local bubble = Instance.new("Frame")
	bubble.Name = "Bubble"
	bubble.LayoutOrder = 1
	bubble.Size = UDim2.fromOffset(120, 30)
	bubble.BackgroundColor3 = Color3.new(1, 1, 1)
	bubble.Visible = false
	bubble.Parent = stack
	Util.corner(bubble, 12)
	local bstroke = Instance.new("UIStroke")
	bstroke.Thickness = 2
	bstroke.Color = Color3.fromRGB(40, 40, 40)
	bstroke.Parent = bubble
	local btext = Util.label(bubble, { Name = "Text", TextSize = 17, TextColor3 = Color3.fromRGB(20, 20, 20), Font = Util.FONT_BOLD })

	local stars = Util.label(stack, {
		Name = "Stars",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(200, 34),
		Text = "",
		TextSize = 30,
		Font = Util.FONT_HEAVY,
		TextColor3 = Color3.fromRGB(255, 205, 40),
		TextStrokeTransparency = 0.2,
		Visible = false,
	})

	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.LayoutOrder = 3
	plate.Size = UDim2.fromOffset(150, 40)
	plate.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
	plate.BackgroundTransparency = 0.2
	plate.Parent = stack
	Util.corner(plate, 8)
	local pstroke = Instance.new("UIStroke")
	pstroke.Color = color
	pstroke.Thickness = 2.5
	pstroke.Parent = plate
	Util.label(plate, { Name = "Name", Text = p.name, Size = UDim2.new(1, 0, 0.55, 0), TextSize = 18, Font = Util.FONT_HEAVY, TextColor3 = Color3.new(1, 1, 1) })
	local bal = Util.label(plate, {
		Name = "Balance",
		Text = p.role,
		Size = UDim2.new(1, 0, 0.45, 0),
		Position = UDim2.fromScale(0, 0.52),
		TextSize = 15,
		Font = Util.FONT_BOLD,
		TextColor3 = Color3.fromRGB(200, 230, 200),
	})

	m:SetAttribute("Role", p.role)
	return {
		name = p.name,
		role = p.role,
		color = color,
		model = m,
		body = body,
		head = head,
		pos = pos,
		chest = pos + Vector3.new(0, 5.5, 0),
		top = pos + Vector3.new(0, 13, 0),
		hud = gui,
		bubble = bubble,
		bubbleText = btext,
		bubbleToken = 0,
		stars = stars,
		balance = bal,
		crates = 0,
	}
end

------------------------------------------------------------------------ build

function Town.build(trace, parent: Instance)
	local old = parent:FindFirstChild("NandaTown")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "NandaTown"
	root.Parent = parent
	local layers = trace.layers or {}

	local ground = Util.part({
		Name = "Grass",
		Size = Vector3.new(2048, 1, 2048),
		CFrame = CFrame.new(0, -0.5, -10),
		Color = Color3.fromRGB(110, 165, 85),
		Material = Enum.Material.Grass,
		Parent = root,
	})
	ground.CastShadow = false
	local plaza = Util.part({
		Name = "Plaza",
		Size = Vector3.new(190, 0.2, 130),
		CFrame = CFrame.new(0, 0.1, -16),
		Color = Color3.fromRGB(222, 212, 190),
		Material = Enum.Material.Pavement,
		Parent = root,
	})
	plaza.CastShadow = false
	local road = Util.part({
		Name = "Road (transport)",
		Size = Vector3.new(170, 0.25, 9),
		CFrame = CFrame.new(-4, 0.2, 8),
		Color = Color3.fromRGB(70, 70, 78),
		Material = Enum.Material.Asphalt,
		Parent = root,
	})
	for i = -7, 7 do
		Util.part({ Name = "Dash", Size = Vector3.new(5, 0.3, 0.6), CFrame = CFrame.new(-4 + i * 11, 0.22, 8), Color = Color3.fromRGB(240, 220, 120), Parent = road })
	end
	Util.part({ Name = "Road N-S", Size = Vector3.new(8, 0.24, 70), CFrame = CFrame.new(0, 0.18, -22), Color = Color3.fromRGB(190, 180, 160), Material = Enum.Material.Cobblestone, Parent = root })
	local roadAnchor = Util.part({ Name = "RoadLabelAnchor", Size = Vector3.new(1, 1, 1), CFrame = CFrame.new(-36, 0.5, 15), Transparency = 1, Parent = root })
	local rt = titleBoard(roadAnchor, "ROADS + COURIERS", "transport · " .. (layers.transport or "?") .. " · ✉ = message", Util.LAYER_COLORS.transport, 0)
	rt.Size = UDim2.fromOffset(250, 46)

	local town = {
		root = root,
		agents = {},
		order = {},
		buildings = {},
		stalls = {},
		center = Vector3.new(0, 4, 0),
	}

	town.buildings.payments = buildBank(root, layers)
	town.buildings.data_facts = buildCourthouse(root, layers)
	town.buildings.registry = buildNoticeBoard(root, layers)
	town.buildings.auth = buildGate(root, layers)
	town.buildings.trust = buildReviewWall(root, layers)
	town.buildings.identity = town.buildings.registry

	-- agents: back row (sellers & co) at z=-14 behind stalls, front row (buyers & co) at z=+24,
	-- anyone else in a middle row.
	local back, front, middle = {}, {}, {}
	for _, p in trace.participants do
		if BACK_ROLES[p.role] then
			table.insert(back, p)
		elseif FRONT_ROLES[p.role] then
			table.insert(front, p)
		else
			table.insert(middle, p)
		end
	end
	local agentsFolder = Instance.new("Folder")
	agentsFolder.Name = "Agents"
	agentsFolder.Parent = root
	local function place(row, z: number, facing: Vector3, stalls: boolean)
		local xs = spread(#row, 110, 40)
		for i, p in row do
			local pos = Vector3.new(xs[i], 0.2, z)
			local a = buildAgent(agentsFolder, p, pos, facing)
			town.agents[p.name] = a
			table.insert(town.order, p.name)
			if stalls then
				town.stalls[p.name] = buildStall(root, p.name, xs[i], z, a.color)
			end
		end
	end
	place(back, -16, Vector3.new(0, 0, 1), true)
	place(middle, 2, Vector3.new(0, 0, -1), false)
	place(front, 26, Vector3.new(0, 0, -1), false)
	if next(town.stalls) then
		local anchor = Util.part({ Name = "MarketLabelAnchor", Size = Vector3.new(1, 1, 1), CFrame = CFrame.new(0, 0.5, -24), Transparency = 1, Parent = root })
		titleBoard(anchor, "MARKET STALLS", "negotiation · " .. (layers.negotiation or "?"), Util.LAYER_COLORS.negotiation, 0)
	end
	return town
end

return Town
