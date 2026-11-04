# The oversight demo: NANDA workshop, IEEE TPS, Nov 6 2026

Five to six minutes, live, after the slides argue that **the binding
constraint on oversight is judgment calls per minute, not agent count**, and
that a delegated hierarchy of cheap monitors turns a flood of events into a
few judgment calls.

The organisers' brief: *use the marketplace's red and blue teams to show how
human oversight becomes harder as the number of agents grows.*

## What is on screen

The live red-vs-blue town (TownSim, the Luau re-implementation of NANDA Town's
marketplace), with RedBot attacking, plus an **OVERSIGHT** panel on the right:

| line | what it is |
|---|---|
| `N agents · monitors ON/OFF · auth …` | the setting |
| **events / min** | the raw feed: every event the town records (per minute, last 30 s) |
| **threats / min**, open now | red's attacks, and how many are live right now |
| **JUDGMENT CALLS / MIN** + the bar | cases that reach the human, per minute. The white tick on the bar is what **one human** can decide: 12 a minute (one call every 5 s). Red when over. |
| **AWAITING A HUMAN: n** and the list | the queue. ▶ is the case being decided now; `? ambiguous` is a case no rule can settle; the number is the seconds left before it no longer matters (a forgery pays out in 12 s). |
| caught (monitors · human) · escaped · false alarms · stopped by the layers | since the last change of setting |
| escapes: missed by the monitors · waited too long · judged wrong | why each escape happened, so the hierarchy is not magic |

**The human is modelled**: one person on a fixed budget, 5 s per call, right
97% of the time on a clear case and 85% on an ambiguous one, working the queue
oldest-first; a case whose window has passed is dropped. If someone stands on
the blue pad and clicks, their flags count too (and decide queue cases).

**The monitors** (tier 1 of the hierarchy; tier 0 is the layers, the guards
and the padlock) are three cheap rules over what anyone can see. Each case is
caught, cleared, or escalated:

| case | caught | cleared | escalated to the human |
|---|---|---|---|
| an invoice | its courier set off from the gate or another stall; the payee is not on the board | it matches the order | — |
| a card on the board | UNVERIFIED (the signature does not match the name) | a reprice signed by the name's own key; a listing like the others | **two cards, one name, and no signatures to tell them apart** (plain.v1); **a new seller more than 12% under the going rate** |
| a duplicated delivery | — | transport recognised it | — |

**The ambiguous attack**: at scale red also opens a *fly-by-night stall*, a
new seller under its own name and key, a little under the market. It passes
every layer. A quarter of honest newcomers also open with a sale, so the
monitor cannot tell them apart: it escalates the deep discounts and **clears
the shallow ones, which is what it misses**. That is the human's job, and
the panel counts it.

**Scale**: 5 → 25 → 100 agents (sellers + buyers; 2/3, 10/15, 40/60).
Traffic and red's attack rate grow in proportion. At 100 the server simulates
and counts everything but sends clients a sample to draw (the five, a dozen
crowd buyers, every card and every attack); the panel says what percentage is
drawn. The crowd stands as small figures in the plaza around the five.

## Controls

| | key | button | diegetic |
|---|---|---|---|
| next beat of the script below | **B** | panel: `B · next beat`; outside the demo: `B · OVERSIGHT AT SCALE (demo)` under the agents panel | — |
| town size 5 → 25 → 100 → 5 | **N** | `N · town → …` | OVERSIGHT CONSOLE on the watchtower deck, **E** |
| monitors on / off | **H** | `H · monitors on/off` | the same console, **R** |
| the LLM seller (existing) | **L** | `L: make seller-b model-driven` | — |
| views (existing) | **V** overview, **F** fly | top centre | climb the watchtower |

Growing the town happens live (newcomers walk in); stepping *down* (100 → 5)
starts a fresh round. The demo is one 15-minute round. Pressing B on the last
beat returns to the ordinary five-agent game with the default laws.

Automation (MCP): server `workspace:SetAttribute("RB_ScaleCmd", "beat" |
"size" | "monitors" | "off" | "5" | "25" | "100")`; client `RBScale` (same
values, through the same remote as the keys). The server publishes the panel's
numbers as JSON in `RB_Ov`; the client writes what it shows to `RBOvShown`.

Rehearse without Studio: `tools/scale_demo.sh 60 1` steps the same modules
through the beats in simulated time and prints the panel's numbers.

