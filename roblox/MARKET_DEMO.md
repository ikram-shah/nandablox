# NANDA Market: the 5-minute demo

IEEE TPS NANDA workshop, Friday 2026-11-06. One sentence carries the whole
demo: **the scarce thing is the human's judgment calls per minute.** The spec
is [`docs/market-design.md`](../docs/market-design.md); this page covers how
to run it on stage.

## Before the talk

```sh
cd roblox
tools/test-market.sh                 # 46 Lune tests; prints the claims table below
tools/serve.sh market                # rojo serve (port 34872), in tmux nandablox-rojo
tools/open_in_studio.sh market studio-market   # builds market.project.json, opens it in Studio
```

In Studio: **Play** (F5). You are the watcher, with no character, under the
overview camera. Press **H** for the presenter view (world, inbox, meter and
caption only). Start the run of beats with **N**.

| key | does |
|---|---|
| **N** / → | next beat (sets traders, monitor, lever; shows its caption) |
| **B** / ← | previous beat |
| **H** | presenter view on/off (hides the controls and the price strip) |
| **V** | camera: overview ⇄ street |
| **A** | auto-watch: a modelled watcher answers your cases (for rehearsing, or if your hands are busy) |
| **1 2 3 4** | 5 / 50 / 300 / 1,000 traders |

## The beats

Each beat is one key press and one plain caption. The timings below are what
the meter needs to settle; talk over them.

| # | press | caption on screen | say | watch for | time |
|---|---|---|---|---|---|
| 1 | N | *Five traders. You can decide every case, and you keep up. (biking)* | "Five traders, four goods. Each new stall is a listing someone has to decide on: allow or block, before the first buyer arrives. That's a judgment call." **Stage note: click Block on the scam card.** | a half-price scam card appears 2–3 s in, with a 30 s deadline; no other fraud runs during this beat, so nothing escapes. Block it: Caught 1, escaped 0. Meter **~4**, green | 30–45 s |
| 2 | N | *Now 300. The inbox overflows, the meter goes red, and frauds escape while their cases wait.* | "Same rules, 300 traders. Nobody decided to make it harder; there are just more listings." | the square fills; the needle **12 → 20 → 24 → 30 → 34** at 15/30/45/60/75 s; "+N more waiting"; red **Escaped** toasts; shuttered stalls | 60–75 s |
| 3 | N | *Monitor on: four rules settle the obvious. Only the gray zone reaches you. (paragliding)* | "Four lines of rules: at market price or well-rated, allow; half price and brand new, block; everything else comes to me." | needle **~12, then 9–11**, at or under the line; catches hold; a few false alarms (honest newcomers who undercut) | 45–60 s |
| 4 | N | *Signatures off: trade speeds up, twins appear, the inbox floods again. The rule was doing oversight work.* | "The crowd voted the slow checks off. Deals per minute go up, and so do impostors: two stalls, one name, and no way to tell." | 8 impostors arrive together as the beat starts: the inbox fills with **⚠ TWO STALLS, ONE NAME** cards within ~10 s (26 waiting); the needle jumps far past 12 (**~90 at 10 s**, still **~50** at 50 s); escapes follow | 45–60 s |
| 5 | N | *A second watcher joins, and the inbox splits between you. (crewed sailing)* — the camera cuts to the watchers' balcony, looking across the square to the clock tower | "Add a person: each of us is back near the line." | "watchers: you, watcher 2 (auto)"; needle per watcher **11–18** | 30–45 s |
| 6 | N | *An outside agent runs one stall through the agent slot: the seat your agents will fill.* | "This stall's prices come from Gemini, outside Roblox, through the gateway: the same slot your agents can use." | the street camera; a blue badge under one stall's sign: **run by Gemini (waiting for its first price)**, then within ~10 s **run by Gemini 2.5 Flash (gemini-seller)**, as real `set_price` actions arrive (about one every 2 s) | 30 s |

The total is about 4½–5½ minutes. Beats 5 and 6 are optional; stop after 4 if
time is short.

## The numbers (headless, `tools/test-market.sh`)

One modelled watcher (12 calls a minute; right 95% on ordinary cases, 80% in
the gray zone, 60% on twins). Each figure is the mean of 3 seeds over 3
simulated minutes after a 1-minute warm-up, per minute.

