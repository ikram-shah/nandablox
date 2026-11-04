-- People up close: pooled R15 rigs (templates the server made from the outfit
-- manifest, Outfits.luau), animated on the client with an AnimationController
-- playing Roblox's default walk and idle. No Humanoid, no physics: each rig's
-- root is anchored and moved with BulkMoveTo; the Motor6Ds and the Animator
-- pose the limbs.
--
-- Only the NEAREST few traders get a rig (LOD); everyone else is a simple
-- figure. Crowd decides who is near; this module only pools and poses.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Market = ReplicatedStorage:WaitForChild("Market")
local Outfits = require(Market.Outfits)

local Rigs = {}

local folder: Folder
local templates: { Model } = {}
local pools: { [number]: { any } } = {}
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
end

local HIP = 3.0 -- root height above the ground for a default R15

local function build(outfit: number)
	local t = templates[outfit] or templates[next(templates)]
	local m = t:Clone()
	local ac = m:FindFirstChildOfClass("AnimationController")
	local animator = ac and ac:FindFirstChildOfClass("Animator")
	local r = {
		model = m,
		root = m.PrimaryPart,
		outfit = outfit,
		tracks = {},
	}
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
	moveCFs[n] = cf * CFrame.new(0, HIP, 0) * lean
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
