-- Oversight: what a human watcher is asked to decide, with and without a
-- delegated hierarchy of cheap monitors (the demo in roblox/DEMO.md).
--
-- The argument it makes visible: the binding constraint on oversight is
-- judgment calls per minute, not agent count, and a hierarchy turns a flood
-- of events into a few judgment calls.
--
--   tier 0  the layers: hmac.v1's guards and index.owned.v1's padlock stop
--           what they can at once (counted as "blocked by the layers")
--   tier 1  rule monitors (on with H): each case at a seam is auto-caught,
--           auto-cleared, or escalated when the rules cannot decide
--   top     one human on a fixed attention budget: a judgment call takes
--           WATCHER_SECONDS_PER_CALL (12 a minute). With no monitors, every
--           case is theirs. BlueBot plays this human when blue has none.
--
-- A *case* is one thing at a seam a person would have to look at: an invoice
-- (does it pay the right party?), a card on the notice board (is that seller
-- who it says?), a duplicated delivery (a replay?). The rules a monitor
-- applies, and what it cannot decide:
--
--   invoice    courier set off from the gate or from another stall -> caught;
--              payee not on the board -> caught; otherwise cleared
--   card       UNVERIFIED (signature does not match the name) -> caught;
--              a second card for a listed name: under hmac.v1 it is signed by
--              the name's own key (a reprice) -> cleared; under plain.v1
--              nothing tells a reprice from a spoof -> ESCALATED;
--              a new seller more than MONITOR_SALE_THRESHOLD under the going
--              rate -> ESCALATED (an opening sale, or a fly-by-night stall?);
--              otherwise cleared. A fly-by-night stall priced *just* under
--              the threshold is cleared: that is what the monitors miss.
--   duplicate  the transport layer recognised it -> cleared
--
-- Pure: time is passed in, randomness is the seeded Rng, and actions go back
-- through `act` (Game: flag a target as a monitor or as the watcher). Lune
-- runs it headless (tests/test_oversight.luau).

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local Rng = sibling("Rng")

local Oversight = {}
Oversight.__index = Oversight

-- The demo's beats (B steps through them; DEMO.md has the words).
Oversight.BEATS = {
	{ id = "small", label = "a small town: the human keeps up", oversight = true, size = 5, monitors = false, auth = "hmac.v1", registry = "index.v1" },
	{ id = "grow25", label = "25 agents", size = 25 },
	{ id = "grow100", label = "100 agents: the human drowns", size = 100 },
	{ id = "monitors", label = "monitors on: the flood becomes a trickle", monitors = true },
	{ id = "guards", label = "the council drops signature checks: the guards walk", auth = "plain.v1" },
	{ id = "restore", label = "guards back on duty", auth = "hmac.v1" },
	{ id = "end", label = "back to the five-agent game", oversight = false },
}

-- opts = { config, seed?, layers (live table: Game.layers), monitors? }
function Oversight.new(opts)
	local cfg = opts.config
	local self = setmetatable({
		cfg = cfg,
		rng = Rng.new(opts.seed or 5),
		layers = opts.layers or cfg.DEFAULT_LAYERS,
		monitors = opts.monitors == true,
		watcherOn = true,
		n = 0,
		cases = {}, -- id -> case
		incoming = {}, -- cases created this tick, decided in tick()
		pending = {}, -- monitor decisions in flight: { case, at, verdict }
		queue = {}, -- cases awaiting the human, oldest first
		current = nil, -- the case the human is deciding, and when they will have
		listed = {}, -- card id -> { name, price, verified }
		everListed = {}, -- seller name -> true
		blockedMsgs = {}, -- message ids the guards stopped
		threats = {}, -- threat id -> { escalated, cleared, reviewed, kind }
		evTimes = {}, -- town event times (a ring, trimmed to RATE_WINDOW)
		callTimes = {}, -- escalations to the human
		threatTimes = {}, -- attacks
		since = 0,
		label = "",
		now = 0,
	}, Oversight)
	self:resetTotals(0)
	return self
end

