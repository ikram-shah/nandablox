-- Small helpers shared by the NANDA Town replay: parts, labels, bubbles, animation.
-- Everything here works both in Studio edit mode (driven by a plugin / execute_luau)
-- and in a playtest client, so nothing depends on Players or on a character.

local RunService = game:GetService("RunService")

local Util = {}

Util.FONT = Enum.Font.BuilderSans
Util.FONT_BOLD = Enum.Font.BuilderSansBold
Util.FONT_HEAVY = Enum.Font.BuilderSansExtraBold

Util.ROLE_COLORS = {
	buyer = Color3.fromRGB(52, 120, 246),
	seller = Color3.fromRGB(245, 140, 30),
	auctioneer = Color3.fromRGB(150, 80, 220),
	issuer = Color3.fromRGB(150, 80, 220),
	bidder = Color3.fromRGB(40, 170, 120),
	attacker = Color3.fromRGB(220, 40, 40),
	forger = Color3.fromRGB(220, 40, 40),
	voter = Color3.fromRGB(70, 160, 200),
	supplier = Color3.fromRGB(200, 120, 60),
	manufacturer = Color3.fromRGB(170, 110, 70),
	agent = Color3.fromRGB(140, 140, 150),
}

Util.LAYER_COLORS = {
	town = Color3.fromRGB(120, 120, 130),
	transport = Color3.fromRGB(90, 160, 255),
	communication = Color3.fromRGB(120, 200, 255),
	identity = Color3.fromRGB(180, 140, 255),
	registry = Color3.fromRGB(110, 200, 120),
	auth = Color3.fromRGB(255, 90, 90),
	trust = Color3.fromRGB(255, 200, 40),
	payments = Color3.fromRGB(250, 170, 30),
	coordination = Color3.fromRGB(200, 120, 255),
	negotiation = Color3.fromRGB(255, 130, 70),
	memory = Color3.fromRGB(160, 160, 220),
	privacy = Color3.fromRGB(150, 150, 150),
	data_facts = Color3.fromRGB(230, 230, 230),
	agent = Color3.fromRGB(180, 180, 180),
	other = Color3.fromRGB(180, 180, 180),
}

function Util.roleColor(role: string?): Color3
	return Util.ROLE_COLORS[role or "agent"] or Util.ROLE_COLORS.agent
end

function Util.money(cents: number?): string
	if cents == nil then
		return "?"
	end
	local neg = cents < 0
	local c = math.abs(math.floor(cents + 0.5))
	local s = string.format("$%d.%02d", c // 100, c % 100)
	return neg and ("-" .. s) or s
end

function Util.part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		if k ~= "Parent" then
			(p :: any)[k] = v
		end
	end
	if props.Parent then
		p.Parent = props.Parent
	end
	return p
end

-- A box whose bottom sits on y=baseY, centred on (x, z).
function Util.box(parent: Instance, name: string, size: Vector3, x: number, z: number, color: Color3, extra: { [string]: any }?): Part
	local props = {
		Name = name,
		Size = size,
		CFrame = CFrame.new(x, size.Y / 2 + ((extra and extra.baseY) or 0), z),
		Color = color,
		Parent = parent,
	}
	if extra then
		for k, v in extra do
			if k ~= "baseY" then
				props[k] = v
			end
		end
	end
	return Util.part(props)
end

function Util.corner(parent: Instance, px: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px or 8)
	c.Parent = parent
	return c
end

function Util.label(parent: Instance, props: { [string]: any }): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = Util.FONT_BOLD
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextScaled = false
	t.TextSize = 18
	t.Size = UDim2.fromScale(1, 1)
	t.RichText = true
	for k, v in props do
		(t :: any)[k] = v
	end
	t.Parent = parent
	return t
end

-- A screen-space-sized label floating over a part (constant pixel size, so it
-- stays legible from the fixed overview camera). AlwaysOnTop stays false:
-- Studio's CaptureService (what the MCP screenshot uses) drops AlwaysOnTop
-- billboards, so layout keeps labels clear of geometry instead.
function Util.billboard(adornee: BasePart, w: number, h: number, offsetY: number, name: string?): BillboardGui
	local b = Instance.new("BillboardGui")
	b.Name = name or "Billboard"
	b.Adornee = adornee
	b.Size = UDim2.fromOffset(w, h)
	b.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	b.AlwaysOnTop = false
	b.LightInfluence = 0
	b.MaxDistance = 1000
	b.ResetOnSpawn = false
	b.Parent = adornee
	return b
end

-- A sign painted on one face of a part.
function Util.sign(part: BasePart, face: Enum.NormalId, text: string, opts: { [string]: any }?): TextLabel
	local o = opts or {}
	local g = Instance.new("SurfaceGui")
	g.Name = "Sign"
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = o.pps or 20
	g.LightInfluence = 0
	g.Adornee = part
	g.Parent = part
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = o.bg or Color3.fromRGB(30, 30, 36)
	bg.BackgroundTransparency = o.bgTransparency or 0
	bg.BorderSizePixel = 0
	bg.Parent = g
	local t = Util.label(bg, {
		Text = text,
		TextScaled = o.scaled ~= false,
		TextColor3 = o.color or Color3.new(1, 1, 1),
		Font = o.font or Util.FONT_HEAVY,
		TextWrapped = true,
		TextXAlignment = o.xalign or Enum.TextXAlignment.Center,
		TextYAlignment = o.yalign or Enum.TextYAlignment.Center,
	})
	if o.textSize then
		t.TextSize = o.textSize
	end
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, o.pad or 8)
	pad.PaddingRight = UDim.new(0, o.pad or 8)
	pad.PaddingTop = UDim.new(0, o.pad or 6)
	pad.PaddingBottom = UDim.new(0, o.pad or 6)
	pad.Parent = t
	return t