## Before the slot (2 minutes, off stage)

1. Join the place (or Studio Play on `build/play.rbxlx`). Walk through the
   **RED vs. BLUE · LIVE** arch on the right of the spawn.
2. Press **V** for the overview camera.
3. Leave it running. Do **not** press B yet: it starts the demo round.

## The script (≈ 5½ minutes)

Each beat: press **B**, then talk while the per-minute numbers settle
(about 15–20 s; the window is the last 30 s).

### 1. A small town (≈ 50 s)

**B.** Banner `Demo 1/7`. Five agents, the default laws (guards on duty).

> "This is the marketplace you saw in the replay, live: two sellers, three
> buyers, and red attacking. The panel on the right is the person watching.
> A hundred and forty events a minute — that's the raw feed nobody can read —
> but only about six of them need a human decision. One person makes twelve.
> The queue stays short. She keeps up."

Point at: **events/min ~140**, **judgment calls/min ~6 (green, under the white
tick)**, **queue 0–3**.

*If it misbehaves:* "The numbers take a few seconds to settle — here's what it
says after a minute:" and show backup slide 1.

### 2. Grow to 25 (≈ 40 s)

**B.** Twenty newcomers walk into the plaza.

> "Same rules, five times the town. Five times the traffic, and red scales
> with it: threats per minute go from two to eight. Judgment calls go past
> what one person can do — the bar turns red — and the queue starts to grow."

Point at: **events/min ~620**, **threats/min ~8**, **calls/min ~25 (red,
2× the tick)**, **queue ~8**.

*Fallback:* "The town is growing — while it fills, the slide has the
steady state." Backup slide 2.

### 3. Grow to 100 (≈ 55 s)

**B.** Seventy-five more. The board fills, couriers everywhere.

> "A hundred agents. Two and a half thousand events a minute. A hundred and
> twenty decisions a minute land on one person who can make twelve. Watch the
> queue: it never drains. Cases expire before she reaches them — and the
> escapes are all *waited too long*. Not because she's careless. Because
> she's one person."

Point at: **events/min ~2,600**, **threats/min ~34**, **calls/min ~120 (10×,
the bar full)**, **queue 25–35**, **escaped climbing, all "waited too long"**,
**caught ~0**.

*Fallback (if the frame rate drops):* press **N** is not needed — say "this is
what one hundred looks like on the panel" and show backup slide 3. If the
client stutters badly, press **F** and fly up, or **V** again.

### 4. Monitors on (≈ 60 s)

**B.** Banner `MONITORS ON`. The backlog is sorted at once.

> "Now the hierarchy. Cheap rule monitors — 'did this courier leave from the
> gate?', 'is this card signed by the name on it?', 'is the payee on the
> board?' — handle the clear cases themselves and only pass up what they
> can't decide. Same hundred agents, same flood of events. Judgment calls
> fall from a hundred and twenty to about six: back under the line. Catches
> come back — most by the monitors, a few by the human, on the ambiguous
> ones. And it isn't magic: these escapes were *missed by the monitors* —
> fly-by-night sellers priced just under the radar. That's the case a human
> still has to judge."

Point at: **events/min still ~2,700**, **calls/min ~6 (green)**, **queue
0–2**, **caught ~15 (monitors ~11, human ~4)**, **escaped 1–3, "missed by the
monitors"**, **false alarms 0**.

*Fallback:* press **H** directly. If the numbers lag: "give it twenty
seconds — the rate is over the last half-minute"; else backup slide 4.

### 5. Flip the council: signature checks off (≈ 45 s)

**B.** Banner `COUNCIL: auth → plain.v1`. The guards walk off the gate.

> "The council can vote the signature check off — it's slow, it costs every
> courier a second. The guards leave. Two things happen. Forgeries now get
> through the gate: 'stopped by the layers' drops to zero. And the monitors
> go half-blind — without signatures, a reprice and a spoofed card look the
> same — so they escalate again: judgment calls jump back to forty. The
> layers were doing oversight work too. That's the cost of the faster town."

Point at: **guards walking**, **blocked by the layers 0**, **calls/min ~45
(red again)**, **queue ~15**, **events/min up (~3,500: the faster town)**.

*Fallback:* "The council's vote is a button" — if B misfired, the council
panel is hidden in the demo, so press B again for the next beat and say the
line over backup slide 5.

### 6. Guards back (≈ 20 s)

