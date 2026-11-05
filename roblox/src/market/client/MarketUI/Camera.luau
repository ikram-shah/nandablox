-- The camera. Four modes:
--   * "street": eye level (7 studs), standing in the first aisle near where
--     the market starts (Layout.HOME), looking along the aisle at the stalls,
--     so the nearest people are dressed R15 rigs at a counter.
--   * "overview": above and to one side, looking at the plaza. Low and close
--     for a small market, pulling up as N grows; the wide shot for 300+.
--   * "balcony": from the watchers' balcony over the south gate, looking out
--     over the square (beat 5).
--   * "walk": free exploration! WASD / Arrow keys walk along the aisles,
--     Q / E or PageUp / PageDown lift or lower, and right-drag or Q/E turns.
--     Clicking a case card teleports you right in front of that stall.
-- "auto" picks street for a small market and overview for a big one.

local UserInputService = game:GetService("UserInputService")
local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)

local Cam = {}

local mode = "auto"
local t = 0
local dist = 60
local scripted = true
Cam.balconyCF = nil :: CFrame? -- set from Landmarks
Cam.inspectSlot = nil :: number?
local walkPos = Vector3.new(Layout.aisleRadius(0) * math.cos(Layout.HOME - 0.32), 6.8, Layout.aisleRadius(0) * math.sin(Layout.HOME - 0.32))
local walkYaw = -Layout.HOME + math.rad(15)
local walkPitch = math.rad(-6)
local dragging = false
local lastMouse = Vector2.zero

function Cam.init()
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = 50
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			dragging = true
			lastMouse = UserInputService:GetMouseLocation()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local nowPos = UserInputService:GetMouseLocation()
			local delta = nowPos - lastMouse
			lastMouse = nowPos
			walkYaw -= delta.X * 0.0045
			walkPitch = math.clamp(walkPitch - delta.Y * 0.0035, math.rad(-55), math.rad(45))
			if mode ~= "walk" then
				mode = "walk"
			end
		end
	end)
end