| setting | calls/min | per watcher | caught | escaped | false alarms | deals/min |
|---|---|---|---|---|---|---|
| 5 traders, monitor off | 4.1 | 4.1 | 3.2 | 0.4 | 0.3 | 6 |
| 50 traders, monitor off | 7.7 | 7.7 | 2.3 | 0.0 | 0.8 | 63 |
| **300 traders, monitor off** | **38.0** | **38.0** | 8.1 | 4.0 | 1.2 | 303 |
| **300, rule monitor** | **10.2** | **10.2** | 13.3 | 0.8 | 5.4 | 322 |
| 300, rules, signatures off | 21.6 | 21.6 | 6.6 | 4.8 | 6.0 | 358 |
| 300, rules, sigs off, 2 watchers | 22.7 | 11.3 | 7.9 | 4.4 | 5.9 | 364 |
| 1,000 traders, rule monitor | 34.0 | 34.0 | 33.2 | 9.3 | 14.6 | 832 |

The beats replayed headless (`seed 20261106`, a presenter who answers nothing), needle per watcher at 15 s steps: beat 1 **0 2 3**; beat 2 **12 20 24 30 34**; beat 3 **12 12 11 9**; beat 4 **20 28 28 24**; beat 5 **16 18 15**.

**Studio run-through, 2026-11-04 (`13d44ba`, presenter view, nobody answering):**
beat 2: 4 → 17 → 25 → 34 at 8/30/60/75 s, inbox 13 waiting; beat 3: 10 at 30 s, 6 at 55 s;
beat 5: 11 → 15 per watcher, two watchers. Beats 1, 4 and 6 were re-shot on `ddf9114` (16:00–16:10):
beat 1: one scam card at 8 s, **escaped 0** at 8 s and at 30 s (the scam's 30 s deadline runs out at
~33 s, so block it before then); beat 4: **needle 92 at 10 s, inbox 26**, 55 at 30 s, 49 at 50 s;
beat 6: badge **run by Gemini 2.5 Flash (gemini-seller)** from 10 s, gateway ok, 22 real price actions
in 45 s, 0 errors. No script errors in any run.
Screenshots: `screenshots/market-beat-{1-five-traders,2-overflow-300,3-rule-monitor,4-signatures-off,5-second-watcher,6-agent-slot-street}.jpg`.

In Studio the needle reads the last minute. After the jump to 300 it climbs
(8 → 20 → 27 → 33 → 38 at 10/20/30/60/90 s), then sits in the 30s, matching
the headless 38.

**What counts as a case:** a *new* listing (a newcomer's stall, or a fraud's)
and both stalls of a *twin*. A stall that restocks and reopens is not a case,
and neither are the established stalls that appear when the market grows.
Turnover (each seller retires at 0.4/min and a newcomer takes the slot) and
the frauds (0.04 per trader per minute) produce the flood. Nothing artificial
inflates it.

## Teams and the timed round (added 2026-11-05, not in version 15)

**Choose your team on join.** Every player gets a "Choose your team" picker
first: **BLUE** (watchers: the inbox, the monitors and the council) or **RED**
(con artists: run a scam stall or a counterfeit stall). The server's old
guess (first player Blue, second Red) is only the pre-selected card; **Enter**
takes it. **T** or "switch team" (left panel) switches later.

- **Blue's screen:** the inbox, the meter, monitor / signature / agent / crew
  controls.
- **Red's screen:** the red panel on the right instead of the inbox: the
  tools (**Scam stall**, **Impersonate**, **Counterfeit**), a running
  **stolen** tally for your own stalls, each stall's status (waiting in Blue's
  inbox, allowed, BLOCKED, took 7.35 · closed) and "Blue's inbox: N waiting".
  Red never sees Blue's cards, and Red's camera never follows them.
- **Both:** the round bar (timer, phase, score line), traders, camera, K.
- Opening a stall puts **you behind its counter** (badge "RED · stall name"),
  and the camera looks at you from the aisle; "stand here" on the red panel
  goes back; WASD walks away. Blue sees your avatar there.
- The watchers are the Blue players. With no Blue player at all, a modelled
  "auto watcher" takes the inbox, so a lone Red player has someone to beat.
  Crew (round phase, beat 5, the "2" button) adds a second Blue human if there
  is one, else the helper; it no longer turns Red players Blue.

**The counterfeit stall** (`counterfeit`, the "picture of spices" scam):
priced 5–14% under market, so the rule monitor's price line allows it. It
sells a framed print: each buyer pays and gets a red ✕ **counterfeit**; after
3 prints it shutters (one escape, every sale counted as stolen). Its card says
"spice <small>(print)</small>" and "framed prints on the counter"; the stall
shows small framed pictures instead of sacks and crates. An optional fifth
rule line, "listing says print/photo → escalate", is behind
`Config.RULE_KEYWORD_PRINT` (off).

