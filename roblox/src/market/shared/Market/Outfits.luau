-- The crowd's wardrobe: every asset the market's people use, in one place
-- (the repo is hermetic; README.md, "asset manifest").
--
-- Outfits are HumanoidDescriptions made of body colours and Roblox's stock
-- R15 body only: no catalog clothing or accessories, so nothing here needs an
-- upload, a purchase or a key. The server turns each into one R15 template
-- (Players:CreateHumanoidModelFromDescriptionAsync), strips the Humanoid, and
-- the clients clone templates into a pool.
--
-- Animations are Roblox's own default R15 walk and idle (the ones the stock
-- Animate script plays), public and owned by Roblox.

local Outfits = {}

Outfits.ANIMATIONS = {
	walk = "rbxassetid://507777826", -- Roblox default R15 walk
	idle = "rbxassetid://507766388", -- Roblox default R15 idle
}

local function c(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- skin tones
local SKIN = { c(255, 220, 190), c(234, 188, 150), c(198, 146, 108), c(160, 110, 76), c(116, 78, 52), c(86, 58, 40) }

-- shirt, trousers: market clothes in warm, readable colours
Outfits.LIST = {
	{ skin = 1, top = c(196, 72, 60), legs = c(50, 52, 66) },
	{ skin = 2, top = c(60, 110, 180), legs = c(90, 70, 50) },
	{ skin = 3, top = c(230, 190, 80), legs = c(40, 60, 90) },
	{ skin = 4, top = c(80, 150, 100), legs = c(120, 110, 96) },
	{ skin = 5, top = c(150, 90, 170), legs = c(50, 52, 66) },
	{ skin = 6, top = c(240, 240, 232), legs = c(90, 70, 50) },
	{ skin = 1, top = c(60, 60, 70), legs = c(120, 110, 96) },
	{ skin = 3, top = c(220, 130, 60), legs = c(40, 60, 90) },
	{ skin = 2, top = c(110, 160, 200), legs = c(50, 52, 66) },
	{ skin = 5, top = c(170, 60, 90), legs = c(120, 110, 96) },
	{ skin = 4, top = c(236, 228, 210), legs = c(70, 56, 44) }, -- an apron: sellers
	{ skin = 6, top = c(200, 170, 120), legs = c(70, 56, 44) },
}
Outfits.SKIN = SKIN

-- which outfit a trader wears (deterministic from its look number)
function Outfits.pick(look: number, role: string?): number
	if role == "seller" then
		return (look % 2 == 0) and 11 or 12
	end
	return (look % 10) + 1
end

return Outfits
