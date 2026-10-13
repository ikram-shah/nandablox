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

Everything in the place comes from this directory: the Rojo project files and
the code under `src/`. The town is built from parts at runtime, so there are no
uploaded assets. Studio is only a viewer of a place built from the repo; nothing
is made or changed by hand in it. Built places (`build/`, `*.rbxlx`) are
git-ignored artifacts.

Rojo is pinned in `rokit.toml` (`rojo-rbx/rojo@7.7.0`, the version of the Rojo
plugin installed in Studio). `tools/rojo.sh` runs that version through rokit and
refuses to run any other version, and every script below goes through it.
Nothing uses the `rojo` that happens to be first on `PATH`.

```sh
tools/build.sh                   # build/default.rbxlx from default.project.json
tools/open_in_studio.sh          # build, copy into the Wine prefix, open Studio in tmux 'studio-nanda'
```

Then press **Play (F5)**. In the replay: **R** restarts, **Space** pauses,
**1 / 2 / 4** sets the speed. To pick another scenario, change the `Trace`
attribute in `default.project.json` (`$attributes` on `NandaReplay`), e.g.
`supply_chain`, and rebuild or let `rojo serve` sync it.

**Dev loop: `rojo serve` plus the Rojo plugin.**

```sh
tools/serve.sh                   # rojo serve default.project.json on localhost:34872
```

In Studio: **Plugins → Rojo → Connect** (localhost, port 34872). Edits under
`src/` and in the project file then sync into the open place. Studio runs under
the Vinegar flatpak, which can't see `~/prg`, so `open_in_studio.sh` copies the
built place into the Wine prefix (`C:\nanda\`). `rojo serve` needs no copy,
because the flatpak shares the host network and Studio reaches `localhost`
(checked 2026-10-12: Studio fetched `http://localhost:34872/api/rojo` and got
this project's name back from Rojo 7.7.0).

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
| `default.project.json` | the Rojo project: code, the `Trace` attribute, lighting, no characters |
| `rokit.toml` | pins Rojo 7.7.0 |
| `tools/` | pinned-Rojo wrapper, build, serve, Studio launcher, trace converter |
| `traces/` | the 11 converted Lab runs as JSON |

Never published, nothing uploaded, no Robux spent.
