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
cd harness && python -m pytest -q   # 13 tests, no network
```

`GEMINI_API_KEY` is read from the environment or `~/.env`. It is never
printed, logged or put on a command line; the harness only says whether it has
one.

| call | what |
|---|---|
| `POST /v1/tick` | one observation of the market → the actions that are ready |
| `GET /v1/health` | key, model, counts, each agent's current action |
| `GET /v1/log?n=20` | the last n decisions: prompt, answer, latency, tokens |
| `POST /v1/reset` | forget every stance |

`POST /v1/tick` never blocks on the model: it queues a decision request and
returns what the background workers have already finished. The game applies
whatever is there and carries on; if nothing is, the agent is scripted.

The model may only move numbers inside a range and pick one `reason` code from
a closed list (`nanda_harness/schema.py`); the game writes its own sentences
from the code. Every prompt and decision is one JSON line, by default under
`$TMPDIR/nanda-harness/decisions.jsonl`.

The whole story — how it plugs into the game, what it measures, what a hosted
harness would take — is in
[`../roblox/README.md`](../roblox/README.md#model-driven-agents-one-llm-through-an-external-harness).