-- V cycles: auto -> walk -> street -> overview -> balcony -> auto
local ORDER = { "auto", "walk", "street", "overview", "balcony" }
function Cam.toggle(): string
	local i = table.find(ORDER, mode) or 1
	local nextMode = ORDER[i % #ORDER + 1]
	Cam.set(nextMode)
	return mode
end

function Cam.mode(): string
	return mode
end

-- the beat's shot; nil = auto
function Cam.set(m: string?)
	if m == "walk" and mode ~= "walk" then
		local cam = workspace.CurrentCamera
		if cam then
			walkPos = Vector3.new(cam.CFrame.Position.X, math.clamp(cam.CFrame.Position.Y, 6.2, 40), cam.CFrame.Position.Z)
			local look = cam.CFrame.LookVector
			walkYaw = math.atan2(-look.X, -look.Z)
			walkPitch = math.clamp(math.asin(math.clamp(look.Y, -0.9, 0.9)), math.rad(-45), math.rad(35))
		end
	end
	mode = (m == "walk" or m == "street" or m == "overview" or m == "balcony") and m or "auto"
	if mode ~= "street" then
		Cam.inspectSlot = nil
	end
end

function Cam.visitStall(slot: number)
	local L = Layout.SLOTS[slot]
	if not L then
		return
	end
	local f = Vector3.new(L.facing.x, 0, L.facing.z)
	local side = Vector3.new(-f.Z, 0, f.X)
	local counter = Vector3.new(L.pos.x, 0, L.pos.z)
	local eye = counter + f * 13 + side * 2.5 + Vector3.new(0, 6.8, 0)
	local target = counter + Vector3.new(0, 5.2, 0)
	local cf = CFrame.lookAt(eye, target)
	local look = cf.LookVector
	walkPos = eye
	walkYaw = math.atan2(-look.X, -look.Z)
	walkPitch = math.clamp(math.asin(math.clamp(look.Y, -0.9, 0.9)), math.rad(-45), math.rad(35))
	Cam.inspectSlot = slot
	mode = "walk"
end

-- the radius the market fills at size n
local function extent(n: number): number
	local need = math.max(4, math.floor(n * 0.3 + 0.5)) * 1.3 + 6
	for a = 1, Layout.AISLES do
		if Layout.capacity(a) >= need then
			return Layout.aisleRadius(a - 1) + 10
		end
	end
	return Layout.EDGE_R
end

-- a stall to frame instead of the default aisle view (beat 6: the stall the
-- outside agent runs)
Cam.focusSlot = nil :: number?

local function atStall(slot: number): (CFrame, number)
	-- stand in the aisle a few studs from the counter, a little to one side,
	-- at eye level: the sign, the badge and the seller in frame
	local L = Layout.SLOTS[slot]
	local f = Vector3.new(L.facing.x, 0, L.facing.z)
	local side = Vector3.new(-f.Z, 0, f.X)
	local counter = Vector3.new(L.pos.x, 0, L.pos.z)
	local sway = math.sin(t * 0.08) * 1.5
	local eye = counter + f * 15 + side * (5 + sway) + Vector3.new(0, 8, 0)
	return CFrame.lookAt(eye, counter + Vector3.new(0, 7, 0)), 60
end

local function street(n: number): (CFrame, number)
	local slot = Cam.inspectSlot or Cam.focusSlot
	if slot and Layout.SLOTS[slot] then
		return atStall(slot)
	end
	-- stand in the first aisle a little before HOME and look along it; drift
	-- slowly back and forth so the shot breathes. In a crowded market lift a
	-- little, over the shoppers' heads.
	local A = Layout.aisleRadius(0)
	local th = Layout.HOME - 0.42 + math.sin(t * 0.05) * 0.08
	local y = 7 + 5 * math.clamp((n - 5) / 295, 0, 1)
	local eye = Vector3.new(A * math.cos(th), y, A * math.sin(th))
	local ahead = th + 0.38
	local look = Vector3.new((A - 1) * math.cos(ahead), 4.2, (A - 1) * math.sin(ahead))
	return CFrame.lookAt(eye, look), 55
end

local function overview(n: number, dt: number): (CFrame, number)
	dist += (extent(n) - dist) * math.min(1, dt * 0.8)
	-- k: 0 for a small market (low, close), 1 for the full square (high, wide)
	local k = math.clamp((dist - 44) / (Layout.EDGE_R - 44), 0, 1)
	local ang = Layout.HOME + t * 0.02 * k -- a small market holds still on its stalls
	local r = dist * (0.9 + 0.65 * k) + 16
	local h = 14 + dist * (0.3 + 0.9 * k)
	local eye = Vector3.new(r * math.cos(ang), h, r * math.sin(ang))
	-- look at the market's middle: the cluster when small, the plaza when big
	local focus = Layout.aisleRadius(0) * (1 - k)
	local look = Vector3.new(focus * math.cos(Layout.HOME), 0, focus * math.sin(Layout.HOME))
	local cf = CFrame.lookAt(eye, look)
	-- shift left a little, so the inbox on the right doesn't cover the middle
	return cf * CFrame.new(dist * 0.18, 0, 0), 50
end

local function balcony(): (CFrame, number)
	local b = Cam.balconyCF
	if not b then
		-- find it in the world (the watchers' balcony model) if nobody told us
		local w = workspace:FindFirstChild("MarketWorld")
		local m = w and w:FindFirstChild("Balcony", true)
		if m and m:IsA("Model") then
			local cf = m:GetBoundingBox()
			b = CFrame.lookAt(cf.Position, Vector3.new(0, cf.Position.Y, 0)) * CFrame.new(0, 2, -8)
			Cam.balconyCF = b
		end
	end
	if not b then
		return overview(300, 0)
	end
	-- a watcher's eye on the balcony, looking out over the square
	local eye = (b * CFrame.new(0, 5.5, 1)).Position
	local look = Vector3.new(0, 2, 0)
	return CFrame.lookAt(eye, look), 60
end

local function walkStep(dt: number): (CFrame, number)
	local turn = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.Left) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
		turn += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Right) or UserInputService:IsKeyDown(Enum.KeyCode.E) then
		turn -= 1
	end
	walkYaw += turn * 1.65 * dt

	local fwd = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
		fwd += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
		fwd -= 1
	end
	local strafe = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		strafe += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		strafe -= 1
	end
	local up = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.R) or UserInputService:IsKeyDown(Enum.KeyCode.PageUp) then
		up += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.F) or UserInputService:IsKeyDown(Enum.KeyCode.PageDown) then
		up -= 1
	end
	local speed = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and 56 or 28
	local rot = CFrame.Angles(0, walkYaw, 0)
	local move = (rot.LookVector * fwd + rot.RightVector * strafe)
	if move.Magnitude > 0 then
		move = move.Unit * speed * dt
	end
	walkPos = Vector3.new(
		math.clamp(walkPos.X + move.X, -Layout.EDGE_R - 20, Layout.EDGE_R + 20),
		math.clamp(walkPos.Y + up * 22 * dt, 5.5, 95),
		math.clamp(walkPos.Z + move.Z, -Layout.EDGE_R - 20, Layout.EDGE_R + 20)
	)
	local cf = CFrame.new(walkPos) * CFrame.Angles(0, walkYaw, 0) * CFrame.Angles(walkPitch, 0, 0)
	return cf, 60
end

function Cam.update(dt: number, n: number)
	if not scripted then
		return
	end
	t += dt
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	-- pressing WASD / Arrow keys enters walk mode automatically
	if mode ~= "walk" and (
		UserInputService:IsKeyDown(Enum.KeyCode.W)
		or UserInputService:IsKeyDown(Enum.KeyCode.S)
		or UserInputService:IsKeyDown(Enum.KeyCode.Up)
		or UserInputService:IsKeyDown(Enum.KeyCode.Down)
	) then
		Cam.set("walk")
	end
	local m = mode
	if m == "auto" then
		m = n <= 50 and "street" or "overview"
	end
	local cf, fov
	if m == "walk" then
		cf, fov = walkStep(dt)
		local a = math.min(1, dt * 10)
		cam.CFrame = cam.CFrame:Lerp(cf, a)
		cam.FieldOfView += (fov - cam.FieldOfView) * a
		return
	elseif m == "street" then
		cf, fov = street(n)
		dist = extent(n)
	elseif m == "balcony" then
		cf, fov = balcony()
	else
		cf, fov = overview(n, dt)
	end
	local a = math.min(1, dt * 2.2)
	cam.CFrame = cam.CFrame:Lerp(cf, a)
	cam.FieldOfView += (fov - cam.FieldOfView) * a
end

-- for screenshots and tests
function Cam.snap(cf: CFrame)
	scripted = false
	workspace.CurrentCamera.CFrame = cf
end

function Cam.release()
	scripted = true
end

return Cam
