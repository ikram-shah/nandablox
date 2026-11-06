-- People up close: pooled R15 rigs (templates the server made from the outfit
-- manifest, Outfits.luau), animated on the client with an AnimationController
-- playing Roblox's default walk and idle. No Humanoid, no physics: each rig's
-- root is anchored and moved with BulkMoveTo; the Motor6Ds and the Animator
-- pose the limbs.
--
-- Only the NEAREST few traders get a rig (LOD); everyone else is a simple
-- figure. Crowd decides who is near; this module only pools and poses.
--
-- Players: Rigs.takePlayer clones that player's real avatar (a template the
-- server built from their HumanoidDescription, ReplicatedStorage.MarketAvatars,
-- see Avatars.luau) with a team-coloured outline; until it exists, or if it
-- never does, a stock outfit wearing the team's shirt.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Market = ReplicatedStorage:WaitForChild("Market")
local Outfits = require(Market.Outfits)
local Avatars = require(Market.Avatars)

local Rigs = {}

local folder: Folder
local templates: { Model } = {}
local avatars: { [number]: Model } = {} -- userId -> that player's avatar template
local pools: { [any]: { any } } = {}
local anims = {}
local live = {}
local moveParts, moveCFs = {}, {}
Rigs.ready = false
Rigs.made = 0

function Rigs.init(parent: Instance)
	folder = Instance.new("Folder")
	folder.Name = "Rigs"
	folder.Parent = parent
	for k, id in Outfits.ANIMATIONS do
		local a = Instance.new("Animation")
		a.AnimationId = id
		anims[k] = a
	end
	task.spawn(function()
		local src = ReplicatedStorage:WaitForChild("MarketRigs", 60)
		if not src then
			warn("[market] no rig templates; the crowd stays simple")
			return
		end
		for _, m in src:GetChildren() do
			local i = tonumber(string.match(m.Name, "%d+"))
			if i and m:IsA("Model") then
				templates[i] = m
			end
		end
		Rigs.ready = next(templates) ~= nil
	end)
	task.spawn(function()
		local src = ReplicatedStorage:WaitForChild(Avatars.FOLDER, 60)
		if not src then
			return
		end
		local function add(m: Instance)
			local id = m:GetAttribute("UserId")
			if m:IsA("Model") and type(id) == "number" then
				avatars[id] = m
			end
		end
		local function remove(m: Instance)
			local id = m:GetAttribute("UserId")
			if type(id) == "number" and avatars[id] == m then
				avatars[id] = nil
			end
		end
		for _, m in src:GetChildren() do
			add(m)
		end
		src.ChildAdded:Connect(add)
		src.ChildRemoved:Connect(remove)
	end)
end

local HIP = 3.0 -- root height above the ground for a default R15

