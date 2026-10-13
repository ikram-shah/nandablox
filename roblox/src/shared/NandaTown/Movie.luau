-- Movie mode: the same replay, dressed for a screen recording.
--
-- Switched on by the attribute Mode = "movie" on StarterPlayerScripts/NandaReplay,
-- which movie.project.json sets (never by hand in Studio). It adds:
--   * no CoreGui, no Roblox topbar, no mouse cursor (so neither the Roblox menu
--     nor the account name can appear),
--   * a black pre-roll, then a short title card with the scenario and seed,
--   * chapter captions a stranger can follow, computed from the trace's events,
--   * a hold on the verdict, then a fade to black.
-- The black at both ends is what tools/record_movie.sh looks for to trim the take.

local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Util = require(script.Parent.Util)

local Movie = {}

-- Timeline, in seconds from the moment the client script runs.
Movie.PREROLL = 2.0 -- solid black: the engine settles, the town is built behind it
Movie.BUILD_AT = 0.3 -- Replay.run is called here, under the black
Movie.TITLE_FADE_IN = 0.6
Movie.TITLE_HOLD = 3.6
Movie.TITLE_FADE_OUT = 0.7
Movie.HOLD = 4.0 -- on the verdict
Movie.FADE_OUT = 0.8
Movie.CAPTION_MIN = 3.5 -- a caption stays up at least this long

Movie.BANNER_Y = 112 -- verdict banner sits under the chapter caption
Movie.MARK = Color3.fromRGB(255, 0, 255) -- pre-roll fill outside the frame (never recorded)

Movie.ACCENT = Color3.fromRGB(250, 190, 60) -- the HUD's progress-bar gold

-- Seconds of town-only screen time before the first event, so the first event
-- lands just as the title card has faded.
function Movie.lead(): number
	return Movie.PREROLL + Movie.TITLE_FADE_IN + Movie.TITLE_HOLD + Movie.TITLE_FADE_OUT - Movie.BUILD_AT
end

------------------------------------------------------------------------ chrome

-- CoreGui (chat, player list with the account name, backpack, emotes), the
-- topbar (Roblox menu) and the cursor. SetCore fails until the CoreScripts have
-- registered it, so retry for a while.
function Movie.hideChrome()
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)
	UserInputService.MouseIconEnabled = false
	task.spawn(function()
		local okTopbar = false
		for _ = 1, 100 do
			okTopbar = pcall(function()
				StarterGui:SetCore("TopbarEnabled", false)
			end)
			if okTopbar then
				break
			end
			task.wait(0.1)
		end
		if not okTopbar then
			warn("[NandaTown] movie: could not disable the topbar")
		end
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
		end)
	end)
end

------------------------------------------------------------------------ the frame

-- The movie's frame: the largest 16:9 rectangle in the viewport below the topbar
-- inset. The Roblox menu button can't be hidden in the new topbar, so the frame
-- leaves it out. Everything the movie shows lives inside this rectangle; during
-- the pre-roll it is black and the rest of the viewport magenta, which is how
-- tools/record_movie.sh finds the exact crop.
function Movie.frameRect(): { x: number, y: number, w: number, h: number }
	local vp = workspace.CurrentCamera.ViewportSize
	-- the new topbar is 58 px; GetGuiInset may report 0 once TopbarEnabled is off,
	-- but the Roblox menu button stays, so never start above it
	local top = math.max(GuiService:GetGuiInset().Y, 58) + 6
	local aw, ah = vp.X, vp.Y - top
	local w, h
	if aw / ah > 16 / 9 then
		h = ah
		w = h * 16 / 9
	else
		w = aw
		h = w * 9 / 16
	end
	w, h = 2 * math.floor(w / 2), 2 * math.floor(h / 2)
	return { x = math.floor((vp.X - w) / 2), y = top + math.floor((ah - h) / 2), w = w, h = h }
end

------------------------------------------------------------------------ gui bits

