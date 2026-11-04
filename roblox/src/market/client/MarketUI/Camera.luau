-- The camera: an overview that slowly orbits the square and pulls back as the
-- market grows, and a street view from the balcony height. No character.

local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)

local Cam = {}

local mode = "overview"
local angle = math.rad(-60)
local dist = 120
local scripted = true

function Cam.init()
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = 50
end

function Cam.toggle()
	mode = mode == "overview" and "street" or "overview"
end

function Cam.mode(): string
	return mode
end

function Cam.set(m: string)
	mode = m
end

-- the radius the market fills at size n
local function extent(n: number): number
	local need = math.max(2, math.floor(n * 0.3 + 0.5)) * 1.3 + 6
	for a = 1, Layout.AISLES do
		if Layout.capacity(a) >= need then
			return Layout.aisleRadius(a - 1) + 10
		end
	end
	return Layout.EDGE_R
end

function Cam.update(dt: number, n: number)
	if not scripted then
		return
	end
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	angle += dt * 0.02
	local want = extent(n)
	dist += (want - dist) * math.min(1, dt * 0.8)
	local cf
	if mode == "overview" then
		-- high and to one side, looking at the plaza, offset so the inbox on the
		-- right does not cover the middle
		local r = dist * 1.55 + 20
		local h = dist * 1.15 + 30
		local eye = Vector3.new(r * math.cos(angle), h, r * math.sin(angle))
		local look = Vector3.new(0, 0, 0)
		cf = CFrame.lookAt(eye, look)
		-- shift the frame left, so the square sits in the visible middle
		cf = cf * CFrame.new(dist * 0.28, 0, 0)
	else
		local r = Layout.aisleRadius(0) - 2
		local eye = Vector3.new(r * math.cos(angle * 3), 14, r * math.sin(angle * 3))
		local ahead = angle * 3 + 0.35
		local look = Vector3.new(r * math.cos(ahead), 4, r * math.sin(ahead))
		cf = CFrame.lookAt(eye, look)
	end
	cam.CFrame = cam.CFrame:Lerp(cf, math.min(1, dt * 3))
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