local function build(key: any, t: Model?)
	t = t or templates[key] or templates[next(templates)]
	local m = (t :: Model):Clone()
	-- the crowd's rigs animate through an AnimationController; a player's
	-- avatar keeps its (idle) Humanoid, and animates through that one's Animator
	local ac = m:FindFirstChildOfClass("AnimationController") or m:FindFirstChildOfClass("Humanoid")
	local animator = ac and ac:FindFirstChildOfClass("Animator")
	local hip = m:GetAttribute("Hip")
	local uid = m:GetAttribute("UserId")
	local r = {
		model = m,
		root = m.PrimaryPart,
		outfit = key,
		tracks = {},
		hip = type(hip) == "number" and hip or HIP,
		userId = type(uid) == "number" and uid or nil, -- set: a real avatar
	}
	if r.userId then
		-- the team colour as an outline, so their own clothes stay theirs
		local h = Instance.new("Highlight")
		h.Name = "TeamGlow"
		h.Adornee = m
		h.FillTransparency = 0.88
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Enabled = false
		h.Parent = m
		r.glow = h
	end
	-- in the DataModel before loading: a Humanoid's Animator silently never
	-- plays tracks loaded while its model was unparented (measured in Studio)
	m.Parent = folder
	if animator then
		for k, a in anims do
			local ok, track = pcall(function()
				return animator:LoadAnimation(a)
			end)
			if ok and track then
				track.Looped = true
				track.Priority = k == "walk" and Enum.AnimationPriority.Movement or Enum.AnimationPriority.Idle
				r.tracks[k] = track
			end
		end
	end
	-- something to carry: a parcel in the colour of the good, welded to the hand
	local hand = m:FindFirstChild("RightHand")
	if hand then
		local parcel = Instance.new("Part")
		parcel.Name = "Parcel"
		parcel.Size = Vector3.new(0.9, 0.8, 0.9)
		parcel.CanCollide = false
		parcel.CanQuery = false
		parcel.CanTouch = false
		parcel.Massless = true
		parcel.CastShadow = false
		parcel.Transparency = 1
		parcel.CFrame = hand.CFrame * CFrame.new(0, -0.5, 0)
		local w = Instance.new("WeldConstraint")
		w.Part0 = hand
		w.Part1 = parcel
		w.Parent = parcel
		parcel.Parent = m
		r.parcel = parcel
	end
	local head = m:FindFirstChild("Head")
	if head then
		local bb = Instance.new("BillboardGui")
		bb.Name = "AgentTag"
		bb.Size = UDim2.new(0, 148, 0, 22)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 2.3, 0)
		bb.AlwaysOnTop = false
		bb.LightInfluence = 0
		bb.MaxDistance = 55
		bb.Enabled = false
		bb.Adornee = head
		local tl = Instance.new("TextLabel")
		tl.Size = UDim2.fromScale(1, 1)
		tl.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
		tl.BackgroundTransparency = 0.22
		tl.TextColor3 = Color3.fromRGB(244, 240, 232)
		tl.Font = Enum.Font.GothamMedium
		tl.TextSize = 12
		tl.Text = ""
		tl.Parent = bb
		local cr = Instance.new("UICorner")
		cr.CornerRadius = UDim.new(0, 6)
		cr.Parent = tl
		bb.Parent = m
		r.tag = bb
		r.tagLabel = tl
	end
	return r
end

-- team tags ("blue" | "red") read from across the square (AlwaysOnTop)
-- unless onTop is false: a red seller's badge behind their own counter is
-- seen only by someone looking at the stall
function Rigs.label(r, text: string?, team: string?, onTop: boolean?)
	if r and r.tag and r.tagLabel then
		if text and text ~= "" then
			r.tagLabel.Text = text
			if team == "blue" then
				r.tagLabel.BackgroundColor3 = Color3.fromRGB(28, 92, 196)
				r.tagLabel.BackgroundTransparency = 0.06
				r.tagLabel.TextSize = 13
				r.tag.Size = UDim2.new(0, 188, 0, 26)
				r.tag.MaxDistance = 240
				r.tag.AlwaysOnTop = onTop ~= false
			elseif team == "red" then
				r.tagLabel.BackgroundColor3 = Color3.fromRGB(196, 48, 48)
				r.tagLabel.BackgroundTransparency = 0.06
				r.tagLabel.TextSize = 13
				r.tag.Size = UDim2.new(0, 188, 0, 26)
				r.tag.MaxDistance = 240
				r.tag.AlwaysOnTop = onTop ~= false
			else
				r.tagLabel.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
				r.tagLabel.BackgroundTransparency = 0.22
				r.tagLabel.TextSize = 12
				r.tag.Size = UDim2.new(0, 148, 0, 22)
				r.tag.MaxDistance = 65
				r.tag.AlwaysOnTop = false
			end
			r.tag.Enabled = true
		else
			r.tag.Enabled = false
		end
	end
end

