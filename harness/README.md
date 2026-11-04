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
cd harness && python -m pytest -q   # 51 tests, no network
```

`GEMINI_API_KEY` is read from the environment or `~/.env`. It is never
printed, logged or put on a command line; the harness only says whether it has
one.

| call | auth | what |
|---|---|---|
| `POST /v1/tick` | yes | one observation of the town → the actions that are ready; with `cases` or `decisions`, a **market tick** for the gateway (below) |
| `POST` / `GET /v1/monitors`, `DELETE /v1/monitors/<name>` | yes¹ | register, list, remove a monitor |
| `POST` / `GET /v1/agents`, `DELETE /v1/agents/<name>` | yes¹ | register, list, remove an agent |
| `POST /v1/builtin/<name>/decide` | yes | the gateway's own `rules` and `gemini-seller`, as `decide` endpoints |
| `GET /v1/health` | yes | key, model, budget, counts, each agent's current action |
| `GET /metrics` | yes | counts, spend estimate, p50/p90 latency, fallbacks, who is calling |
| `GET /v1/log?n=20` | yes | the last n decisions: prompt, answer, latency, tokens |
| `POST /v1/reset` | yes | forget every stance |
| `GET /healthz` | **no** | is the process up (the platform's probe); no counts, no secrets |

¹ also the *registration token*, if one is set (`NANDA_REGISTRATION_TOKEN`).

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

## The gateway: NANDA Market's monitor and agent slots

"Like we have the Gemini endpoint, some endpoint for hosted agents." The
contract is in [`../docs/market-design.md`](../docs/market-design.md#the-slot-contract-gateway);
this section is what the gateway does where the contract is silent, so the
Roblox side and the gateway agree. The starter kit for participants is
[`starter/`](starter/README.md).

### One tick

```sh
curl -s -X POST $G/v1/tick -H "Authorization: Bearer $TOKEN" -H "X-Nanda-Server: $JOBID" -d @starter/tick.json
```

```json
{"verdicts": [{"case": "c-17", "verdict": "escalate", "monitor": "rules", "reason": "40% below market: the gray zone"},
              {"case": "c-18", "verdict": "block",    "monitor": "rules", "reason": "58% below market and new"}],
 "actions":  [{"agent": "seller-12", "set_price": 280, "by": "team-b"}],
 "errors":   [{"from": "slowpoke", "error": "timeout (no answer within 800 ms)"}],
 "served_ms": 803}