-- A ScreenGui with a "Frame" child sized to Movie.frameRect(); returns both.
local frames: { Frame } = {}
local function screen(parent: Instance, name: string, order: number): (ScreenGui, Frame)
	local g = Instance.new("ScreenGui")
	g.Name = name
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = order
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.Parent = parent
	local f = Instance.new("Frame")
	f.Name = "Frame"
	f.BackgroundTransparency = 1
	f.ClipsDescendants = true
	local r = Movie.frameRect()
	f.Position = UDim2.fromOffset(r.x, r.y)
	f.Size = UDim2.fromOffset(r.w, r.h)
	f.Parent = g
	table.insert(frames, f)
	return g, f
end

-- Keep every movie frame, the HUD and the caption on the 16:9 rectangle if the
-- viewport changes. `follow.hud` and `follow.relayout` are filled in as they exist.
local follow: { hud: any?, relayout: (() -> ())? } = {}
local function followViewport()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		local r = Movie.frameRect()
		for _, f in frames do
			if f.Parent then
				f.Position = UDim2.fromOffset(r.x, r.y)
				f.Size = UDim2.fromOffset(r.w, r.h)
			end
		end
		if follow.hud then
			follow.hud:setRect(r)
		end
		if follow.relayout then
			follow.relayout()
		end
	end)
end

-- The viewport starts small while the client boots; wait until it holds still.
local function settleViewport()
	local cam = workspace.CurrentCamera
	local last, since, t0 = cam.ViewportSize, os.clock(), os.clock()
	while os.clock() - t0 < 5 do
		task.wait(0.05)
		local v = cam.ViewportSize
		if v ~= last then
			last, since = v, os.clock()
		elseif v.X > 400 and v.Y > 300 and os.clock() - since > 0.4 then
			break
		end
	end
end

local function fill(parent: Instance, color: Color3, transparency: number): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	f.Parent = parent
	return f
end

-- Linear fade of a set of properties, on the real clock (not the replay clock).
local function fade(duration: number, step: (number) -> ())
	local t0 = os.clock()
	while true do
		local a = math.clamp((os.clock() - t0) / duration, 0, 1)
		step(a)
		if a >= 1 then
			break
		end
		task.wait()
	end
end

------------------------------------------------------------------------ title card

