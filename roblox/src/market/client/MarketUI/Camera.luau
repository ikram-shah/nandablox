-- The camera. Modes:
--   * "follow": automatically frames the stall of the TOP case in your Inbox
--     (no clicking needed — as you Allow/Block the top card, the camera glides
--     to the next top case's stall; when the inbox is empty, shows street/overview).
--   * "walk": 3rd-person street walk! Your watcher avatar walks the aisles with
--     WASD / Arrow keys (right-drag or Left/Right turns); clicking a case card
--     teleports your avatar right in front of that stall.
--   * "overview": high wide angle over the plaza.
--   * "balcony": from the watchers' balcony over the south gate (beat 5).
--   * "street": 1st-person eye-level aisle shot.

local UserInputService = game:GetService("UserInputService")
local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)
local Rigs = require(script.Parent.RigFigures)

local Cam = {}

local mode = "follow"
local t = 0
local dist = 60
local scripted = true
Cam.balconyCF = nil :: CFrame? -- set from Landmarks
Cam.inspectSlot = nil :: number?
Cam.topSlot = nil :: number?
Cam.onModeChange = nil :: ((string) -> ())?
local walkPos = Vector3.new(Layout.aisleRadius(0) * math.cos(Layout.HOME - 0.32), 0, Layout.aisleRadius(0) * math.sin(Layout.HOME - 0.32))
local walkYaw = -Layout.HOME + math.rad(15)
local avatarYaw = walkYaw
local walkPitch = math.rad(-12)
local dragging = false
local lastMouse = Vector2.zero
local avatarRig: any = nil

local function hideAvatar()
	if avatarRig then
		Rigs.give(avatarRig)
		avatarRig = nil
	end
end

local function ensureAvatar()
	if not avatarRig and Rigs.ready then
		avatarRig = Rigs.take(1, "buyer")
		if avatarRig then
			Rigs.label(avatarRig, "watcher · you")
		end
	end
	return avatarRig
end

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

