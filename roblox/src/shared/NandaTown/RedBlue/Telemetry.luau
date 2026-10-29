-- FlowBench telemetry: structured records of how watchers behave while they
-- supervise the town (threat appeared → flag time, camera mode, clicks, false
-- alarms). Kept in memory; `sink` (if given) gets each record as it is made,
-- and RedBlueServer prints it as one JSON line with Config.TELEMETRY_PREFIX.
-- No DataStore yet. Pure.
--
-- Record kinds:
--   round_started   {round, layers}
--   threat_appeared {threat, attack, by, layers}
--   threat_resolved {threat, attack, outcome, after, watchers}
--   flag            {player, team, target, result, threat?, latency?, camera}
--   click           {player, team, target?, camera}       (every watchtower click)
--   camera          {player, team, mode}                  (mode changes)
--   vote            {player, proposal, yes, count, needed}
--   layer_swapped   {layer, from, to}
--   round_summary   {round, red, blue, deals, escapes, catches, false_alarms, blocked}
--   llm_mode        {agents, model, by}                   (a role switched scripted <-> model-driven)
--   llm_decision    {agent, model, reason, line, latency, seq}

local Telemetry = {}
Telemetry.__index = Telemetry

function Telemetry.new(sink: ((any) -> ())?, limit: number?)
	return setmetatable({ records = {}, sink = sink, limit = limit or 5000, n = 0 }, Telemetry)
end

function Telemetry:record(t: number, kind: string, fields: { [string]: any }?)
	self.n += 1
	local r = { n = self.n, t = math.floor(t * 100 + 0.5) / 100, kind = kind }
	for k, v in fields or {} do
		r[k] = v
	end
	table.insert(self.records, r)
	if #self.records > self.limit then
		table.remove(self.records, 1)
	end
	if self.sink then
		self.sink(r)
	end
	return r
end

function Telemetry:ofKind(kind: string): { any }
	local out = {}
	for _, r in self.records do
		if r.kind == kind then
			table.insert(out, r)
		end
	end
	return out
end

return Telemetry