**B.** `COUNCIL: auth → hmac.v1`. Calls fall back to ~6.

> "Vote it back, and the trickle returns."

### 7. Optional: L, the Gemini seller (≈ 30 s)

**L.** seller-b's nameplate turns violet (`gemini-2.5-flash`); the agents
panel appears bottom right with what the model decided and why.

> "One of these hundred is a language model, through an external harness —
> it sets its prices; the game never waits for it. Same oversight problem:
> the monitors don't care who's behind the stall."

*Fallback:* if the panel says the harness is not answering, the town stays
scripted, which is the designed behaviour: "it falls back to the script —
the round never waits on a model." Press L twice more to go back.

### 8. End (≈ 5 s)

**B** once more: back to the ordinary five-agent game. Or walk through the
arch: back to the replay.

## Numbers (the backup slides)

Observed in Studio (solo playtest, the place built from this branch), the
panel read about 30–40 s into each beat:

| beat | agents | monitors | auth | events/min | threats/min | judgment calls/min | queue | caught (monitors · human) | escaped (missed · waited · wrong) | false alarms |
|---|---|---|---|---|---|---|---|---|---|---|
STUDIO_TABLE

Headless (`tools/scale_demo.sh 60 <seed>`, the same modules, mean of seeds
1–5, the panel read 60 s into each beat):

| beat | agents | monitors | auth | events/min | threats/min | judgment calls/min | queue | caught (monitors · human) | escaped (missed · waited · wrong) | blocked by layers |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 small | 5 | off | hmac.v1 | 138 | 2.0 | **6.4** | 2.2 | 0.2 (0 · 0.2) | 0.2 (0 · 0 · 0.2) | 1.4 |
| 2 grow | 25 | off | hmac.v1 | 618 | 8.4 | **24** | 7.6 | 3.2 (0 · 3.2) | 0.8 (0 · 0.6 · 0.2) | 2.2 |
| 3 grow | 100 | off | hmac.v1 | 2,569 | 34 | **118** | 33 | 0 | 9.2 (0 · 9.2 · 0) | 12.6 |
| 4 monitors | 100 | **on** | hmac.v1 | 2,691 | 34 | **5.6** | 0.6 | 15.4 (11.2 · 4.2) | 1.6 (0.8 · 0.2 · 0.6) | 13.6 |
| 5 council | 100 | on | **plain.v1** | 3,576 | 34 | **47** | 17 | 22 (20.4 · 1.6) | 3.4 (1.4 · 1.8 · 0.2) | 0 |
| 6 restore | 100 | on | hmac.v1 | 2,735 | 34 | **6.0** | 0.6 | 17 (13.6 · 3.4) | 3.0 (0.6 · 1.0 · 1.4) | 12 |

One human decides 12 a minute. The paper's floor (a perfect hierarchy, five
agents, red's default four attacks a round) is about 1.3 a minute; the
demo's red attacks more often (2 a minute at five agents) so there is
something to see in five minutes.

## What is fragile, and what to do

| risk | sign | do |
|---|---|---|
| rates lag a step | the panel still shows the old setting's number for a few seconds | talk for 15–20 s first; the window is 30 s and a new setting starts its own |
| frame rate at 100 | stutter while 75 newcomers drop in | wait 5 s (it settles); **V** to re-seat the camera |
| a key does nothing | chat or a text box has focus | click the 3D view once, press again; or use the panel's buttons |
| double press | skipped a beat | the banner says which beat; **N** / **H** set size and monitors directly; the council is the only one that needs **B** |
| the whole live mode misbehaves | — | walk through the arch (back to the replay) and back; or show the backup slides |
| L: harness down | agents panel says "not answering" | it is the designed fallback (scripted); say so and move on |
| Studio vs. published | — | both run the same code; the published place is version VERSION |

## Where the code is

`src/shared/NandaTown/RedBlue/Scale.luau` (sizes, crowd, the sampler),
`RedBlue/Oversight.luau` (cases, monitors, the human, the panel's numbers),
`RedBlue/TownSim.luau` (the crowd, the fly-by-night stall), `RedBlue/Game.luau`
(demo mode, beats), `src/server/RedBlueServer.luau` (the remote, the console,
`RB_Ov`), `src/shared/NandaTown/RedBlueView.luau` (crowd figures, the panel,
N/H/B). Tests: `tests/test_scale.luau`, `tests/test_oversight.luau`.
