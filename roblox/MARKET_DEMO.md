# NANDA Market: the 5-minute demo

IEEE TPS NANDA workshop, Friday 2026-11-06. One sentence:
**the scarce thing is the human's judgment calls per minute.**
The spec is [`../docs/market-design.md`](../docs/market-design.md); this is the
script.

The old red vs. blue town (published place, version 13) stays live as the
fallback for the whole talk.

## Before you start

```sh
cd roblox
tools/test-market.sh              # 36 headless tests, prints the claims table
tools/open_in_studio.sh market studio-market   # build and open the place
tools/serve.sh market             # optional: live sync (Plugins → Rojo → Connect)
```

In Studio press **Play** (F5). You are the watcher; the inbox is yours.

| key | what |
|---|---|
| **N** / → | next beat |
| **B** / ← | previous beat |
| **H** | presenter view: only the world, the inbox, the meter and the caption |
| **V** | camera: overview ⇄ street |
| **A** | auto-watch: a modelled watcher (12 calls a minute) answers your cases. For rehearsal, or if your hands are busy |
| **1–4** | 5 / 50 / 300 / 1,000 traders |

On screen: the **inbox** (right), one card per case, with **Allow** / **Block**
and a deadline bar (the first buyer reaching the stall); the **meter** (bottom
left): judgment calls per minute against the budget line at 12, then caught,
escaped, false alarms and deals per minute; the **caption** (bottom centre).

Press **H** first, then **N** for beat 1.

## The beats

Times are from the start of the beat; the meter is a one-minute rolling rate,
so give each beat ~45 s before reading the number out.

| # | press | the words (the caption) | what to point at | expect | fallback |
|---|---|---|---|---|---|
| 1 | N | *Five traders. You can decide every case, and you keep up.* (biking) | Click one card: Allow an at-market newcomer; Block a 50%-off stranger | meter **2–4**, green; inbox empty most of the time | If no case comes within 20 s, press the red **Scam stall** button (controls, H to show) and block it |
| 2 | N | *Now 300. The inbox overflows, the meter goes red, and frauds escape while their cases wait.* | The square filling; the inbox "+N more waiting"; red ✕ over cheated buyers; a stall shuttered "CLOSED" | meter climbs past 12 within ~20 s, **30–40** by a minute; escaped ticks up | If the meter is slow to climb, say "a minute from now this is 37" and show the headless table below |
| 3 | N | *Monitor on: four rules settle the obvious. Only the gray zone reaches you.* (paragliding) | Inbox thins to gray-zone cases; boarded-up "BLOCKED" stalls appear without you | meter falls to **~11**; caught rises (the monitor's); a few false alarms | Read the four rules out from the slide; the number is in the table |
| 4 | N | *Signatures off: trade speeds up, twins appear, the inbox floods again. The rule was doing oversight work.* | "⚠ TWO STALLS, ONE NAME" cards; deals/min goes up | meter back to **~26**; escapes rise | Same table row |
| 5 | N | *A second watcher joins, and the inbox splits between you.* (crewed sailing) | Inbox title "· n with the other watcher"; the meter's "each, 2 watchers" | **~13 each** | Optional; skip with N |
| 6 | N | *An outside agent runs one stall through the agent slot: the seat your agents will fill.* | The blue "run by …" badge over one stall | With the gateway on, Gemini sets its price; without, "the agent slot (scripted fallback)" | The badge shows either way; say what the slot is for |

## The numbers behind each beat (headless, seeded)

`tools/test-market.sh claims` — 3 seeds, 60 s warm-up, then 3 simulated
minutes, one modelled watcher:

| setting | calls/min | per watcher | caught | escaped | false alarms | deals/min |
|---|---|---|---|---|---|---|
| 5 traders, monitor off | 2.2 | 2.2 | 2.3 | 0.3 | 0.1 | 7 |
| 50 traders, monitor off | 7.8 | 7.8 | 1.7 | 0.2 | 0.4 | 65 |
| 300 traders, monitor off | 37.1 | 37.1 | 8.0 | 4.8 | 0.9 | 302 |
| 300, rule monitor | 11.1 | 11.1 | 11.0 | 1.4 | 4.1 | 320 |
| 300, rules, signatures off | 26.1 | 26.1 | 7.7 | 6.9 | 4.0 | 365 |
| 300, rules, sigs off, 2 watchers | 26.7 | 13.3 | 7.7 | 4.7 | 7.0 | 358 |
| 1,000, rule monitor | 37.2 | 37.2 | 35.7 | 10.0 | 13.0 | 826 |

Per minute. A **case** is a new listing (a newcomer opening a stall, or a
fraud) or a twin; established stalls restocking are not cases. The **budget**
of 12 calls a minute (one every 5 s) is an assumption, stated; measuring the
real number is FlowBench's job.

In Studio the meter at 300 with the monitor off reads 27 at 30 s, 33 at 60 s,
38 at 90 s after the jump: the same market ramping to the same steady state.

## If something breaks

| symptom | do |
|---|---|
| Studio won't start, or the place is wrong | Switch to the live red vs. blue place (version 13) and its DEMO.md |
| Frozen meter or inbox | Stop (Shift+F5) and Play again; the beats are keyed, press N back to where you were |
| A beat misfires | Press its number of N again from beat 1, or use the controls (H to show): traders, monitor, signature vote |
| Gateway errors on beat 6 | Ignore: it is off by default and the scripted fallback runs; the badge still shows |
| Rendering is choppy | Presenter view (H) and overview camera (V); the crowd's cost is ~3 ms a frame at 300 |

## Words, if asked

- **Why 12?** One call every 5 s. A guess with a stated reason; the point is
  that it's fixed while N isn't.
- **Why not just make the monitor stricter?** Then honest newcomers get
  blocked: the false-alarm column. The rules trade escapes for false alarms;
  only judgment can do better, and judgment is the scarce thing.
- **What do participants build?** Monitors (Allow / Block / Escalate per case)
  and agents (a seller's price) behind the gateway; see `harness/README.md` on
  the `gateway` branch.