function Movie.titleCard(parent: Instance, trace): ScreenGui
	local g, frame = screen(parent, "NandaMovieTitle", 50)
	local scrim = fill(frame, Color3.fromRGB(14, 16, 22), 0.12)
	scrim.Name = "Scrim"
	local lines = {
		Util.label(scrim, {
			Name = "Title",
			Text = "NANDA Town  ·  one real run, replayed in Roblox",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 0.5, -10),
			Size = UDim2.new(1, -80, 0, 64),
			TextSize = 56,
			Font = Util.FONT_HEAVY,
		}),
		Util.label(scrim, {
			Name = "Run",
			Text = string.format(
				"scenario <b>%s</b>  ·  seed <b>%s</b>  ·  %d events  ·  run %s",
				tostring(trace.scenario),
				tostring(trace.seed),
				#trace.events,
				tostring(trace.run_id)
			),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0.5, 8),
			Size = UDim2.new(1, -80, 0, 34),
			TextSize = 28,
			Font = Util.FONT,
			TextColor3 = Color3.fromRGB(205, 205, 215),
		}),
		Util.label(scrim, {
			Name = "Gloss",
			Text = "Each protocol layer is a building. Every motion is one logged event.",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0.5, 58),
			Size = UDim2.new(1, -80, 0, 30),
			TextSize = 24,
			Font = Util.FONT_BOLD,
			TextColor3 = Movie.ACCENT,
		}),
	}
	g:SetAttribute("Lines", #lines)
	return g
end

local function fadeTitle(g: ScreenGui, duration: number)
	local scrim = (g:FindFirstChild("Frame") :: Frame):FindFirstChild("Scrim") :: Frame
	local base = scrim.BackgroundTransparency
	local labels = {}
	for _, c in scrim:GetChildren() do
		if c:IsA("TextLabel") then
			table.insert(labels, c)
		end
	end
	fade(duration, function(a)
		scrim.BackgroundTransparency = base + (1 - base) * a
		for _, l in labels do
			l.TextTransparency = a
		end
	end)
	g:Destroy()
end

------------------------------------------------------------------------ chapters

local function money(c: number?): string
	return Util.money(c)
end

-- Chapters for the marketplace scenario, each keyed to the first event that
-- starts it, with the numbers read from the trace itself. Returns
-- { {seq, label, title, text} } in seq order; chapters whose events are
-- missing are skipped, so another run of the scenario still captions sensibly.
local function marketplaceChapters(trace)
	local ev = trace.events
	local function first(pred: (any) -> boolean, after: number?)
		for _, e in ev do
			if e.seq > (after or 0) and pred(e) then
				return e
			end
		end
		return nil
	end
	local function kind(k: string, msgKind: string?)
		return function(e)
			return e.kind == k and (msgKind == nil or (e.detail and e.detail.kind == msgKind))
		end
	end
	local out = {}
	local function add(e, label: string, title: string, text: string)
		if e then
			table.insert(out, { seq = e.seq, label = label, title = title, text = text })
		end
	end

	-- the cast
	local buyers, sellers, buyerCash = {}, {}, nil
	for _, p in trace.participants do
		if p.role == "buyer" then
			table.insert(buyers, p.name)
			buyerCash = buyerCash or p.balance_cents
		elseif p.role == "seller" then
			table.insert(sellers, p.name)
		end
	end
	local buyer = buyers[1] or "the buyer"
	add(
		ev[1],
		"",
		"The town opens",
		string.format(
			"%s (%s to spend) and %d sellers join: bank accounts, signing keys, verified cards.",
			buyer,
			money(buyerCash),
			#sellers
		)
	)

	-- 1. quotes: the first round of quote responses
	local q1 = first(kind("message_sent", "quote_request"))
	local nego = first(kind("negotiation_started"))
	if q1 then
		local quotes = {}
		for _, e in ev do
			if nego and e.seq > nego.seq then
				break
			end
			if e.kind == "message_sent" and e.detail.kind == "quote_response" then
				table.insert(quotes, string.format("%s quotes %s", tostring(e.observer), money(e.detail.body and e.detail.body.unit_cents)))
			end
		end
		add(q1, "1 / 6", "Quotes", string.format("%s asks every seller for a widget price: %s.", buyer, table.concat(quotes, ", ")))
	end

	-- 2. haggling
	if nego then
		local offer = first(kind("offer_made"), nego.seq)
		local counter = first(kind("counter_made"), nego.seq)
		local accepted = first(kind("offer_accepted"), nego.seq)
		local text = string.format("%s haggles with the cheaper seller, %s", buyer, tostring(nego.detail.seller))
		if offer and counter and accepted then
			text = string.format(
				"%s offers %s %s. It counters at %s, and %s accepts.",
				buyer,
				tostring(nego.detail.seller),
				money(offer.detail.cents),
				money(counter.detail.cents),
				buyer
			)
		end
		add(nego, "2 / 6", "Haggling", text)
	end

	-- 3. order and escrow
	local hold = first(kind("escrow_held"))
	local po = hold and first(kind("message_sent", "purchase_order"), hold.seq - 1)
	if hold then
		local qty = po and po.detail.body and po.detail.body.quantity
		add(
			hold,
			"3 / 6",
			"Order & escrow",
			string.format(
				"%s orders %s widgets. The bank holds its %s in escrow until they arrive.",
				buyer,
				tostring(qty or "the"),
				money(hold.detail.cents)
			)
		)
	end

	-- 4. the injected fault and how it was handled
	local dup = first(kind("message_duplicated"))
	local seen = first(kind("duplicate_recognized"))
	if dup then
		add(
			dup,
			"4 / 6",
			"A duplicated message, handled",
			string.format(
				"An injected fault sends %s's %s twice. Escrow pays once; %s ignores the copy.",
				tostring(dup.from),
				tostring(dup.detail.kind),
				seen and tostring(seen.observer) or buyer
			)
		)
	end

	-- 5. payment and reputation, over both rounds
	local round2 = seen and first(kind("message_sent", "quote_request"), seen.seq)
	local reps = {}
	for _, e in ev do
		if e.kind == "reputation_updated" then
			table.insert(reps, e)
		end
	end
	local lastRep = reps[#reps]
	if round2 and lastRep then
		add(
			round2,
			"5 / 6",
			"Payment & reputation",
			string.format(
				"%s rated %s good, remembers it and buys again. Escrow pays; %s's reputation: %s ★.",
				buyer,
				tostring(lastRep.subject),
				tostring(lastRep.subject),
				tostring(lastRep.detail.score)
			)
		)
	end

	-- 6. verdict
	local fin = first(kind("run_finished"))
	local r = trace.result
	if fin and r then
		local passed = 0
		for _, s in r.stages do
			if s.status == "passed" then
				passed += 1
			end
		end
		add(
			fin,
			"6 / 6",
			"Verdict",
			string.format(
				"The courthouse checks the whole record: %d of %d checks pass, and the money adds up.",
				passed,
				#r.stages
			)
		)
	end
	return out
end

local CHAPTERS = {
	marketplace = marketplaceChapters,
}

function Movie.chapters(trace)
	local f = CHAPTERS[trace.scenario]
	return f and f(trace) or {}
end

------------------------------------------------------------------------ captions

local Caption = {}
Caption.__index = Caption

function Movie.caption(parent: Instance): any
	local g, frame = screen(parent, "NandaMovieCaption", 20)
	local f = Instance.new("Frame")
	f.Name = "Caption"
	-- in the gap between the HUD's title panel (x 14..484) and legend (w-344..w-14),
	-- or under them if the frame is too narrow
	local function layout()
		local w = Movie.frameRect().w
		local gap0, gap1 = 496, w - 356
		local cw = math.clamp(gap1 - gap0, 520, 780)
		if gap1 - gap0 >= 520 then
			f.Position = UDim2.fromOffset(math.floor((gap0 + gap1 - cw) / 2), 12)
		else
			f.Position = UDim2.fromOffset(math.floor((w - cw) / 2), 124)
		end
		f.Size = UDim2.fromOffset(cw, 64)
	end
	layout()
	follow.relayout = layout
	f.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = frame
	Util.corner(f, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Movie.ACCENT
	stroke.Thickness = 2
	stroke.Transparency = 1
	stroke.Parent = f
	local head = Util.label(f, {
		Name = "Head",
		Text = "",
		Position = UDim2.fromOffset(16, 5),
		Size = UDim2.new(1, -32, 0, 28),
		TextSize = 24,
		Font = Util.FONT_HEAVY,
		TextColor3 = Movie.ACCENT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTransparency = 1,
	})
	local body = Util.label(f, {
		Name = "Body",
		Text = "",
		Position = UDim2.fromOffset(16, 34),
		Size = UDim2.new(1, -32, 0, 22),
		TextScaled = true, -- one line; shrinks a long chapter instead of wrapping
		Font = Util.FONT_BOLD,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTransparency = 1,
	})
	local fit = Instance.new("UITextSizeConstraint")
	fit.MaxTextSize = 19
	fit.MinTextSize = 13
	fit.Parent = body
	return setmetatable({ gui = g, frame = f, stroke = stroke, head = head, body = body, shownAt = -math.huge, token = 0 }, Caption)
end

function Caption:show(ch)
	self.token += 1
	local token = self.token
	local f, head, body, stroke = self.frame, self.head, self.body, self.stroke
	local wasUp = f.BackgroundTransparency < 1
	task.spawn(function()
		if wasUp then
			fade(0.2, function(a)
				head.TextTransparency, body.TextTransparency = a, a
			end)
		end
		if self.token ~= token then
			return
		end
		head.Text = ch.label ~= "" and string.format('%s   <font color="#ffffff">%s</font>', ch.label, ch.title) or ch.title
		body.Text = ch.text
		self.shownAt = os.clock()
		fade(0.3, function(a)
			head.TextTransparency, body.TextTransparency = 1 - a, 1 - a
			if not wasUp then
				f.BackgroundTransparency = 1 - 0.9 * a
				stroke.Transparency = 1 - a
			end
		end)
	end)
end

------------------------------------------------------------------------ the take

local function stage(name: string)
	workspace:SetAttribute("NandaMovieStage", name)
end

-- Runs the whole take on the client. `start(opts)` starts the replay (Replay.run
-- with the caller's camera and gui parent merged in) and returns its state.
function Movie.run(trace, guiParent: Instance, start: ({ [string]: any }) -> any)
	local t0 = os.clock()
	local function at(t: number)
		local dt = t - (os.clock() - t0)
		if dt > 0 then
			task.wait(dt)
		end
	end

	Movie.hideChrome()
	settleViewport()
	t0 = os.clock()
	followViewport()
	-- pre-roll: magenta viewport, black frame (the recorder's crop marks)
	local mark = Instance.new("ScreenGui")
	mark.Name = "NandaMovieMark"
	mark.IgnoreGuiInset = true
	mark.ResetOnSpawn = false
	mark.DisplayOrder = 99
	mark.Parent = guiParent
	fill(mark, Movie.MARK, 0)
	local black, blackFrame = screen(guiParent, "NandaMovieBlack", 100)
	local blackFill = fill(blackFrame, Color3.new(0, 0, 0), 0)
	stage("preroll")
	local title = Movie.titleCard(guiParent, trace)

	-- chapters fire on events, each held at least CAPTION_MIN
	local chapters = Movie.chapters(trace)
	local bySeq = {}
	for _, ch in chapters do
		bySeq[ch.seq] = ch
	end
	local caption = Movie.caption(guiParent)
	local queue, busy = {}, false
	local function pump()
		if busy then
			return
		end
		busy = true
		task.spawn(function()
			while #queue > 0 do
				local wait = Movie.CAPTION_MIN - (os.clock() - caption.shownAt)
				if wait > 0 then
					task.wait(wait)
				end
				caption:show(table.remove(queue, 1))
				task.wait(0.35)
			end
			busy = false
		end)
	end

	at(Movie.BUILD_AT)
	local state = start({
		lead = Movie.lead(),
		hudRect = Movie.frameRect(),
		bannerY = Movie.BANNER_Y,
		onEvent = function(e)
			local ch = bySeq[e.seq]
			if ch then
				table.insert(queue, ch)
				pump()
			end
		end,
	})

	follow.hud = state.hud
	state.hud:setRect(Movie.frameRect())

	at(Movie.PREROLL)
	mark:Destroy()
	stage("title")
	fade(Movie.TITLE_FADE_IN, function(a)
		blackFill.BackgroundTransparency = a
	end)
	black.Enabled = false
	at(Movie.PREROLL + Movie.TITLE_FADE_IN + Movie.TITLE_HOLD)
	fadeTitle(title, Movie.TITLE_FADE_OUT)
	stage("replay")

	while not state.done and not state.cancelled do
		task.wait(0.05)
	end
	stage("hold")
	task.wait(Movie.HOLD)
	black.Enabled = true
	fade(Movie.FADE_OUT, function(a)
		blackFill.BackgroundTransparency = 1 - a
	end)
	stage("done")
	workspace:SetAttribute("NandaMovieSeconds", os.clock() - t0)
end

return Movie