local TOP_PARTS = { "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm" }
function Rigs.setShirtColor(r, col: Color3)
	if not r or not r.model or r.userId then
		return -- (never repaint a player's own avatar)
	end
	local bc = r.model:FindFirstChildOfClass("BodyColors")
	if bc then
		bc.TorsoColor3 = col
	end
	for _, pname in TOP_PARTS do
		local p = r.model:FindFirstChild(pname)
		if p and p:IsA("BasePart") then
			p.Color = col
		end
	end
end

-- a player's team colour: an outline on a real avatar, the shirt on a stock one
function Rigs.setTeam(r, col: Color3)
	if not r then
		return
	end
	if r.glow then
		r.glow.FillColor = col
		r.glow.OutlineColor = col
		r.glow.Enabled = true
	else
		Rigs.setShirtColor(r, col)
	end
end

function Rigs.hasAvatar(userId: number?): boolean
	return userId ~= nil and avatars[userId] ~= nil
end

-- the rig for a player: their own avatar if the server built one, else a
-- stock outfit (Red and Blue get different ones, as before). r.userId tells
-- which; Camera swaps a stock rig for the avatar once it arrives.
function Rigs.takePlayer(userId: number?, role: string)
	local t = userId and avatars[userId]
	if not t then
		return Rigs.take(role == "red" and 10 or 1, "buyer")
	end
	local key = "u" .. tostring(userId)
	local pool = pools[key]
	local r = pool and table.remove(pool) or build(key, t)
	r.model.Parent = folder
	r.anim = nil
	r.mood = nil
	r.speed = 1
	live[r] = true
	return r
end

function Rigs.take(look: number, role: string)
	if not Rigs.ready then
		return nil
	end
	local outfit = Outfits.pick(look or 1, role)
	if not templates[outfit] then
		outfit = next(templates)
	end
	local pool = pools[outfit]
	local r = pool and table.remove(pool) or build(outfit)
	r.model.Parent = folder -- stays parented while pooled (hidden far below); reparenting a rig is costly
	r.anim = nil
	r.mood = nil
	r.speed = 1
	live[r] = true
	Rigs.made += pool and 0 or 1
	return r
end

function Rigs.give(r)
	if not r then
		return
	end
	live[r] = nil
	if r.tag then
		r.tag.Enabled = false
		r.tag.StudsOffsetWorldSpace = Vector3.new(0, 2.3, 0)
	end
	if r.glow then
		r.glow.Enabled = false
	end
	for _, t in r.tracks do
		t:Stop(0)
	end
	r.anim = nil
	-- park it out of sight instead of unparenting
	local n = #moveParts + 1
	moveParts[n] = r.root
	moveCFs[n] = CFrame.new(0, -400, 0)
	pools[r.outfit] = pools[r.outfit] or {}
	table.insert(pools[r.outfit], r)
end

function Rigs.carry(r, color: Color3?)
	if r and r.parcel then
		r.parcel.Transparency = color and 0 or 1
		if color then
			r.parcel.Color = color
		end
	end
end

local function play(r, which: string, speed: number)
	if r.anim ~= which then
		if r.anim and r.tracks[r.anim] then
			r.tracks[r.anim]:Stop(0.2)
		end
		local t = r.tracks[which]
		if t then
			t:Play(0.2)
		end
		r.anim = which
	end
	local t = r.tracks[which]
	if t and which == "walk" and math.abs(r.speed - speed) > 0.05 then
		r.speed = speed
		t:AdjustSpeed(speed)
	end
end

-- cf: feet on the ground, facing; walking: play walk, else idle
function Rigs.place(r, cf: CFrame, walking: boolean, slump: boolean?)
	if not r then
		return
	end
	local n = #moveParts + 1
	local lean = slump and CFrame.Angles(math.rad(-10), 0, 0) or CFrame.identity
	moveParts[n] = r.root
	moveCFs[n] = cf * CFrame.new(0, r.hip or HIP, 0) * lean
	play(r, walking and "walk" or "idle", 1.15)
end

function Rigs.flush()
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCFs, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveParts)
		table.clear(moveCFs)
	end
end

function Rigs.count(): number
	local n = 0
	for _ in live do
		n += 1
	end
	return n
end

return Rigs
