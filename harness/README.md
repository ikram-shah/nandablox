# nanda-harness

The external LLM agent harness for NANDA Town in Roblox. The Roblox server
polls it over `HttpService` and feeds what it returns into the game's existing
policy interface, so one trader in the town is driven by a language model
instead of a script.

Standard library only: nothing to install.

```sh
harness/run.sh                      # http://127.0.0.1:8790, gemini-2.5-flash
harness/run.sh --model gemini-3.5-flash
harness/run.sh --no-llm             # serve the API, never call a model
cd harness && python -m pytest -q   # 30 tests, no network
```

`GEMINI_API_KEY` is read from the environment or `~/.env`. It is never
printed, logged or put on a command line; the harness only says whether it has
one.

| call | auth | what |
|---|---|---|
| `POST /v1/tick` | yes | one observation of the market → the actions that are ready |
| `GET /v1/health` | yes | key, model, budget, counts, each agent's current action |
| `GET /metrics` | yes | counts, spend estimate, p50/p90 latency, fallbacks, who is calling |
| `GET /v1/log?n=20` | yes | the last n decisions: prompt, answer, latency, tokens |
| `POST /v1/reset` | yes | forget every stance |
| `GET /healthz` | **no** | is the process up (the platform's probe); no counts, no secrets |

`POST /v1/tick` never blocks on the model: it queues a decision request and
returns what the background workers have already finished. The game applies
whatever is there and carries on; if nothing is, the agent is scripted.

The model may only move numbers inside a range and pick one `reason` code from
a closed list (`nanda_harness/schema.py`); the game writes its own sentences
from the code. Every prompt and decision is one JSON line, by default under
`$TMPDIR/nanda-harness/decisions.jsonl`, with a one-line summary (no prompt,
no answer) on stdout for the platform's log.

## Hosted

A published Roblox server cannot reach `localhost`, so for the live place the
same service runs on Railway (project `nanda-harness`, built from
`harness/Dockerfile`):

<https://nanda-harness-production.up.railway.app>

Deploy, from this directory:

```sh
railway link --project d5333929-4c25-4ecd-9203-057f829fc074
railway up --detach                      # tests/ is left out by .railwayignore
curl -s https://nanda-harness-production.up.railway.app/healthz
```

`GEMINI_API_KEY` and `NANDA_HARNESS_TOKEN` are Railway service variables.
Neither is ever in this repo, in an image layer, or in a log line.

### What protects it

**A shared secret on every endpoint but `/healthz`.** `Authorization: Bearer
<token>` (or the older `x-nanda-token`), compared with `hmac.compare_digest`;
anything else is `401`. The Roblox server sends it from the experience's
secrets store — see `Config.LLM_SECRET` in the game, and
`roblox/tools/secret.sh` for the fallback that bakes it into the built place.
A public bind with no token is refused at startup.

**Budget caps, server-side, so the key cannot be drained.** Calls per minute /
hour / day, plus a dollar ceiling per rolling day and per process lifetime.
Spend is counted from Gemini's own token counts at the model's list price
(`limits.py`). Over any cap the harness stops calling the model and **keeps
answering 200** with the stance each agent already has: the game re-stamps a
stance it is handed, so the town trades on normally and no round ever fails on
a cap. `/v1/tick` says `"llm": "budget"` and names the cap that bound.

**Rate limits, per IP and per Roblox server.** The game sends its `game.JobId`
as `X-Nanda-Server`, so one live server cannot monopolise the harness however
many are running; over the limit it is `429` with `Retry-After`, which the
game's own backoff already handles. A global ceiling sits above both, and
failed authentications are counted per address and shut that address out —
counting failures only, so the game is never throttled by someone else's
guessing.

**Nothing a caller invents costs money.** At most `--max-agents` agents are
tracked, and `NANDA_HARNESS_AGENTS` pins which names are allowed at all
(`seller-b,buyer-3` in production).

| variable | default | what |
|---|---|---|
| `PORT` | 8790 | the platform sets this |
| `NANDA_HARNESS_HOST` | `127.0.0.1` | `0.0.0.0` to accept from outside |
| `NANDA_HARNESS_TOKEN` | — | the shared secret; required for a public bind |
| `GEMINI_API_KEY` | — | without it the harness serves and the town stays scripted |
| `NANDA_HARNESS_MODEL` | `gemini-2.5-flash` | |
| `NANDA_MAX_PER_MINUTE` / `_HOUR` / `_DAY` | 40 / 1200 / 6000 | model calls |
| `NANDA_MAX_USD_PER_DAY` / `_TOTAL` | 2 / 20 | rolling 24 h; total since this process started |
| `NANDA_PER_IP_PER_MINUTE` | 300 | requests. Generous because several Roblox servers can share one egress address; the budget, not this, is what guards the money |
| `NANDA_PER_SERVER_PER_MINUTE` | 45 | requests, per `game.JobId` (the game polls 24/min) |
| `NANDA_GLOBAL_PER_MINUTE` | 900 | requests |
| `NANDA_HARNESS_AGENTS` | any | allowlist of agent names |

The dollar *total* is since the process started: a container that restarts
forgets it. The rolling-day cap and the per-minute/hour/day call caps are the
ones to trust, and they bound the worst case on their own
(6000 calls/day × ~$0.0002 ≈ $1.20).

The whole story — how it plugs into the game, what it measures, what hosting
it took — is in
[`../roblox/README.md`](../roblox/README.md#model-driven-agents-one-llm-through-an-external-harness).