-- V cycles: follow -> walk -> overview -> balcony -> street -> follow
local ORDER = { "follow", "walk", "overview", "balcony", "street" }
function Cam.toggle(): string
	local i = table.find(ORDER, mode) or 1
	local nextMode = ORDER[i % #ORDER + 1]
	Cam.set(nextMode)
	return mode
end

function Cam.mode(): string
	return mode
end

-- the beat's shot; nil = follow
function Cam.set(m: string?)
	if m == "auto" or m == nil then
		m = "follow"
	end
	if m == "walk" and mode ~= "walk" then
		local slot = Cam.inspectSlot or Cam.topSlot
		if slot and Layout.SLOTS[slot] then
			local L = Layout.SLOTS[slot]
			local f = Vector3.new(L.facing.x, 0, L.facing.z)
			local side = Vector3.new(-f.Z, 0, f.X)
			local counter = Vector3.new(L.pos.x, 0, L.pos.z)
			local stand = counter + f * 6.2 + side * 1.0
			local toStall = (counter - stand)
			local yaw = math.atan2(-toStall.X, -toStall.Z)
			walkPos = Vector3.new(stand.X, 0, stand.Z)
			walkYaw = yaw
			avatarYaw = yaw
			walkPitch = math.rad(-14)
		else
			local cam = workspace.CurrentCamera
			if cam then
				local look = cam.CFrame.LookVector
				walkYaw = math.atan2(-look.X, -look.Z)
				avatarYaw = walkYaw
				walkPitch = math.rad(-14)
				local ground = Vector3.new(cam.CFrame.Position.X, 0, cam.CFrame.Position.Z) + Vector3.new(look.X, 0, look.Z) * 3.0
				walkPos = Vector3.new(
					math.clamp(ground.X, -Layout.EDGE_R, Layout.EDGE_R),
					0,
					math.clamp(ground.Z, -Layout.EDGE_R, Layout.EDGE_R)
				)
			end
		end
	end
	mode = (m == "follow" or m == "walk" or m == "street" or m == "overview" or m == "balcony") and m or "follow"
	if mode ~= "walk" then
		hideAvatar()
	end
	if mode ~= "street" then
		Cam.inspectSlot = nil
	end
	if Cam.onModeChange then
		Cam.onModeChange(mode)
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
	-- Stand in the aisle 7.5 studs in front of the counter, facing the stall
	local stand = counter + f * 7.5 + side * 1.2
	local toStall = (counter - stand)
	local yaw = math.atan2(-toStall.X, -toStall.Z)
	walkPos = Vector3.new(stand.X, 0, stand.Z)
	walkYaw = yaw
	avatarYaw = yaw
	walkPitch = math.rad(-12)
	Cam.inspectSlot = slot
	Cam.set("walk")
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
	-- stand in the open aisle 9.5 studs from the counter, slightly to one side,
	-- at eye level: the sign, the counter goods/crates, and the seller in frame
	local L = Layout.SLOTS[slot]
	local f = Vector3.new(L.facing.x, 0, L.facing.z)
	local side = Vector3.new(-f.Z, 0, f.X)
	local counter = Vector3.new(L.pos.x, 0, L.pos.z)
	local sway = math.sin(t * 0.08) * 0.8
	local eye = counter + f * 9.5 + side * (1.8 + sway) + Vector3.new(0, 6.2, 0)
	return CFrame.lookAt(eye, counter + Vector3.new(0, 5.0, 0)), 62
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
	walkYaw += turn * 1.8 * dt

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
	local speed = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and 44 or 22
	local rot = CFrame.Angles(0, walkYaw, 0)
	local move = (rot.LookVector * fwd + rot.RightVector * strafe)
	local moving = move.Magnitude > 0.01
	if moving then
		local dir = move.Unit
		move = dir * speed * dt
		avatarYaw = math.atan2(-dir.X, -dir.Z)
	end
	walkPos = Vector3.new(
		math.clamp(walkPos.X + move.X, -Layout.EDGE_R - 20, Layout.EDGE_R + 20),
		0,
		math.clamp(walkPos.Z + move.Z, -Layout.EDGE_R - 20, Layout.EDGE_R + 20)
	)
	local rig = ensureAvatar()
	if rig then
		local footCF = CFrame.new(walkPos.X, 0, walkPos.Z) * CFrame.Angles(0, avatarYaw, 0)
		Rigs.place(rig, footCF, moving)
	end
	local head = Vector3.new(walkPos.X, 4.4, walkPos.Z)
	local camRot = CFrame.Angles(0, walkYaw, 0) * CFrame.Angles(walkPitch, 0, 0)
	local eye = head - camRot.LookVector * 8.5 + Vector3.new(0, 1.6, 0)
	local cf = CFrame.lookAt(eye, head + Vector3.new(0, 0.6, 0))
	return cf, 62
end

function Cam.update(dt: number, n: number)
	if not scripted then
		return
	end
	t += dt
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	-- pressing WASD / Arrow keys enters 3rd-person walk mode automatically
	if mode ~= "walk" and (
		UserInputService:IsKeyDown(Enum.KeyCode.W)
		or UserInputService:IsKeyDown(Enum.KeyCode.S)
		or UserInputService:IsKeyDown(Enum.KeyCode.Up)
		or UserInputService:IsKeyDown(Enum.KeyCode.Down)
	) then
		Cam.set("walk")
	end
	local m = mode
	local cf, fov
	if m == "walk" then
		cf, fov = walkStep(dt)
		local a = math.min(1, dt * 10)
		cam.CFrame = cam.CFrame:Lerp(cf, a)
		cam.FieldOfView += (fov - cam.FieldOfView) * a
		return
	elseif m == "follow" then
		local slot = Cam.inspectSlot or Cam.topSlot
		if slot and Layout.SLOTS[slot] then
			cf, fov = atStall(slot)
			local a = math.min(1, dt * 5.0)
			cam.CFrame = cam.CFrame:Lerp(cf, a)
			cam.FieldOfView += (fov - cam.FieldOfView) * a
			return
		end
		cf, fov = (n <= 50) and street(n) or overview(n, dt)
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