```

### Decisions the Roblox side must know

1. **Same path, told apart by the body.** `POST /v1/tick` is a market tick
   if the body has a `cases` or a `decisions` key, and the town's tick
   otherwise. The live town never sends either, so it gets exactly what it
   got before. The two share the per-server rate limit (45/min per
   `X-Nanda-Server`); a tick every 2 s is 30.
2. **The answer is always 200** with `verdicts`, `actions`, `errors`,
   `served_ms`, however many monitors failed. `400` only for a body that is
   not a JSON object; `401` / `429` exactly as before.
3. **At most one verdict per case and one action per trader.** Anything
   missing — late, malformed, nobody registered — is for the game's
   built-ins. Never wait for a second answer to the same tick.
4. **Which monitor.** An optional top-level `"monitor": "<name>"` asks that
   monitor only. Without it every registered monitor is asked, outside ones
   in the order they registered, then the built-in `rules`, and for each case
   the first valid verdict in that order wins. So with no outside monitor,
   the gateway's `rules` answers every case — the same four lines as the
   game's own. When the slot is *off*, send no `cases`.
5. **Which agent drives which trader.** An optional `"driver": "<name>"` on a
   decision sends it to that registration. Without it, a decision goes to the
   first registration (same order) whose `roles` include the decision's
   `role`; `gemini-seller` (roles `["seller"]`) is last. Send decisions only
   for traders that are *not* scripted, and set `driver` when the game knows
   who drives them.
6. **Extra fields.** Every action carries `"by": "<registration>"`. A
   verdict's `monitor` is always set by the gateway to the registration's
   name, whatever the monitor wrote, so nobody can sign as `rules`. Unknown
   request fields are passed through to outside code untouched.
7. **`reason` is untrusted text** from outside code: optional, one line, at
   most 120 printable characters. Run it through `TextService` before a
   player sees it, or show only the verdict and the monitor.
8. **The only action is `set_price`**: an integer number of cents, 1 to
   10,000,000, for a trader that registration was sent this tick.
9. **`gemini-seller` answers a tick late.** It never waits for the model: the
   first tick queues a decision and returns nothing, a later one carries the
   stance (`quote_pct` of the market), turned into `set_price` against the
   market price *in that tick*. It drives at most 2 traders at once (a trader
   not sent for 60 s gives its seat back), refreshing each every 12 s, on **its own
   budget** (10 calls/min, 300/h, 1500/day, $0.50/day, $5 total) — separate
   from the town's, so the market can never use up the live seller's calls.
   Worst case for the key is the two ceilings added: $2.50/day.
10. **Time.** 800 ms per outside call, 900 ms for the whole tick, measured
    from when the request arrives. Give `HttpService` 2 s or more, and keep
    one tick in flight per server.
11. **Sizes.** At most 500 cases and 2000 decisions per tick (the rest are
    not sent, and `errors` says so); the request body at most 256 KiB, the
    same cap as before.
12. **`errors`** is a list of `{"from", "error"}`, where `from` is a
    registration's name, `request` (something wrong with the tick itself) or
    `gateway`; at most 50 per tick.

### Registration

`POST /v1/monitors` `{name, url, token}`; `POST /v1/agents` adds
`roles` (e.g. `["seller"]`). The gateway calls `POST {url}/decide` with
`Authorization: Bearer <that token>` — never its own — and `name` is
1–32 letters, digits, `.`, `_`, `-`. Posting a name again replaces it.
`GET` lists them with their stats (calls, ok, timeouts, failures, rejected
items, last latency, last error) and never their tokens; `DELETE
/v1/{monitors,agents}/<name>` removes one. The built-ins are registered at
startup as `{"name": "rules", "url": "builtin:rules"}` and
`{"name": "gemini-seller", "url": "builtin:gemini-seller"}`; the operator can
remove them and register them again under those names.

`NANDA_REGISTRATION_TOKEN`, if set, is a second secret that opens the
registration routes and nothing else (no tick, no health, no model), so
hackathon participants can take a slot without the token the game uses. It
cannot remove a built-in. Anyone holding it can replace or remove anyone
else's registration: this is a hackathon, not a tenancy model.

**Where it lives, and the limits of that.** In memory: a restart or a deploy
forgets every outside registration (the built-ins come back on their own).
`NANDA_GATEWAY_REGISTRY=/path/registry.json` keeps them in a file (mode
0600, since it holds the registrants' tokens); on Railway that only outlives
a deploy on a mounted volume, and this service has none. One process only:
two replicas would each have their own registry.

### What protects it from outside code

- **https only, to public hosts.** The host is resolved, every address must
  be public (no `10.x`, `169.254.x`, `*.railway.internal`, loopback), and the
  socket connects to the address that was checked, so DNS rebinding changes
  nothing. No redirects. `http://localhost` only with `--allow-localhost`
  (`NANDA_GATEWAY_ALLOW_LOCALHOST=1`), which a public bind refuses.
- **Time:** 800 ms per call, 900 ms per tick; one call per registration in
  flight, so a slow host misses ticks instead of piling up threads.
- **Size:** answers over 64 KiB are an error, not a truncated parse.
- **Schema:** every verdict and action is checked; whatever fails is dropped
  and named in `errors`, and the rest of the answer still counts.
- **Rate:** 60 calls a minute per registration; at most 16 monitors and 16
  agents.

| variable | default | what |
|---|---|---|
| `NANDA_GATEWAY` | on | `0` switches the gateway off; market ticks are then town ticks |
| `NANDA_REGISTRATION_TOKEN` | — | the registration-only secret |
| `NANDA_GATEWAY_REGISTRY` | memory | a JSON file for registrations |
| `NANDA_GATEWAY_CALL_MS` / `_TICK_MS` | 800 / 900 | |
| `NANDA_GATEWAY_MAX_BYTES` | 65536 | largest answer from outside code |
| `NANDA_GATEWAY_PER_REG_PER_MINUTE` | 60 | |
| `NANDA_GATEWAY_MAX_PER_MINUTE` / `_HOUR` / `_DAY` | 10 / 300 / 1500 | the gemini-seller's model calls |
| `NANDA_GATEWAY_MAX_USD_PER_DAY` / `_TOTAL` | 0.5 / 5 | |
| `NANDA_GATEWAY_MAX_AGENTS` / `_INTERVAL` | 2 / 12 s | traders it drives; seconds between two calls for one |

The whole story — how it plugs into the game, what it measures, what hosting
it took — is in
[`../roblox/README.md`](../roblox/README.md#model-driven-agents-one-llm-through-an-external-harness).