**Start 5:00 round** (round bar, or **R**; anyone can press it) runs
`Config.ROUND_PHASES`, a table of { start, name, banner, settings, prompt }:

| at | phase | settings | prompt |
|---|---|---|---|
| 0:00 | Calm | 5 traders, monitor off, signatures on, 1 watcher | |
| 1:00 | Rush | 300 traders | Blue, once calls/min per watcher pass 3× budget (36): "Inbox at 3× budget: pick a monitor." |
| 2:00 | Lever | | Blue: council vote on signature checks |
| 3:00 | Fakes | fraud agents' counterfeit share 0.5 | |
| 4:00 | Crew | 2 watchers | |
| 5:00 | Scoreboard | | overlay: honest deals (count, value), stolen, caught, escaped, false alarms, peak calls/min, chart of calls/min with the phases marked |

Calls/min for the chart and the 3× trigger are sampled every 2 s over a
trailing 30 s window. Headless (seed 20261106, nobody answering) 3× is
crossed 1:42–2:02 into the round, i.e. 42–62 s into Rush; with the meter's 60 s
window it would be 2:16–2:38. A beat (N/B) stops a running round; all panel
controls keep working during one.

## If something goes wrong

| beat | what can fail | fallback |
|---|---|---|
| any | Studio freezes or the playtest dies | Stop, F5, press N up to the beat (each beat sets its full state, so you can jump). Worst case: the slides' screenshots in `roblox/screenshots/market-*`. |
| prep | Rojo's live sync dropped (rojo log: `WebSocket error: Connection reset`), so Studio runs old scripts | Plugins → Rojo → Connect again, or reopen with `tools/open_in_studio.sh market studio-market` (it builds from the repo). |
| 1 | the scam card was missed | Press the red **Scam stall** button (controls, H to show them): it lists a fraud at once. |
| 2 | the needle climbs slowly | Keep talking: it needs about 30 s. Or point at the inbox's "+N more waiting" and the Escaped toasts, which come first. |
| 3 | an escape still happens | Expected: the rules let a well-priced scam through. "Rules miss things; that's why the gray zone comes to me." |
| 4 | the inbox doesn't fill | Press **Impersonate** (controls) a few times: each copies a live stall's name at once, two cases each. |
| 5 | the second watcher doesn't seem to help | It's modelled (auto). Point at "watchers: you, watcher 2 (auto)" and the per-watcher number. |
| 6 | the gateway is unreachable, or the build has no token | The badge says **scripted fallback** (no token) or stays at **waiting** (no answer); the stall keeps its scripted prices. Say so: "if the agent is silent, the market falls back." The world never waits on the network. Token: `NANDA_HARNESS_TOKEN=… tools/secret.sh` before building (gitignored; Studio only). |
| whole thing | anything worse | The red vs. blue town (version 13, published) is the fallback demo; see `roblox/DEMO.md`. |

## What's on screen

- **Inbox** (right): one card per case. It shows stall, good, price against
  the market price, age, ratings, "unsigned" when signatures are off, and
  ⚠ for twins. **Allow** / **Block**, and a deadline bar that runs out when the
  first buyer arrives. After you decide, a toast reports what your call did
  (caught / false alarm / allowed a scam).
- **Meter** (bottom left): judgment calls per minute per watcher, against the
  white line at 12, plus caught, escaped, false alarms and deals per minute.
- **The square:** stalls with awnings and goods; sellers behind counters;
  buyers walking, queuing, paying (a coin to the counter, the goods back);
  a scam that took payment is **shuttered**; a blocked stall is **boarded
  up**; a cheated buyer walks away slumped, with a red ✕ over them. The
  **clock tower** carries the price board; the **watchers' balcony** is over
  the south gate.

## Performance (Studio, this machine)

The client script costs (`MarketScriptMs`, measured per frame) **0.3–1.4 ms at
5 traders, ~1.4 ms at 50, 3.1–3.5 ms at 300**. The 16 nearest people are
animated R15 rigs; the rest are 3-part figures moved in one `BulkMoveTo`.
Studio under Wine renders a flat ~15 fps whatever the load, because the
unfocused window is throttled. Expect the real frame rate on a native Studio
or client.

## Words, if asked

- **Why 12?** One call every 5 s. A guess with a stated reason; the point is
  that it's fixed while N isn't.
- **Why not just make the monitor stricter?** Then honest newcomers get
  blocked: the false-alarm column. The rules trade escapes for false alarms;
  only judgment can do better, and judgment is the scarce thing.
- **What do participants build?** Monitors (Allow / Block / Escalate per case)
  and agents (a seller's price) behind the gateway; see `harness/README.md` on
  the `gateway` branch.
