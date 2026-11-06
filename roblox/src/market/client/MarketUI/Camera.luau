-- The camera. Modes:
--   * "auto": follow (below), except that above Cam.AUTO_WIDE_ABOVE traders it
--     holds the overview instead of chasing the top case; a stall you pick
--     still wins. Cam.mode() says "follow"; Cam.modeName() says "auto".
--   * "follow": automatically frames the stall of the TOP case in your Inbox
--     (no clicking needed — as you Allow/Block the top card, the camera glides
--     to the next top case's stall; when the inbox is empty, shows street/overview).
--   * "walk": 3rd-person street walk! Your watcher avatar walks the aisles with
--     WASD / Arrow keys (right-drag or Left/Right turns); clicking a case card
--     teleports your avatar right in front of that stall.
--   * "overview": high wide angle over the plaza.
--   * "balcony": from the watchers' balcony over the south gate (beat 5).
--   * "street": 1st-person eye-level aisle shot.
--   * "stall": a Red player minding their own scam/counterfeit stall: their
--     avatar stands behind its counter, seen from the aisle.
-- When the market grows (in follow, auto or walk) the camera sweeps out to the
-- overview for Cam.SWEEP_SECONDS so the new scale shows, then glides back.
-- The stall being framed is passed to Effects.focus, so only its popups play
-- full size.

local UserInputService = game:GetService("UserInputService")
local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)
local Rigs = require(script.Parent.RigFigures)
local Avatars = require(Market.Avatars)
-- (so popups from other stalls stay out of the way of the one you are looking at)
local Effects = require(script.Parent.Effects)

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
local myRole = "blue"
-- (nil headless; your rig is your real avatar once the server has built it)
local localPlayer = game:GetService("Players").LocalPlayer
local myUserId: number? = localPlayer and localPlayer.UserId or nil
local lastMoving = false
local peers: { [string]: { id: string, num: number, role: string, x: number, z: number, tx: number, tz: number, yaw: number, moving: boolean, rig: any, stall: string? } } = {}
-- the stall a Red player is minding ("stall" mode)
local mindSlot: number? = nil
local mindName: string? = nil

-- "auto": follow, except that above AUTO_WIDE_ABOVE traders the camera holds
-- the overview instead of chasing the inbox's top case (a stall you picked
-- still wins). Strictly above, so at the beats' 300 "auto" is plain follow.
Cam.AUTO_WIDE_ABOVE = 300
local auto = false
-- The market grew (a size button, a beat, a round phase): sweep out to the
-- overview for a few seconds so the new scale is visible, then come back.
-- Walking, dragging the view, or picking a stall ends it early.
Cam.SWEEP_SECONDS = 6
local sweepLeft = 0
local easeLeft = 0 -- after a sweep, glide back instead of snapping
local lastN: number? = nil
local lastInspect: number? = nil
-- the stall a card's "visit" walked you to (Cam.set clears inspectSlot in walk)
local visitSlot: number? = nil

local BLUE_SHIRT = Color3.fromRGB(48, 114, 214)
local RED_SHIRT = Color3.fromRGB(214, 56, 52)

local function stylePlayerRig(rig: any, role: string, who: string, stall: string?)
	if not rig then
		return
	end
	local isRed = role == "red"
	Rigs.setTeam(rig, isRed and RED_SHIRT or BLUE_SHIRT)
	local title = (isRed and "RED SCAMMER · " or "BLUE WATCHER · ") .. who
	if isRed and stall then
		title = "RED · " .. stall
	end
	local minding = isRed and stall ~= nil
	Rigs.label(rig, title, isRed and "red" or "blue", not minding)
	if rig.tag then
		-- behind a counter the badge sits lower, under the awning's valance
		rig.tag.StudsOffsetWorldSpace = Vector3.new(0, minding and 1.15 or 2.3, 0)
	end
end

local function hideAvatar()
	if avatarRig then
		Rigs.give(avatarRig)
		avatarRig = nil
	end
end

-- a stock stand-in whose player's real avatar has since arrived: swap it
local function stale(rig: any, userId: number?): boolean
	return rig ~= nil and rig.userId == nil and Rigs.hasAvatar(userId)
end

local function ensureAvatar()
	if stale(avatarRig, myUserId) then
		hideAvatar()
	end
	if not avatarRig and Rigs.ready then
		avatarRig = Rigs.takePlayer(myUserId, myRole)
	end
	if avatarRig then
		stylePlayerRig(avatarRig, myRole, "you", mode == "stall" and mindName or nil)
	end
	return avatarRig
end

function Cam.setRole(role: string)
	if role ~= "blue" and role ~= "red" then
		return
	end
	myRole = role
	if avatarRig then
		stylePlayerRig(avatarRig, myRole, "you")
	end
end

function Cam.role(): string
	return myRole
end

function Cam.pose()
	if mode == "stall" and mindSlot and Layout.SLOTS[mindSlot] then
		local L = Layout.SLOTS[mindSlot]
		return { x = L.back.x, z = L.back.z, yaw = math.atan2(-L.facing.x, -L.facing.z), moving = false, mind = mindSlot }
	end
	return { x = walkPos.X, z = walkPos.Z, yaw = avatarYaw, moving = lastMoving }
