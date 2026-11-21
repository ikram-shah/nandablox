# HALHack pilot: a monitor that sees what the human sees

Ikram Shah · HALHack pilot, Nov 20, 2026 · Track: human oversight / watchtower

## Problem

In NANDA Market at 1,000 traders, a human watcher gets about 12 judgment calls a minute. With the built-in `rules` monitor, obvious scams (50%+ below market, unvouched, empty counter) still land in the human's inbox and expire before anyone reaches them. About 40% of frauds escape.

## What I built

1. **A monitor for the "yours" slot** (`harness/starter/my_monitor.py`). It reads each new stall, then:
   - **blocks** stalls that are new, unvouched, and have an empty counter or a below-market price (scam, smooth-talker and counterfeit patterns)
   - **blocks** stalls with an invalid signature
   - **allows** stalls that are vouched or established and priced plausibly
   - **escalates** only the ambiguous cases to the human: vouched but 28%+ below market (a possible bought vouch), twins when signatures are off, and an established seller who suddenly drops 35%+

2. **A three-line change to the game** (`MarketSim.luau`, `gatewayRequest`). The human's inbox card shows *vouched* and *stocked / no crates*, but the request sent to an outside monitor stripped both fields. Outside monitors were judging with less evidence than the human. The change passes them through:

```lua
vouched = p.vouchedBy ~= nil,
stocked = p.hasStock == true,
```

## Results (1,000 traders, signatures on, 2 watchers, the game's rolling 60 s meter)

| | rules (built-in) | my monitor v1 (game's fields only) | my monitor v2 (+ vouched, stocked) |
|---|---|---|---|
| Frauds caught | 36 | 173 | 139 |
| Frauds escaped | 24 (40%) | 3 (2%) | 2 (1.4%) |
| False alarms | 1 | 32 | 1 |
| Honest deals / min | 775 | 862 | 863 |
| Human judgment calls / min | TBD | not captured | 3–8 (budget 12) |

Across the whole v2 session (about 4 minutes), total theft was 7.43 NB, against 138.6 NB in 90 seconds under `rules`.

Caught counts vary with Red's attack volume, so compare escape rates and false alarms.

## What worked and what didn't

- **v1** (price, ratings and signature only) stopped almost all theft but blocked many honest newcomers (32 false alarms a minute). It couldn't tell a cheap vouched newcomer from a scammer.
- **v2** used the same rules plus the two fields the human already sees. Escapes stayed low, false alarms fell to the built-in's level, and the human's load stayed under budget. What's left in the inbox is the case a human should judge: vouched but suspiciously cheap.
- **Caveat:** in this simulation, honest newcomers are always vouched and most fraud types never are, so v2 benefits from how the game is built. Bought vouches and stolen IDs still need a human or other checks.
- **Scripted rounds** reset the monitor at every phase, so I measured in free play.

## Takeaway

Before adding more AI to oversight, first give the automated layer the evidence the human already sees. Then let it filter, so the human handles only the cases that need judgment.

## Run it

```sh
export SLOT_TOKEN=<any long secret>
python3 harness/starter/my_monitor.py &
harness/run.sh --no-llm --allow-localhost &
curl -s -X POST http://127.0.0.1:8790/v1/monitors \
  -d '{"name":"ikram","url":"http://localhost:8801","token":"'$SLOT_TOKEN'"}'
# Studio: open the market place built with GATEWAY_ENABLED=true and GATEWAY_URL=http://localhost:8790,
# then in the command bar: game:GetService("HttpService").HttpEnabled = true. Play, Monitor -> yours.
```
