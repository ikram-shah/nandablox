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


local LEG_L = CFrame.new(-0.45, 2.5, 0)
local LEG_R = CFrame.new(0.45, 2.5, 0)
local LEG_DOWN = CFrame.new(0, -1.25, 0)
local HEAD = OFF.body * CFrame.new(0, 1.8, 0)
local SLUMP = CFrame.Angles(math.rad(-14), 0, 0)

function Simple.flush(dt: number)
	t += dt
	local n = 0
	for i = 1, #queue do
		local f = queue[i]
		queue[i] = nil
		f.queued = false
		if live[f] and not f.hidden then
			local cf = f.cf
			local swing, up = 0, cf
			if f.moving and not f.far then
				local s = math.sin((t + f.phase) * 11)
				swing = s * 0.5
				up = cf * CFrame.new(0, math.abs(s) * 0.15, 0)
			end
			local body = f.mood == "cheated" and up * OFF.body * SLUMP or up * OFF.body
			moveParts[n + 1], moveCFs[n + 1] = f.body, body
			moveParts[n + 2], moveCFs[n + 2] = f.head, f.mood == "cheated" and body * CFrame.new(0, 1.8, 0) or up * HEAD
			n += 2
			-- legs: swing up close; far away they only need to follow, and only
			-- when the figure actually moved
			if swing ~= 0 then
				moveParts[n + 1], moveCFs[n + 1] = f.legL, cf * LEG_L * CFrame.Angles(swing, 0, 0) * LEG_DOWN
				moveParts[n + 2], moveCFs[n + 2] = f.legR, cf * LEG_R * CFrame.Angles(-swing, 0, 0) * LEG_DOWN
				n += 2
				f.legsSwung = true
			elseif f.moving or f.legsSwung or f.legsAt ~= cf then
				moveParts[n + 1], moveCFs[n + 1] = f.legL, cf * OFF.legL
				moveParts[n + 2], moveCFs[n + 2] = f.legR, cf * OFF.legR
				n += 2
				f.legsSwung = false
				f.legsAt = cf
			end
			-- the parcel only while carrying (it is invisible otherwise)
			if f.bag.Transparency < 1 then
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
