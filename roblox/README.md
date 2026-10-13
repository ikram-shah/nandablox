# NANDA Town in Roblox: spike S0

S0 replays **one real NANDA Town run** in Roblox Studio as a town square. Each
protocol layer that acts during the run gets its own building:

- the gate and guards (auth)
- the notice board (registry)
- market stalls (negotiation)
- roads and couriers (transport)
- the bank and vault (payments)
- the review wall and stars (trust)
- the courthouse (data_facts, the verdict)

No network is involved: the trace ships inside the place. The design behind
it is in `../research/roblox-nanda-town.md` (S0 in its "Spike ladder"), and
the trace format is described in `../research/nandatown.md` §4.

![verdict](screenshots/06-verdict.png)

## Status (2026-10-12)

- The marketplace run (seed 42, 65 events) replays from start to finish, both
  in edit mode and in a real Play-mode playtest of the Rojo-built place. It
  ends on "VERDICT: PASSED · 8/8 stages", and the ledger shows money is
  conserved.
- All 11 Lab scenarios are converted and load cleanly (`traces/`,
  `src/shared/NandaTown/Traces/`). Four of them (auction, voting,
  capability_spoofing, supply_chain) also replayed to the end with no
  warnings. Scenarios with other roles (ballot box, council, factory) still
  reuse the marketplace layout; S1 will give them their own.
- Frames: `screenshots/01-quotes` → `02-haggle` → `03-deal-escrow` →
  `04-duplicate-fault` → `05-reputation` → `06-verdict`.

## Run it

```sh
tools/open_in_studio.sh          # rojo build, copy into the Wine prefix, open Studio in tmux 'studio-s0'
```

Then press **Play (F5)**. In the replay: **R** restarts, **Space** pauses,
**1 / 2 / 4** sets the speed. To pick another scenario, set the `Trace`
attribute on `StarterPlayerScripts/NandaReplay`, e.g. `supply_chain`.

There is also a live-edit loop with no rebuild. Serve this directory with
`python3 -m http.server 34901 --bind 127.0.0.1 --directory ~/prg/mit-nanda/roblox`,
then paste `tools/load_into_studio.luau` into Studio's command bar (or send it
through the MCP `execute_luau`). It pulls the current sources over localhost
and replays in edit mode. This also settles one open question in
`research/roblox.md`: **Studio can reach localhost.**

New traces: `tools/trace_to_luau.py <run-dir or events.jsonl> --luau
src/shared/NandaTown/Traces/<name>.luau --json traces/<name>.json`.

## Layout

| path | what |
|---|---|
| `src/shared/NandaTown/Town.luau` | builds the square and buildings |
| `src/shared/NandaTown/Replay.luau` | turns the event stream into animations: couriers, coins, bubbles, stars, faults, verdict |
| `src/shared/NandaTown/Hud.luau` | title, legend, ledger, ticker, stage list |
| `src/shared/NandaTown/Util.luau` | tweens, clock, pause and speed |
| `src/client/NandaReplay.client.luau` | Play-mode runner with a fixed overview camera |
| `tools/` | trace converter, Studio launcher, live loader |
| `traces/` | the 11 converted Lab runs as JSON |

Never published, nothing uploaded, no Robux spent.