end

-- Red: stand behind your own stall's counter (nil: stop minding it)
function Cam.mind(slot: number?, name: string?)
	mindSlot = slot
	mindName = name
	if slot then
		Cam.set("stall")
	elseif mode == "stall" then
		Cam.set("follow")
	end
end

function Cam.minding(): number?
	return mode == "stall" and mindSlot or nil
end

function Cam.syncPlayers(list: { any }?, myId: string?)
	if type(list) ~= "table" then
		return
	end
	local seen = {}
	for _, p in list do
		if type(p) == "table" and type(p.id) == "string" then
			if p.id == myId then
				-- (your own team is the client's to follow: MarketClient)
			else
				seen[p.id] = true
				local e = peers[p.id]
				if not e then
					e = {
						id = p.id,
						num = p.num or 2,
						role = p.role or "red",
						x = p.x or 0,
						z = p.z or 34,
						tx = p.x or 0,
						tz = p.z or 34,
						yaw = p.yaw or 0,
						moving = p.moving == true,
						rig = nil,
					}
					peers[p.id] = e
				else
					e.num = p.num or e.num
					e.role = p.role or e.role
					e.tx = p.x or e.tx
					e.tz = p.z or e.tz
					e.yaw = p.yaw or e.yaw
					e.moving = p.moving == true
				end
				e.stall = p.stall
			end
		end
	end
	for id, e in peers do
		if not seen[id] then
			if e.rig then
				Rigs.give(e.rig)
			end
			peers[id] = nil
		end
	end
end

local function stepPeers(dt: number)
	if not Rigs.ready then
		return
	end
	local a = math.min(1, dt * 10)
	for _, e in peers do
		local uid = Avatars.userIdFromPlayerId(e.id)
		if stale(e.rig, uid) then
			Rigs.give(e.rig)
			e.rig = nil
		end
		if not e.rig then
			e.rig = Rigs.takePlayer(uid, e.role)
		end
		if e.rig then
			stylePlayerRig(e.rig, e.role, "Player " .. tostring(e.num or 2), e.stall)
			local dx = e.tx - e.x
			local dz = e.tz - e.z
			local distSq = dx * dx + dz * dz
			if distSq > 30 * 30 then
				-- a jump (to their stall's counter): snap, don't glide through the stalls
				e.x, e.z = e.tx, e.tz
				distSq = 0
			else
				e.x += dx * a
				e.z += dz * a
			end
			local footCF = CFrame.new(e.x, 0, e.z) * CFrame.Angles(0, e.yaw, 0)
			Rigs.place(e.rig, footCF, e.moving or distSq > 0.25)
		end
	end
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
			sweepLeft = 0
			if mode ~= "walk" then
				mode = "walk"
				auto = false
			end
		end
	end)
end

-- V cycles: auto -> follow -> walk -> overview -> balcony -> street -> auto
local ORDER = { "auto", "follow", "walk", "overview", "balcony", "street" }

-- the mode as the camera row names it: "auto" is follow with the wide rule
function Cam.modeName(): string
	return (auto and mode == "follow") and "auto" or mode
end

function Cam.toggle(): string
	local i = table.find(ORDER, Cam.modeName()) or 1
	local nextMode = ORDER[i % #ORDER + 1]
	Cam.set(nextMode)
	return Cam.modeName()
end

-- (still "follow" in auto, so the follow-mode stall highlight keeps working)
function Cam.mode(): string
	return mode
end

-- seconds left of the scale sweep (0 when not sweeping)
function Cam.sweeping(): number
	return sweepLeft
end

-- the beat's shot; nil = follow, "auto" = follow with the wide rule
function Cam.set(m: string?)
	auto = m == "auto"
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
	if m == "stall" and not mindSlot then
		m = "follow"
	end
	mode = (m == "follow" or m == "walk" or m == "street" or m == "overview" or m == "balcony" or m == "stall") and m or "follow"
	if mode ~= "walk" and mode ~= "stall" then
		hideAvatar()
	end
	if mode ~= "street" then
		Cam.inspectSlot = nil
	end
	if mode ~= "follow" then
		auto = false
	end
	if mode ~= "walk" then
		visitSlot = nil
	end
	if Cam.onModeChange then
		Cam.onModeChange(Cam.modeName())
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
	sweepLeft = 0
	Cam.set("walk")
	visitSlot = slot
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
	lastMoving = moving
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
	stepPeers(dt)
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
	-- the market grew: start the scale sweep (not on join, while the first
	-- meter arrives; not for a Red player behind their counter; not over a
	-- beat's scripted street or balcony shot, nor when already wide)
	if lastN and n > lastN and t > 4 and (mode == "follow" or mode == "walk") then
		sweepLeft = Cam.SWEEP_SECONDS
	end
	lastN = n
	-- picking a stall (a card, a test hook) ends it
	if Cam.inspectSlot ~= nil and Cam.inspectSlot ~= lastInspect then
		sweepLeft = 0
	end
	lastInspect = Cam.inspectSlot
	if sweepLeft > 0 and mode ~= "stall" then
		sweepLeft = math.max(0, sweepLeft - dt)
		if mode == "walk" then
			walkStep(dt) -- (keeps your avatar placed; moving ends the sweep)
			if lastMoving then
				sweepLeft = 0
			end
		end
		if sweepLeft > 0 then
			Effects.focus(nil)
			local scf, sfov = overview(n, dt)
			local a = math.min(1, dt * 1.6)
			cam.CFrame = cam.CFrame:Lerp(scf, a)
			cam.FieldOfView += (sfov - cam.FieldOfView) * a
			easeLeft = 1.5
			return
		end
	end
	easeLeft = math.max(0, easeLeft - dt)
	-- how fast the shot catches up: as given, or gently just after a sweep
	local function rate(k: number): number
		return math.min(1, dt * (easeLeft > 0 and math.min(k, 2.0) or k))
	end
	local m = mode
	local cf, fov
	if m == "stall" and mindSlot and Layout.SLOTS[mindSlot] then
		Effects.focus(mindSlot)
		lastMoving = false
		local L = Layout.SLOTS[mindSlot]
		local rig = ensureAvatar()
		if rig then
			local p = Vector3.new(L.back.x, 0, L.back.z)
			local face = Vector3.new(L.facing.x, 0, L.facing.z)
			Rigs.place(rig, CFrame.lookAt(p, p + face), false)
		end
		-- from the aisle, a little to one side and above eye level: the sign,
		-- the counter (sacks, or framed prints), and you behind it
		local f = Vector3.new(L.facing.x, 0, L.facing.z)
		local side = Vector3.new(-f.Z, 0, f.X)
		local counter = Vector3.new(L.pos.x, 0, L.pos.z)
		-- (not much further out: across the aisle stand the next row's stalls)
		-- high enough to see you over the buyers queuing at the counter
		-- (and low enough to see your badge under the awning's valance)
		local eye = counter + f * 11.5 + side * 1.6 + Vector3.new(0, 8.6, 0)
		cf, fov = CFrame.lookAt(eye, counter + Vector3.new(0, 5.2, 0)), 64
		local a = rate(4)
		cam.CFrame = cam.CFrame:Lerp(cf, a)
		cam.FieldOfView += (fov - cam.FieldOfView) * a
		return
	elseif m == "walk" then
		cf, fov = walkStep(dt)
		-- the stall you walked to (a card's visit) while you are still near it
		local near = nil
		local S = visitSlot and Layout.SLOTS[visitSlot]
		if S and (Vector3.new(S.pos.x, 0, S.pos.z) - walkPos).Magnitude < 25 then
			near = visitSlot
		end
		Effects.focus(near)
		local a = rate(10)
		cam.CFrame = cam.CFrame:Lerp(cf, a)
		cam.FieldOfView += (fov - cam.FieldOfView) * a
		return
	elseif m == "follow" then
		lastMoving = false
		-- auto, in a big market: hold the overview unless you picked a stall
		local wide = auto and n > Cam.AUTO_WIDE_ABOVE
		local slot = Cam.inspectSlot or (not wide and Cam.topSlot or nil)
		if slot and Layout.SLOTS[slot] then
			Effects.focus(slot)
			-- Also move our logical position in front of this stall so other players
			-- see our avatar standing at the stall we are inspecting!
			local L = Layout.SLOTS[slot]
			local f = Vector3.new(L.facing.x, 0, L.facing.z)
			local side = Vector3.new(-f.Z, 0, f.X)
			local counter = Vector3.new(L.pos.x, 0, L.pos.z)
			local stand = counter + f * 7.2 - side * 2.2
			local toStall = counter - stand
			walkPos = Vector3.new(stand.X, 0, stand.Z)
			avatarYaw = math.atan2(-toStall.X, -toStall.Z)
			cf, fov = atStall(slot)
			local a = rate(5.0)
			cam.CFrame = cam.CFrame:Lerp(cf, a)
			cam.FieldOfView += (fov - cam.FieldOfView) * a
			return
		end
		-- (not `a and street(n) or overview(...)`: that keeps only the first
		-- return value, fov came back nil and every frame errored here)
		Effects.focus(nil)
		if n <= 50 and not wide then
			cf, fov = street(n)
		else
			cf, fov = overview(n, dt)
		end
	elseif m == "street" then
		lastMoving = false
		local fs = Cam.inspectSlot or Cam.focusSlot
		Effects.focus(fs and Layout.SLOTS[fs] and fs or nil)
		cf, fov = street(n)
		dist = extent(n)
	elseif m == "balcony" then
		lastMoving = false
		Effects.focus(nil)
		cf, fov = balcony()
	else
		lastMoving = false
		Effects.focus(nil)
		cf, fov = overview(n, dt)
	end
	local a = rate(2.2)
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