end

-- Animation ----------------------------------------------------------------

-- Everything runs on one virtual clock that advances by dt × speed each frame
-- unless paused, so the whole replay (scheduler, flights, bubbles) can be
-- paused mid-flight — handy for screenshots — or sped up.
Util.speed = 1
Util.paused = false
Util.clock = 0
local clockConn: RBXScriptConnection? = nil

function Util.startClock()
	if clockConn then
		clockConn:Disconnect()
	end
	Util.clock = 0
	Util.paused = false
	clockConn = RunService.Heartbeat:Connect(function(dt)
		if not Util.paused then
			Util.clock += dt * Util.speed
		end
	end)
end

function Util.now(): number
	return Util.clock
end

-- Yield until the virtual clock reaches `t`.
function Util.waitUntil(t: number)
	while Util.clock < t do
		RunService.Heartbeat:Wait()
	end
end

function Util.delay(seconds: number, fn: () -> ())
	local due = Util.clock + seconds
	task.spawn(function()
		Util.waitUntil(due)
		fn()
	end)
end

-- Run fn(alpha) every frame for `duration` virtual seconds (alpha 0..1), in its own thread.
function Util.animate(duration: number, fn: (number) -> (), done: (() -> ())?)
	task.spawn(function()
		local d = math.max(duration, 1 / 60)
		local t0 = Util.clock
		while true do
			local a = math.clamp((Util.clock - t0) / d, 0, 1)
			local ok, err = pcall(fn, a)
			if not ok then
				warn("[NandaTown] animate:", err)
				break
			end
			if a >= 1 then
				break
			end
			RunService.Heartbeat:Wait()
		end
		if done then
			done()
		end
	end)
end

function Util.wait(seconds: number)
	Util.waitUntil(Util.clock + seconds)
end

function Util.ease(a: number): number -- smoothstep
	return a * a * (3 - 2 * a)
end

function Util.bezier(p0: Vector3, p1: Vector3, p2: Vector3, a: number): Vector3
	local u = 1 - a
	return p0 * (u * u) + p1 * (2 * u * a) + p2 * (a * a)
end

-- Fly a part along an arc from `from` to `to`, peaking `height` studs above the midpoint.
function Util.fly(part: BasePart, from: Vector3, to: Vector3, height: number, duration: number, done: (() -> ())?)
	local mid = (from + to) / 2 + Vector3.new(0, height, 0)
	part.CFrame = CFrame.new(from)
	Util.animate(duration, function(a)
		if part:GetAttribute("Landed") then
			return -- someone placed it already (e.g. a crate stacked at the buyer's feet)
		end
		local e = Util.ease(a)
		local p = Util.bezier(from, mid, to, e)
		local ahead = Util.bezier(from, mid, to, math.min(e + 0.02, 1))
		if (ahead - p).Magnitude > 1e-3 then
			part.CFrame = CFrame.lookAt(p, ahead)
		else
			part.CFrame = CFrame.new(p) * (part.CFrame - part.CFrame.Position)
		end
	end, done)
end

-- Fade a BillboardGui's contents out and destroy it after `life` seconds.
function Util.expire(inst: Instance, life: number)
	Util.delay(life, function()
		if inst.Parent then
			inst:Destroy()
		end
	end)
end

return Util
