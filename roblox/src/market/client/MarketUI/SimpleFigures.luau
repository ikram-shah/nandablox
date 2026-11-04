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
		legL = p({ Size = Vector3.new(0.75, 2.5, 0.8), Parent = m }),
		legR = p({ Size = Vector3.new(0.75, 2.5, 0.8), Parent = m }),
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
	f.legL.Color, f.legR.Color = pants, pants
	if role == "seller" then
		f.body.Color = f.body.Color:Lerp(Color3.fromRGB(240, 230, 210), 0.25)
	end
	f.bag.Transparency = 1
	f.cf = CFrame.new(0, -100, 0)
	f.phase = (look % 17) / 17
	f.m.Parent = folder
	live[f] = true
	return f
end

function Simple.give(f)
	live[f] = nil
	f.m.Parent = nil
	table.insert(pool, f)
end

function Simple.carry(f, good: string?)
	if good then
		f.bag.Color = Theme.GOODS[good].color
		f.bag.Transparency = 0
	else
		f.bag.Transparency = 1
	end
end

function Simple.mood(f, mood: string?)
	f.mood = mood
end

local t = 0
function Simple.place(f, cf: CFrame, moving: boolean, _state: string?, _far: boolean?)
	f.cf = cf
	f.moving = moving
	f.dirty = true
end

function Simple.flush(dt: number)
	t += dt
	local n = 0
	for f in live do
		if f.dirty or f.moving then
			f.dirty = false
			local cf = f.cf
			local swing = f.moving and math.sin((t + f.phase) * 11) * 0.5 or 0
			local bob = f.moving and math.abs(math.sin((t + f.phase) * 11)) * 0.15 or 0
			local slump = f.mood == "cheated" and CFrame.Angles(math.rad(-14), 0, 0) or CFrame.identity
			local up = CFrame.new(0, bob, 0)
			n += 1
			moveParts[n], moveCFs[n] = f.body, cf * up * OFF.body * slump
			n += 1
			moveParts[n], moveCFs[n] = f.head, cf * up * OFF.body * slump * CFrame.new(0, 1.8, 0)
			n += 1
			moveParts[n], moveCFs[n] = f.legL, cf * CFrame.new(-0.45, 2.5, 0) * CFrame.Angles(swing, 0, 0) * CFrame.new(0, -1.25, 0)
			n += 1
			moveParts[n], moveCFs[n] = f.legR, cf * CFrame.new(0.45, 2.5, 0) * CFrame.Angles(-swing, 0, 0) * CFrame.new(0, -1.25, 0)
			n += 1
			moveParts[n], moveCFs[n] = f.bag, cf * up * OFF.bag
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
