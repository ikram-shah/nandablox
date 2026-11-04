-- Colours, type and small UI helpers for the market's screens.

local Theme = {}

Theme.FONT = Enum.Font.BuilderSans
Theme.BOLD = Enum.Font.BuilderSansBold
Theme.HEAVY = Enum.Font.BuilderSansExtraBold

Theme.INK = Color3.fromRGB(34, 30, 27)
Theme.PAPER = Color3.fromRGB(250, 246, 238)
Theme.PANEL = Color3.fromRGB(28, 26, 31)
Theme.PANEL2 = Color3.fromRGB(42, 39, 46)
Theme.MUTED = Color3.fromRGB(160, 154, 150)
Theme.WHITE = Color3.fromRGB(255, 255, 255)
Theme.OK = Color3.fromRGB(86, 196, 120)
Theme.WARN = Color3.fromRGB(240, 180, 60)
Theme.BAD = Color3.fromRGB(232, 84, 72)
Theme.BLUE = Color3.fromRGB(90, 150, 240)
Theme.GOLD = Color3.fromRGB(246, 196, 70)

-- each good's colour and how it is drawn
Theme.GOODS = {
	bread = { color = Color3.fromRGB(205, 140, 70), awning = { Color3.fromRGB(196, 84, 52), Color3.fromRGB(248, 236, 214) }, icon = "🍞" },
	cloth = { color = Color3.fromRGB(110, 80, 170), awning = { Color3.fromRGB(70, 92, 160), Color3.fromRGB(236, 232, 244) }, icon = "🧵" },
	lamp = { color = Color3.fromRGB(240, 190, 70), awning = { Color3.fromRGB(46, 118, 102), Color3.fromRGB(242, 230, 196) }, icon = "🏮" },
	spice = { color = Color3.fromRGB(214, 92, 40), awning = { Color3.fromRGB(176, 52, 78), Color3.fromRGB(250, 220, 160) }, icon = "🌶" },
}

function Theme.money(cents: number): string
	return string.format("%d.%02d", cents // 100, cents % 100)
end

function Theme.new(class: string, props: { [string]: any }, children: { Instance }?): any
	local i = Instance.new(class)
	for k, v in props do
		if k ~= "Parent" then
			(i :: any)[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = i
	end
	if props.Parent then
		i.Parent = props.Parent
	end
	return i
end

function Theme.corner(r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 10)
	return c
end

function Theme.pad(p: number, l: number?)
	local u = Instance.new("UIPadding")
	u.PaddingTop = UDim.new(0, p)
	u.PaddingBottom = UDim.new(0, p)
	u.PaddingLeft = UDim.new(0, l or p)
	u.PaddingRight = UDim.new(0, l or p)
	return u
end

function Theme.stroke(color: Color3?, t: number?, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color or Color3.new(1, 1, 1)
	s.Thickness = t or 1
	s.Transparency = transparency or 0.85
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	return s
end

function Theme.label(props)
	local defaults = {
		BackgroundTransparency = 1,
		Font = Theme.FONT,
		TextColor3 = Theme.WHITE,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, 20),
	}
	for k, v in props do
		defaults[k] = v
	end
	return Theme.new("TextLabel", defaults)
end

function Theme.button(props, onClick: () -> ())
	local defaults = {
		BackgroundColor3 = Theme.PANEL2,
		AutoButtonColor = true,
		Font = Theme.BOLD,
		TextColor3 = Theme.WHITE,
		TextSize = 16,
		Size = UDim2.new(0, 60, 0, 30),
	}
	for k, v in props do
		defaults[k] = v
	end
	local b = Theme.new("TextButton", defaults, { Theme.corner(8) })
	b.Activated:Connect(onClick)
	return b
end

return Theme