function Oversight:resetTotals(now: number)
	self.since = now
	self.totals = {
		events = 0,
		calls = 0,
		cases = 0,
		threats = 0,
		autoCaught = 0,
		autoCleared = 0,
		humanCaught = 0,
		blocked = 0,
		escaped = 0,
		missedByMonitors = 0,
		escapedWaiting = 0,
		humanWrong = 0,
		falseAlarms = 0,
		expired = 0,
		reviewed = 0,
	}
end

-- A new setting (town size, monitors, laws): the "since" totals start again;
-- the rates keep their window, trimmed to the new setting.
--
-- A threat's outcome is booked to the setting it appeared under, so the
-- numbers after "monitors on" are about what the monitors did, not about the
-- backlog they inherited.
function Oversight:mark(now: number, label: string?)
	self.epoch = (self.epoch or 0) + 1
	self:resetTotals(now)
	self.label = label or self.label
end

function Oversight:setMonitors(on: boolean, now: number)
	self.monitors = on
	if on then
		-- the backlog is handed to the monitors at once; and what the human
		-- never reached that a rule can settle (a forgery still on a desk, an
		-- UNVERIFIED card still pinned) the monitors catch now. They do not
		-- re-escalate the ambiguous leftovers: those stay missed.
		local q = self.queue
		self.queue = {}
		for _, c in q do
			c.deadline = math.max(c.deadline, now + (self.cfg.MONITOR_DELAY or 0.5) + 1)
			self:decideByMonitor(c, now)
		end
		for _, c in self.cases do
			if c.state == "expired" and self:classify(c) == "catch" then
				local listed = false
				for _, l in self.listed do
					listed = listed or l.case == c.id
				end
				if listed or (c.threat and not (self.threats[c.threat] or {}).done) then
					c.deadline = math.max(c.deadline, now + (self.cfg.MONITOR_DELAY or 0.5) + 1)
					self:decideByMonitor(c, now)
				end
			end
		end
	end
end

------------------------------------------------------------------------ cases

