-- The cheapest figure: a few anchored parts (body, head, legs) moved together
-- with one workspace:BulkMoveTo per frame. Used for the far crowd, and as the
-- whole crowd when rigs are off. Same interface as RigFigures.

local Theme = require(script.Parent.Theme)

local Simple = {}

local folder: Folder
local pool = {}
local live = {}
local moveParts = {}
local moveCFs = {}

local SKIN = {
	Color3.fromRGB(255, 220, 190), Color3.fromRGB(234, 188, 150), Color3.fromRGB(198, 146, 108),
	Color3.fromRGB(160, 110, 76), Color3.fromRGB(116, 78, 52), Color3.fromRGB(86, 58, 40),
}
local SHIRTS = {
	Color3.fromRGB(196, 72, 60), Color3.fromRGB(60, 110, 180), Color3.fromRGB(230, 190, 80),
	Color3.fromRGB(80, 150, 100), Color3.fromRGB(150, 90, 170), Color3.fromRGB(240, 240, 232),
	Color3.fromRGB(60, 60, 70), Color3.fromRGB(220, 130, 60), Color3.fromRGB(110, 160, 200),
	Color3.fromRGB(170, 60, 90),
}
local PANTS = {
	Color3.fromRGB(50, 52, 66), Color3.fromRGB(90, 70, 50), Color3.fromRGB(40, 60, 90), Color3.fromRGB(120, 110, 96),
}
Simple.SKIN, Simple.SHIRTS, Simple.PANTS = SKIN, SHIRTS, PANTS

local function p(props)
	local x = Instance.new("Part")
	x.Anchored = true
	x.CanCollide = false
	x.CanQuery = false
	x.CanTouch = false
	x.CastShadow = false
	x.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		(x :: any)[k] = v
	end
	return x
end

-- offsets from the figure's root (feet on the ground at y = 0)
local OFF = {
	body = CFrame.new(0, 3.6, 0),
	head = CFrame.new(0, 5.4, 0),
	legL = CFrame.new(-0.45, 1.25, 0),
	legR = CFrame.new(0.45, 1.25, 0),
	bag = CFrame.new(0.95, 3.2, -0.5),
}

function Simple.init(parent: Instance)
	folder = Instance.new("Folder")
	folder.Name = "Simple"
	folder.Parent = parent
end

local function build()
	local m = Instance.new("Folder")
	m.Name = "Figure"
	local f = {
		m = m,
		body = p({ Size = Vector3.new(1.8, 2.2, 1), Parent = m }),
		head = p({ Shape = Enum.PartType.Ball, Size = Vector3.new(1.25, 1.25, 1.25), Parent = m }),
		legs = p({ Size = Vector3.new(1.6, 2.5, 0.8), Parent = m }),
		bag = p({ Size = Vector3.new(0.9, 0.9, 0.9), Transparency = 1, Parent = m }),
	}
	return f
end

function Simple.take(look: number, role: string)
	local f = table.remove(pool) or build()
	look = look or 1
	f.body.Color = SHIRTS[look % #SHIRTS + 1]
	f.head.Color = SKIN[(look // 7) % #SKIN + 1]
	local pants = PANTS[(look // 3) % #PANTS + 1]
	f.legs.Color = pants
	if role == "seller" then
		f.body.Color = f.body.Color:Lerp(Color3.fromRGB(240, 230, 210), 0.25)
	end
	f.bag.Transparency = 1
	f.carrying = false
	f.cf = CFrame.new(0, -100, 0)
	f.phase = (look % 17) / 17
	f.m.Parent = folder
	live[f] = true
	return f
end

function Simple.give(f)
	live[f] = nil
	f.hidden = false
	f.m.Parent = nil
	table.insert(pool, f)
end

-- hidden (out of the world) while a rig stands in for this figure
function Simple.show(f, on: boolean)
	f.m.Parent = on and folder or nil
	f.hidden = not on
end
Simple.hide = function(f, hidden: boolean)
	Simple.show(f, not hidden)
end

function Simple.carry(f, good: string?)
	if good then
		f.bag.Color = Theme.GOODS[good].color
		f.bag.Transparency = 0
	else
		f.bag.Transparency = 1
	end
	f.carrying = good ~= nil
end

function Simple.mood(f, mood: string?)
	f.mood = mood
end

local t = 0
local queue = {} -- figures placed since the last flush

function Simple.place(f, cf: CFrame, moving: boolean, _state: string?, far: boolean?)
	f.cf = cf
	f.moving = moving
	f.far = far
	if not f.queued then
		f.queued = true
		table.insert(queue, f)
	end
end


local LEGS = CFrame.new(0, 1.25, 0)
local HEAD = OFF.body * CFrame.new(0, 1.8, 0)
local SLUMP = CFrame.Angles(math.rad(-14), 0, 0)

-- Three parts a figure (body, head, legs), four while carrying something.
-- Walking reads as a bob and a sway; anyone close enough to see legs is a rig.
function Simple.flush(dt: number)
	t += dt
	local n = 0
	for i = 1, #queue do
		local f = queue[i]
		queue[i] = nil
		f.queued = false
		if live[f] and not f.hidden then
			local cf = f.cf
			local up = cf
			if f.moving then
				local s = math.sin((t + f.phase) * 11)
				up = cf * CFrame.new(0, math.abs(s) * 0.18, 0) * CFrame.Angles(0, 0, s * 0.06)
			end
			local body = f.mood == "cheated" and up * OFF.body * SLUMP or up * OFF.body
			moveParts[n + 1], moveCFs[n + 1] = f.body, body
			moveParts[n + 2], moveCFs[n + 2] = f.head, f.mood == "cheated" and body * CFrame.new(0, 1.8, 0) or up * HEAD
			moveParts[n + 3], moveCFs[n + 3] = f.legs, up * LEGS
			n += 3
			if f.carrying or f.bagShown then
				-- move the bag while carried, and once more to put it away
				f.bagShown = f.carrying
				moveParts[n + 1], moveCFs[n + 1] = f.bag, up * OFF.bag
				n += 1
			end
		end
	end
	for i = #moveParts, n + 1, -1 do
		moveParts[i], moveCFs[i] = nil, nil
	end
	if n > 0 then
		workspace:BulkMoveTo(moveParts, moveCFs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

return Simple
