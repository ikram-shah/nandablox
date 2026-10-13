-- Play-mode runner (StarterPlayerScripts): builds NANDA Town on this client and
-- replays the trace from one fixed overview camera. No server, no network.
--   R = restart, Space = pause/resume, 1/2/4 = playback speed.
-- The "Trace" attribute on this script picks the module in
-- ReplicatedStorage.NandaTown.Traces (default: marketplace). It is set in the
-- Rojo project file ($attributes), never by hand in Studio.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local NT = ReplicatedStorage:WaitForChild("NandaTown")
local Replay = require(NT:WaitForChild("Replay"))
local Util = require(NT:WaitForChild("Util"))
local traceName = script:GetAttribute("Trace") or "marketplace"
local trace = require(NT:WaitForChild("Traces"):WaitForChild(traceName))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local state
local function start()
	state = Replay.run(trace, { parent = workspace, guiParent = playerGui, camera = camera })
end

-- External control without sharing a Lua VM (plugins, the MCP, the command bar):
-- read workspace attribute NandaSeq for progress, set NandaPaused to pause.
RunService.Heartbeat:Connect(function()
	if state then
		workspace:SetAttribute("NandaSeq", state.lastSeq)
	end
end)
workspace:GetAttributeChangedSignal("NandaPaused"):Connect(function()
	Util.paused = workspace:GetAttribute("NandaPaused") == true
end)

-- the default camera scripts may grab the camera back; keep it on the overview
RunService:BindToRenderStep("NandaTownCamera", Enum.RenderPriority.Camera.Value + 1, function()
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = Replay.CAMERA.fov
		camera.CFrame = CFrame.lookAt(Replay.CAMERA.pos, Replay.CAMERA.target)
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.R then
		start()
	elseif input.KeyCode == Enum.KeyCode.Space then
		Util.paused = not Util.paused
	elseif input.KeyCode == Enum.KeyCode.One then
		Util.speed = 1
	elseif input.KeyCode == Enum.KeyCode.Two then
		Util.speed = 2
	elseif input.KeyCode == Enum.KeyCode.Four then
		Util.speed = 4
	end
end)

task.wait(1)
start()
