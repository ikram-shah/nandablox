# NANDA Town trace format, as the replay reads it

Read from [projnanda/nandatown](https://github.com/projnanda/nandatown) at commit
[`0931790`](https://github.com/projnanda/nandatown/tree/09317903cd7e33ec2a79b88af447b5403c6d2054) (2026-10-12).
File:line references are to that tree. `roblox/tools/trace_to_luau.py` turns a run into
the Luau module the place plays; `roblox/traces/raw/marketplace.bundle.json` is the run used for the movie.

## Bundle layout

Every run writes `runs/<run_id>/` with five canonical records plus a manifest
(`src/nandatown/bundle.py:33, 79-109`):

| file | content |
|---|---|
| `profile.json` | the recipe; for the Lab, the full scenario (agents with roles and configs, layer per layer, faults, seed), redacted |
| `run.json` | the attempt: `run_id`, participants `[{name, role}]`, releases, `config: {mode, seed, layers, logical_time, rerun_command}` |
| `intents.jsonl` | what agents asked for: `{intent_id, run_id, at, actor, action, payload}`; actions `send, register, lookup, pay, escrow_hold, escrow_release, escrow_refund, attest, announce, bid, award` (`sim/api.py`) |
| `events.jsonl` | what the town recorded (below) |
| `result.json` | the evaluator's verdict: `{run_id, evaluator_version, stages:[{name, status, evidence:[event_id…], note}], verdict, evaluated_at}` |
| `manifest.json` | SHA-256 of each record and a bundle fingerprint |

Side files are `report.md`, `attestation.json` (Ed25519 signature over the
fingerprint and verdict) and, for Track, `state/`.

## The event record

Every event, Lab or Track, is a `TownEvent` (`src/nandatown/records.py:102-111`;
JSON Schema at `schemas/town_event.schema.json`):

```json
{"event_id":"ev-31","run_id":"sim-e6802a896c38","at":1.7000000000000002,
 "observer":"buyer-1","kind":"message_sent","subject":"m-7",
 "detail":{"to":"seller-b","kind":"purchase_order","conversation":"c-4",
           "body":{"nid":"n-1","order_id":"order-buyer-1-1","sku":"widget","quantity":2,"unit_cents":1795}}}
```

- `observer`: who saw it, either an agent name or `"town"` (Track also uses
  `"runner"`). An agent-observed event is that agent acting.
- `subject`: what it is about. Its meaning depends on `kind`: a message id
  (`m-N`), an agent name, an escrow or order ref, a negotiation id (`n-N`), a
  task id, or the run id.
- `detail`: free-form, per kind (table below).
- `event_id`: `ev-1, ev-2, …`, assigned in emission order, so it is a total
  order (`engine.py:56-58`).

## Lab event kinds and fields (all observed in the 11 Lab runs unless marked)

| kind | observer | subject | detail |
|---|---|---|---|
| `run_created` | town | run id | `scenario, seed` |
| `account_opened` | town | agent | `balance_cents` (emitted *before* `run_created`, because accounts open while the engine is built; `sim/runner.py:157`) |
| `participant_joined` | town | agent | `role` |
| `identity_created` | town | agent | `agent_id` |
| `card_registered` / `card_unverified` | town | card name | `capabilities, verified` / `capabilities, publisher` |
| `card_publish_refused` | town | card name | `capabilities, publisher, reason` |
| `signature_invalid` | town | message id or card name | `claimed` |
| `message_sent` | sender | message id | `to, kind, conversation, body` |
| `message_delivered` | town | message id | `to, kind` (no sender: join on `subject` to the `message_sent`) |
| `message_dropped` / `message_duplicated` / `message_delayed` | town | message id | `to, kind, fault` (+`rate` / +`delay`) |
| `negotiation_started` | buyer | `n-N` | `seller, subject` |
| `offer_made` / `counter_made` / `offer_accepted` | buyer / seller / acceptor | `n-N` | `cents` |
| `escrow_held` | town | order/task ref | `from, cents` |
| `escrow_released` | town | ref | `to, cents` |
| `payment_settled` | town | ref or memo | `from, to, cents, via?` |
| `receipt_attested` | rater | rated agent | `record_id, claim, value` |
| `reputation_updated` | rater | rated agent | `outcome, delta, score, receipt` (+ capped fields) |
| `memory_written` | agent | agent | `key` |
| `task_announced` | issuer | task id | `spec, rule` |
| `bid_placed` | bidder | task id | `cents` |
| `bid_rejected` | town | task id | `bidder, cents, reason` |
| `task_awarded` | issuer | task id | `winner, cents, rule, bids` |
| `ballot_cast` / `ballot_rejected` / `vote_result` | ballot box | voter / voter / `"vote"` | `choice` / `reason` / `counts, total` |
| `proposal_retry` / `consensus_committed` / `value_committed` | proposer / proposer / acceptor | — | `missing` / `acks, quorum` / `value` |
| `duplicate_recognized` | buyer | order id | `kind` |
| `product_assembled` | manufacturer | order id | `parts` |
| `message_unhandled` | agent | message id | `kind` |
| `run_finished` | town | run id | `logical_time` |
| in code, not seen in these runs | | | `delivery_failed, payment_rejected, escrow_refunded, task_unfilled, negotiation_abandoned, buyer_gave_up, forgery_skipped, card_withdrawn, card_withdraw_refused, reputation_reweighted` |

Track events share the envelope but use other kinds: `message_accepted`
(`sender, to, kind, content_fingerprint, request_id`), `message_claimed`
(`claimant, attempt, fence`), `claim_expired`, `stale_fence_rejected`,
`ack_recorded` (`status, note, fence, attempt`), `participant_crashed`,
`participant_restarted`, `participant_exited`, `duplicate_offered`,
`ack_dropped`, `notify_suppressed`, `grant_required`, … My
`quote-crash-restart` run produced 17 events in 5.1 s wall.

## Timing model

- **Lab: a discrete-event clock in logical seconds.** One heap queue of
  `(time, seq, callback)` (`engine.py:83-86`); the loop pops until the queue
  is empty or `max_time` passes (`:115-118`). There is no wall clock
  inside a run. Message latency is a constant 0.1 (`transport.py:14`); agents
  schedule their own waits (buyer starts at 0.5, waits 1.0 for quotes, and so
  on). Many events share one `at` (one callback emits several), so **order by
  `event_id`, not `at`**. Times are float sums and show drift such as
  `1.7000000000000002`; round for display.
- Runs are short: marketplace ends at t = 4.3, supply_chain 3.4, auction 6.7,
  consensus 3.5, the spoofing and eviction runs 1.6–1.9 logical seconds. A Roblox replay has to stretch time (for
  example 1 logical s ≈ 3–5 s on screen), or the whole run is a blink.
- **Track: wall-clock Unix seconds** (`at: 1791849697.9`), real
  concurrency, not reproducible.

## Seeds and determinism (verified)

`random.Random(spec.seed)` is the only randomness (`engine.py:27`), and it
feeds only identity keys (`identity.py:23`) and `drop_rate` faults
(`transport.py:29-31`). The reference agents are deterministic. Two
`marketplace --seed 42` runs produced identical `events.jsonl` once the
random `run_id` (`engine.py:26`) is masked; `--seed 7` differed **only** in the
`seed` field of `run_created`, because the scenario has no `drop_rate` rule.
Wall-clock values appear only outside events (`manifest.created_at`,
`attestation.signed_at`, `result.evaluated_at`).

## Export and size

- The bundle already is the export: `events.jsonl` is newline-delimited
  JSON. To get one JSON object, merge the five records (this is what
  `research/nandatown/sample-trace.json` is). `nandatown replay` prints a text
  view; the visualizer HTML embeds `{title, meta, participants, events,
  result}` as JSON (`visualizer.py:223-230`), a third ready-made shape.
- Bundled Lab scenarios: **28–71 events, 5–13 KB `events.jsonl`, 13–26 KB
  per bundle**, 9–36 intents. Marketplace: 65 events, 24 intents, 12.2 KB.
- Generated large runs: about **12 events per agent** for voting and **28
  per agent** for a 2-round marketplace, about 2 KB per agent in
  `events.jsonl` (5,000 voters → 60,007 events, 11 MB; 5,000-agent market →
  140,002 events, 28 MB).
- Sample: `research/nandatown/sample-trace.jsonl` (verbatim) and
  `sample-trace.json` (merged, untrimmed), both from the run in
  `cli-visualize-marketplace.png`. It covers discovery, a 2-step haggle,
  escrow, a duplicated delivery the buyer recognizes, two reputation updates,
  memory reuse in round 2, and a redacted `budget_cents` in the profile.

## Mapping events to a scene (as the replay does it)

| event | could be drawn as |
|---|---|
| `participant_joined` (+ `role`) | spawn an avatar; role picks model/colour |
| `card_registered` / `card_unverified` | a card pinned to the town notice board; unverified = red stamp |
| `message_sent` → `message_delivered` (same `subject`) | a letter/drone flies sender → `to`, landing at the delivered time; label = `detail.kind` |
| `message_dropped` / `_duplicated` / `_delayed` | letter falls and breaks / splits in two / slows |
| `negotiation_*`, `offer_made`, `counter_made`, `offer_accepted` | speech bubbles with the cents |
| `escrow_held` → `escrow_released` + `payment_settled` | coins into a bank vault, later out to the seller |
| `receipt_attested` + `reputation_updated` | a stamped receipt, then stars over the subject (`score`) |
| `task_announced`, `bid_placed`, `bid_rejected`, `task_awarded` | auction podium, paddles, a late paddle bounced |
| `signature_invalid` | a guard rejecting a forged badge |
| `memory_written` | a notebook icon |
| `run_finished` + `result.json` | a scoreboard of stages: passed / failed / inconclusive |
