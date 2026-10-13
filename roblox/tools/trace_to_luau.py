#!/usr/bin/env python3
"""Convert a NANDA Town run into a Roblox-friendly trace (Luau ModuleScript and/or JSON).

Input can be any of:
  * an ``events.jsonl`` file (one TownEvent per line),
  * a run bundle directory (``events.jsonl`` plus optional ``run.json`` / ``result.json``),
  * a merged JSON object with an ``events`` list (e.g. traces/raw/marketplace.bundle.json).

The output is one table:

  {
    format = "nandatown-trace/roblox-v1",
    run_id, scenario, seed, logical_time,
    layers = { transport = "memory.v1", ... },        -- from run.json when available
    participants = { {name, role, balance_cents, agent_id}, ... },
    events = { {seq, id, at, observer, kind, subject, layer, detail, from?, msg_kind?}, ... },
    messages = { ["m-1"] = {from, to, kind, conversation, sent_seq, deliveries = {seq...}, faults = {...}} },
    result = { verdict, stages = { {name, status, note}, ... } },  -- when result.json available
    layers_touched = { "payments", "transport", ... },
  }

Events are ordered by the numeric part of ``event_id`` (a total order in Lab
runs); ``at`` is kept as-is (logical seconds, rounded to 1e-6). Delivery /
fault events get a ``from`` joined on ``subject`` from the matching
``message_sent``. Nothing scenario-specific is assumed, so the other Lab
scenarios (auction, voting, consensus, supply_chain, spoofing, ...) convert too.

Usage:
  trace_to_luau.py INPUT [--luau OUT.luau] [--json OUT.json] [--run run.json] [--result result.json]
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

FORMAT = "nandatown-trace/roblox-v1"

# Which of the twelve layers (or "town" bookkeeping) each Lab event kind belongs to.
KIND_LAYER = {
    # town bookkeeping
    "run_created": "town",
    "participant_joined": "town",
    "run_finished": "data_facts",
    # transport
    "message_sent": "transport",
    "message_delivered": "transport",
    "message_dropped": "transport",
    "message_duplicated": "transport",
    "message_delayed": "transport",
    "delivery_failed": "transport",
    # communication
    "message_unhandled": "communication",
    "duplicate_recognized": "communication",
    # identity
    "identity_created": "identity",
    # registry
    "card_registered": "registry",
    "card_unverified": "registry",
    "card_publish_refused": "registry",
    "card_withdrawn": "registry",
    "card_withdraw_refused": "registry",
    # auth
    "signature_invalid": "auth",
    "forgery_skipped": "auth",
    # trust
    "receipt_attested": "trust",
    "reputation_updated": "trust",
    "reputation_reweighted": "trust",
    # payments
    "account_opened": "payments",
    "escrow_held": "payments",
    "escrow_released": "payments",
    "escrow_refunded": "payments",
    "payment_settled": "payments",
    "payment_rejected": "payments",
    # coordination (auction, voting, consensus)
    "task_announced": "coordination",
    "bid_placed": "coordination",
    "bid_rejected": "coordination",
    "task_awarded": "coordination",
    "task_unfilled": "coordination",
    "ballot_cast": "coordination",
    "ballot_rejected": "coordination",
    "vote_result": "coordination",
    "proposal_retry": "coordination",
    "consensus_committed": "coordination",
    "value_committed": "coordination",
    # negotiation
    "negotiation_started": "negotiation",
    "offer_made": "negotiation",
    "counter_made": "negotiation",
    "offer_accepted": "negotiation",
    "negotiation_abandoned": "negotiation",
    "buyer_gave_up": "negotiation",
    # memory
    "memory_written": "memory",
    # agent work
    "product_assembled": "agent",
}

DELIVERY_KINDS = {"message_delivered", "message_dropped", "message_duplicated", "message_delayed", "delivery_failed"}


# ---------------------------------------------------------------- loading

def _read_jsonl(path: Path) -> list[dict]:
    out = []
    with path.open() as fh:
        for n, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{n}: bad JSON: {exc}")
    return out


def load(inp: Path, run_path: Path | None, result_path: Path | None) -> tuple[list[dict], dict | None, dict | None, str]:
    run = result = None
    if inp.is_dir():
        events = _read_jsonl(inp / "events.jsonl")
        if (inp / "run.json").exists():
            run = json.loads((inp / "run.json").read_text())
        if (inp / "result.json").exists():
            result = json.loads((inp / "result.json").read_text())
    elif inp.suffix == ".jsonl":
        events = _read_jsonl(inp)
        # a sibling bundle?
        for name, slot in (("run.json", "run"), ("result.json", "result")):
            sib = inp.with_name(name)
            if sib.exists() and inp.name == "events.jsonl":
                if slot == "run":
                    run = json.loads(sib.read_text())
                else:
                    result = json.loads(sib.read_text())
    else:
        merged = json.loads(inp.read_text())
        if isinstance(merged, list):
            events = merged
        else:
            events = merged["events"]
            run = merged.get("run")
            result = merged.get("result")
    # --run / --result accept the bare record or a merged JSON that contains it
    if run_path:
        run = json.loads(run_path.read_text())
        run = run.get("run", run) if "run_id" not in run else run
    if result_path:
        result = json.loads(result_path.read_text())
        result = result.get("result", result) if "stages" not in result else result
    return events, run, result, str(inp)


# ---------------------------------------------------------------- transform

def _ev_num(ev: dict, fallback: int) -> tuple[int, int]:
    m = re.search(r"(\d+)$", str(ev.get("event_id", "")))
    return (int(m.group(1)) if m else 10**9, fallback)


def _clean(v):
    """Round float drift (1.7000000000000002 -> 1.7) recursively."""
    if isinstance(v, float):
        return round(v, 6) if math.isfinite(v) else None
    if isinstance(v, dict):
        return {str(k): _clean(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_clean(x) for x in v]
    return v


def convert(events: list[dict], run: dict | None, result: dict | None, source: str) -> dict:
    events = [e for _, e in sorted(((_ev_num(e, i), e) for i, e in enumerate(events)), key=lambda p: p[0])]
    out_events = []
    messages: dict[str, dict] = {}
    participants: dict[str, dict] = {}
    order: list[str] = []
    meta = {"run_id": None, "scenario": None, "seed": None, "logical_time": None}
    touched: list[str] = []

    def part(name: str) -> dict:
        if name not in participants:
            participants[name] = {"name": name, "role": "agent", "balance_cents": None, "agent_id": None}
            order.append(name)
        return participants[name]

    for seq, ev in enumerate(events, 1):
        kind = ev.get("kind", "?")
        detail = _clean(ev.get("detail") or {})
        subject = ev.get("subject")
        rec = {
            "seq": seq,
            "id": ev.get("event_id", f"ev-{seq}"),
            "at": _clean(float(ev.get("at", 0) or 0)),
            "observer": ev.get("observer"),
            "kind": kind,
            "subject": subject,
            "layer": KIND_LAYER.get(kind, "other"),
            "detail": detail,
        }
        if rec["layer"] not in touched:
            touched.append(rec["layer"])
        meta["run_id"] = meta["run_id"] or ev.get("run_id")

        if kind == "run_created":
            meta["scenario"] = detail.get("scenario")
            meta["seed"] = detail.get("seed")
        elif kind == "run_finished":
            meta["logical_time"] = detail.get("logical_time", rec["at"])
        elif kind == "account_opened" and subject:
            part(subject)["balance_cents"] = detail.get("balance_cents")
        elif kind == "participant_joined" and subject:
            part(subject)["role"] = detail.get("role", "agent")
        elif kind == "identity_created" and subject:
            part(subject)["agent_id"] = detail.get("agent_id")
        elif kind == "message_sent" and subject:
            m = messages.setdefault(subject, {"deliveries": [], "faults": []})
            m.update({"from": ev.get("observer"), "to": detail.get("to"), "kind": detail.get("kind"),
                      "conversation": detail.get("conversation"), "sent_seq": seq})
            rec["msg_kind"] = detail.get("kind")
        elif kind in DELIVERY_KINDS and subject:
            m = messages.setdefault(subject, {"deliveries": [], "faults": []})
            rec["from"] = m.get("from")
            rec["msg_kind"] = detail.get("kind", m.get("kind"))
            if kind == "message_delivered":
                m["deliveries"].append(seq)
            else:
                m["faults"].append({"seq": seq, "kind": kind, "fault": detail.get("fault")})
        out_events.append(rec)

    # participants from run.json fill gaps (and fix order) when present
    if run:
        for p in run.get("participants", []):
            q = part(p["name"])
            if q["role"] == "agent":
                q["role"] = p.get("role", "agent")
        cfg = run.get("config", {})
        meta["seed"] = meta["seed"] if meta["seed"] is not None else cfg.get("seed")
        meta["scenario"] = meta["scenario"] or run.get("profile_name")
        if meta["logical_time"] is None and cfg.get("logical_time") is not None:
            meta["logical_time"] = _clean(float(cfg["logical_time"]))
    if meta["logical_time"] is None and out_events:
        meta["logical_time"] = max(e["at"] for e in out_events)

    trace = {
        "format": FORMAT,
        "source": source,
        **meta,
        "layers": (run or {}).get("config", {}).get("layers", {}),
        "participants": [participants[n] for n in order],
        "events": out_events,
        "messages": messages,
        "layers_touched": touched,
    }
    if result:
        trace["result"] = {
            "verdict": result.get("verdict"),
            "stages": [{"name": s.get("name"), "status": s.get("status"), "note": s.get("note", "")}
                       for s in result.get("stages", [])],
        }
    return trace


# ---------------------------------------------------------------- Luau emitter

_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_LUAU_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
                  "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
                  "continue", "export", "type"}


def _lstr(s: str) -> str:
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif o < 32 or o == 127:
            out.append(f"\\{o:03d}")
        else:
            out.append(ch)  # UTF-8 passes through; Luau strings are byte strings
    out.append('"')
    return "".join(out)


def _key(k: str) -> str:
    return k if _IDENT.match(k) and k not in _LUAU_KEYWORDS else f"[{_lstr(k)}]"


def to_luau(v, indent: int = 0, inline_depth: int = 2) -> str:
    pad = "\t" * indent
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return _lstr(v)
    if isinstance(v, list):
        if not v:
            return "{}"
        items = [to_luau(x, indent + 1) for x in v]
        if all("\n" not in s for s in items) and sum(len(s) for s in items) < 100:
            return "{ " + ", ".join(items) + " }"
        return "{\n" + "".join(f"{pad}\t{s},\n" for s in items) + pad + "}"
    if isinstance(v, dict):
        # Luau tables cannot hold nil values; drop them.
        pairs = [(k, x) for k, x in v.items() if x is not None]
        if not pairs:
            return "{}"
        items = [f"{_key(k)} = {to_luau(x, indent + 1)}" for k, x in pairs]
        if all("\n" not in s for s in items) and sum(len(s) for s in items) < 110:
            return "{ " + ", ".join(items) + " }"
        return "{\n" + "".join(f"{pad}\t{s},\n" for s in items) + pad + "}"
    raise TypeError(f"cannot emit {type(v)}")


def emit_module(trace: dict) -> str:
    head = (
        "--!nocheck\n"
        "-- GENERATED by roblox/tools/trace_to_luau.py from " + trace["source"].replace("\n", " ") + "\n"
        "-- Do not edit by hand; regenerate instead.\n"
        f"-- {trace.get('scenario')} seed={trace.get('seed')} run={trace.get('run_id')} "
        f"events={len(trace['events'])} logical_time={trace.get('logical_time')}\n"
    )
    return head + "return " + to_luau(trace) + "\n"


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("input", type=Path, help="events.jsonl, a bundle dir, or merged JSON")
    ap.add_argument("--luau", type=Path, help="write a ModuleScript source here ('-' for stdout)")
    ap.add_argument("--json", type=Path, help="write the converted trace as JSON here ('-' for stdout)")
    ap.add_argument("--run", type=Path, help="run.json to merge (participants, layers, seed)")
    ap.add_argument("--result", type=Path, help="result.json to merge (verdict and stages)")
    a = ap.parse_args(argv)
    events, run, result, source = load(a.input, a.run, a.result)
    try:
        source = str(a.input.resolve().relative_to(Path.home()))
        source = "~/" + source
    except ValueError:
        pass
    trace = convert(events, run, result, source)
    if not a.luau and not a.json:
        a.luau = Path("-")
    for path, text in ((a.luau, emit_module(trace) if a.luau else None),
                       (a.json, json.dumps(trace, indent=1, ensure_ascii=False) + "\n" if a.json else None)):
        if path is None:
            continue
        if str(path) == "-":
            sys.stdout.write(text)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            print(f"wrote {path} ({len(text):,} bytes, {len(trace['events'])} events, "
                  f"{len(trace['participants'])} participants, layers {trace['layers_touched']})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