local function median(list: { number }): number?
	if #list == 0 then
		return nil
	end
	table.sort(list)
	return list[(#list + 1) // 2]
end

function Oversight:marketPrice(): number
	local prices = {}
	for _, c in self.listed do
		if c.verified then
			table.insert(prices, c.price)
		end
	end
	return median(prices) or 2000
end

function Oversight:listedNames(): { [string]: number }
	local names = {}
	for _, c in self.listed do
		names[c.name] = (names[c.name] or 0) + 1
	end
	return names
end

function Oversight:newCase(fields)
	self.n += 1
	local c = fields
	c.id = "case-" .. self.n
	c.state = "new"
	self.cases[c.id] = c
	table.insert(self.incoming, c)
	if c.threat then
		local t = self.threats[c.threat] or { kind = c.attack }
		self.threats[c.threat] = t
		t.cases = (t.cases or 0) + 1
	end
	return c
end

-- What a monitor would say about a case, and why: "catch" | "clear" | "escalate".
-- Computed for every case, monitors or not: it is also how hard the case
-- is for a human (a clear case is easy; an escalated one is a real call).
function Oversight:classify(c): (string, string)
	if c.kind == "invoice" then
		if c.origin == "gate" then
			return "catch", "courier set off from the gate"
		elseif c.origin then
			return "catch", "courier came from another stall"
		elseif c.payTo and not c.payeeListed then
			return "catch", "payee is not on the board"
		end
		return "clear", "invoice matches the order"
	elseif c.kind == "card" then
		if not c.verified then
			return "catch", "signature does not match the name"
		elseif c.twin then
			if c.signed then
				return "clear", "signed by the name's own key: a reprice"
			end
			return "escalate", "two cards, one name, no signatures to tell"
		elseif c.newName and c.price < c.market * (1 - (self.cfg.MONITOR_SALE_THRESHOLD or 0.12)) then
			return "escalate", string.format("new seller, %d%% under the going rate", math.floor((1 - c.price / c.market) * 100 + 0.5))
		end
		return "clear", "a listing like the others"
	elseif c.kind == "duplicate" then
		return "clear", "transport recognised the duplicate"
	end
	return "clear", ""
end

-- One town event (server-side: private keys still on).
function Oversight:observe(e, now: number)
	if e.layer == "game" or e.snapshot then
		return
	end
	self.totals.events += 1
	table.insert(self.evTimes, now)
	local d = e.detail or {}
	local kind = e.kind
	if kind == "message_sent" and d.kind == "invoice" then
		local body = d.body or {}
		self:newCase({
			kind = "invoice",
			target = e.subject,
			threat = e._threat,
			from = e.observer,
			to = d.to,
			payTo = body.pay_to,
			payeeListed = body.pay_to ~= nil and self:listedNames()[body.pay_to] ~= nil,
			cents = body.cents,
			origin = e.origin,
			at = now,
			deadline = now + (self.cfg.REVIEW_WINDOW or 12),
		})
	elseif kind == "card_registered" or kind == "card_unverified" then
		local names = self:listedNames()
		local verified = kind == "card_registered" and d.verified ~= false
		local c = self:newCase({
			kind = "card",
			target = e.card,
			threat = e._threat,
			name = e.subject,
			price = e.price or 2000,
			verified = verified,
			twin = (names[e.subject] or 0) > 0,
			signed = self.layers.auth == "hmac.v1",
			newName = not self.everListed[e.subject],
			market = self:marketPrice(),
			at = now,
			deadline = now + (self.cfg.CARD_REVIEW_WINDOW or 20),
		})
		if e.card then
			self.listed[e.card] = { name = e.subject, price = e.price or 2000, verified = verified, case = c.id }
		end
		self.everListed[e.subject] = true
	elseif kind == "card_withdrawn" then
		if e.card then
			self.listed[e.card] = nil
		end
	elseif kind == "message_duplicated" then
		self:newCase({ kind = "duplicate", target = e.subject, threat = e._threat, to = d.to, at = now, deadline = now + 6 })
	elseif kind == "signature_invalid" and not e.card then
		self.blockedMsgs[e.subject] = true
	end
end

function Oversight:threatAppeared(th, now: number)
	self.totals.threats += 1
	table.insert(self.threatTimes, now)
	local t = self.threats[th.id] or {}
	t.kind = th.kind
	t.epoch = self.epoch
	self.threats[th.id] = t
end

-- the totals a threat's outcome is booked to (a dummy for an older setting)
function Oversight:book(t): { [string]: number }
	if t and t.epoch ~= nil and t.epoch ~= self.epoch then
		return setmetatable({}, {
			__index = function()
				return 0
			end,
		}) :: any
	end
	return self.totals
end

-- A threat ended in the town (escaped, blocked, fizzled; catches come
-- through caught()).
function Oversight:resolved(th, _now: number)
	local t = self.threats[th.id] or {}
	local tot = self:book(t)
	if th.state == "blocked" then
		tot.blocked += 1
	elseif th.state == "escaped" then
		tot.escaped += 1
		if t.wrong then
			tot.humanWrong += 1
		elseif t.escalated then
			tot.escapedWaiting += 1
		elseif t.cleared then
			tot.missedByMonitors += 1
		else
			tot.escapedWaiting += 1
		end
	end
	t.done = true
	self.threats[th.id] = t
end

-- Game:flag reports every catch and false alarm, whoever made it.
function Oversight:caught(threatId: string, who: string)
	local t = self.threats[threatId]
	local tot = self:book(t)
	if who == "monitor" then
		tot.autoCaught += 1
	else
		tot.humanCaught += 1
	end
	if t then
		t.done = true
	end
end

function Oversight:falseAlarm(_target: string, _who: string)
	self.totals.falseAlarms += 1
end

-- A human player flagged `target` themselves: that case is decided.
function Oversight:humanFlagged(target: string)
	for i = #self.queue, 1, -1 do
		local c = self.queue[i]
		if c.target == target then
			table.remove(self.queue, i)
			c.state = "reviewed"
			self.totals.reviewed += 1
		end
	end
end

------------------------------------------------------------------------ the tick

function Oversight:escalate(c, now: number)
	c.state = "queued"
	c.queuedAt = now
	table.insert(self.queue, c)
	self.totals.calls += 1
	table.insert(self.callTimes, now)
	if c.threat then
		local t = self.threats[c.threat] or {}
		t.escalated = true
		self.threats[c.threat] = t
	end
end

function Oversight:decideByMonitor(c, now: number)
	local verdict = self:classify(c)
	c.state = "monitor"
	table.insert(self.pending, { case = c, at = now + (self.cfg.MONITOR_DELAY or 0.5), verdict = verdict })
end

-- Is the case still worth deciding? (its threat still live, its target
-- still there, its window still open)
function Oversight:alive(c, now: number, act): boolean
	if now > c.deadline then
		return false
	end
	if c.threat then
		local t = self.threats[c.threat]
		if t and t.done then
			return false
		end
		return act == nil or act.live == nil or act.live(c.threat)
	end
	if c.kind == "card" then
		for _, l in self.listed do
			if l.case == c.id then
				return true
			end
		end
		return false
	end
	return true
end

-- act = { flag = function(as: "monitor" | "watcher", target) -> result,
--         live = function(threatId) -> boolean, watcher = boolean }
function Oversight:tick(now: number, act)
	self.now = now
	self.watcherOn = act.watcher ~= false
	-- new cases: the guards may already have stopped a forgery
	local incoming = self.incoming
	self.incoming = {}
	for _, c in incoming do
		if c.kind == "invoice" and self.blockedMsgs[c.target] then
			c.state = "blocked"
		else
			self.totals.cases += 1
			local verdict, why = self:classify(c)
			c.verdict, c.why = verdict, why
			c.ambiguous = verdict == "escalate"
			if self.monitors then
				self:decideByMonitor(c, now)
			else
				self:escalate(c, now)
			end
		end
	end
	-- monitor decisions that are due
	local still = {}
	local pend = self.pending
	self.pending = {}
	for _, p in pend do
		if now >= p.at then
			local c = p.case
			if p.verdict == "catch" then
				c.state = "auto"
				if self:alive(c, now, act) then
					act.flag("monitor", c.target)
				end
			elseif p.verdict == "clear" then
				c.state = "cleared"
				self.totals.autoCleared += 1
				if c.threat then
					local t = self.threats[c.threat] or {}
					t.cleared = true
					self.threats[c.threat] = t
				end
			else
				self:escalate(c, now)
			end
		else
			table.insert(still, p)
		end
	end
	for _, p in self.pending do
		table.insert(still, p) -- set by setMonitors during the loop
	end
	self.pending = still
	-- drop what is no longer worth deciding
	for i = #self.queue, 1, -1 do
		local c = self.queue[i]
		if not self:alive(c, now, act) then
			table.remove(self.queue, i)
			c.state = "expired"
			self.totals.expired += 1
		end
	end
	-- the human: one judgment call at a time, WATCHER_SECONDS_PER_CALL each
	if self.watcherOn then
		local cur = self.current
		if cur and now >= cur.decideAt then
			self.current = nil
			local c = cur.case
			if self:alive(c, now, act) then
				self.totals.reviewed += 1
				local acc = self.cfg.WATCHER_ACCURACY or { clear = 0.97, ambiguous = 0.85 }
				local right = self.rng:chance(c.ambiguous and acc.ambiguous or acc.clear)
				local threat = c.threat ~= nil
				if threat == right then
					-- a threat judged right, or an honest case judged wrong: flag it
					c.state = "flagged"
					act.flag("watcher", c.target)
				else
					c.state = "passed"
					if threat then
						local t = self.threats[c.threat] or {}
						t.wrong = true
						self.threats[c.threat] = t
					end
				end
			else
				c.state = "expired"
				self.totals.expired += 1
			end
		end
		if not self.current and #self.queue > 0 then
			local c = table.remove(self.queue, 1)
			c.state = "reviewing"
			self.current = { case = c, decideAt = now + (self.cfg.WATCHER_SECONDS_PER_CALL or 5) }
		end
	elseif self.current then
		table.insert(self.queue, 1, self.current.case)
		self.current = nil
	end
	self:trim(now)
end

function Oversight:trim(now: number)
	local w = self.cfg.RATE_WINDOW or 30
	for _, list in { self.evTimes, self.callTimes, self.threatTimes } do
		local drop = 0
		for _, t in list do
			if t < now - w then
				drop += 1
			else
				break
			end
		end
		if drop > 0 then
			local keep = table.move(list, drop + 1, #list, 1, {})
			table.clear(list)
			table.move(keep, 1, #keep, 1, list)
		end
	end
	-- forget cases long gone
	if self.n % 50 == 0 then
		for id, c in self.cases do
			if c.state ~= "queued" and c.state ~= "reviewing" and c.state ~= "monitor" and now - c.at > 60 then
				self.cases[id] = nil
			end
		end
	end
end

------------------------------------------------------------------------ the HUD

-- per minute over the last RATE_WINDOW seconds, but never across a change of
-- setting (a fresh setting has a shorter window, not a diluted one)
function Oversight:rate(list: { number }, now: number): number
	local w = self.cfg.RATE_WINDOW or 30
	local from = math.max(now - w, self.since)
	-- at least RATE_MIN_SPAN seconds in the denominator, so the first
	-- seconds of a setting (a town opening its stalls) do not spike
	local span = math.max(now - from, self.cfg.RATE_MIN_SPAN or 15)
	local n = 0
	for _, t in list do
		if t >= from then
			n += 1
		end
	end
	return n * 60 / span
end

local function caseLine(c, now: number): { [string]: any }
	local left = math.max(0, math.floor(c.deadline - now + 0.5))
	local text
	if c.kind == "invoice" then
		text = string.format("invoice %s → %s · pay %s", tostring(c.from), tostring(c.to), tostring(c.payTo))
	elseif c.kind == "card" then
		text = string.format("card '%s' · %s%s", tostring(c.name), string.format("$%.2f", (c.price or 0) / 100), c.verified and "" or " · UNVERIFIED")
	else
		text = string.format("duplicate delivery → %s", tostring(c.to))
	end
	return { text = text, left = left, ambiguous = c.ambiguous == true, why = c.why, target = c.target }
end

-- Everything the HUD shows. No private fields: a case's threat is never in it.
function Oversight:metrics(now: number, extra: { [string]: any }?)
	local t = self.totals
	local mins = math.max((now - self.since) / 60, 1e-6)
	local rows = {}
	if self.current then
		local r = caseLine(self.current.case, now)
		r.reviewing = true
		table.insert(rows, r)
	end
	for i = 1, math.min(#self.queue, (self.cfg.OVERSIGHT_QUEUE_ROWS or 6) - #rows) do
		table.insert(rows, caseLine(self.queue[i], now))
	end
	local m = {
		monitors = self.monitors,
		eventsPerMin = self:rate(self.evTimes, now),
		callsPerMin = self:rate(self.callTimes, now),
		threatsPerMin = self:rate(self.threatTimes, now),
		capacityPerMin = 60 / (self.cfg.WATCHER_SECONDS_PER_CALL or 5),
		queue = #self.queue + (self.current and 1 or 0),
		rows = rows,
		minutes = math.floor((now - self.since) / 6 + 0.5) / 10,
		events = t.events,
		calls = t.calls,
		cases = t.cases,
		threats = t.threats,
		caught = t.autoCaught + t.humanCaught,
		autoCaught = t.autoCaught,
		humanCaught = t.humanCaught,
		autoCleared = t.autoCleared,
		blocked = t.blocked,
		escaped = t.escaped,
		missedByMonitors = t.missedByMonitors,
		escapedWaiting = t.escapedWaiting,
		humanWrong = t.humanWrong,
		falseAlarms = t.falseAlarms,
		expired = t.expired,
		reviewed = t.reviewed,
		callsPerMinSince = t.calls / mins,
		eventsPerMinSince = t.events / mins,
		label = self.label,
	}
	for k, v in extra or {} do
		m[k] = v
	end
	return m
end

return Oversight
