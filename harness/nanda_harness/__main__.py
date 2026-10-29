"""Run the harness:  python -m nanda_harness  (or harness/run.sh)

Locally that is 127.0.0.1:8790 and nothing else to do. Hosted (Railway, a
container, anything with a public address) it reads its whole configuration
from the environment:

  PORT                     what to bind (the platform sets it); else 8790
  NANDA_HARNESS_HOST       0.0.0.0 to accept from outside; default 127.0.0.1
  NANDA_HARNESS_TOKEN      the shared secret every endpoint but /healthz needs
  GEMINI_API_KEY           the model key
  NANDA_HARNESS_MODEL      default gemini-2.5-flash
  NANDA_MAX_PER_MINUTE/HOUR/DAY, NANDA_MAX_USD_PER_DAY, NANDA_MAX_USD_TOTAL
  NANDA_PER_IP_PER_MINUTE, NANDA_PER_SERVER_PER_MINUTE, NANDA_GLOBAL_PER_MINUTE
  NANDA_HARNESS_AGENTS     comma-separated allowlist of agent names

Neither the API key nor the token is ever printed, logged or put on a command
line; the only thing said about either is whether there is one. Binding
anywhere but loopback without a token is refused.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

from .app import serve
from .brain import Brain, gemini_call
from .limits import Budget, prices_for
from .metrics import Metrics

DEFAULT_LOG = os.path.join(os.environ.get("TMPDIR", "/tmp"), "nanda-harness", "decisions.jsonl")


def load_env_file(path: str) -> None:
    """Fill in environment variables from a KEY=value file; never overrides."""
    p = pathlib.Path(path).expanduser()
    if not p.is_file():
        return
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip().strip('"').strip("'")
        if k and k not in os.environ:
            os.environ[k] = v


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


def _float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return default


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="nanda_harness", description="LLM agent harness for NANDA Town in Roblox")
    ap.add_argument("--host", default=os.environ.get("NANDA_HARNESS_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=_int("PORT", 8790))
    ap.add_argument("--model", default=os.environ.get("NANDA_HARNESS_MODEL", "gemini-2.5-flash"))
    ap.add_argument("--interval", type=float, default=_float("NANDA_INTERVAL", 4.0), help="seconds between two model calls for the same agent")
    ap.add_argument("--timeout", type=float, default=_float("NANDA_TIMEOUT", 20.0), help="seconds before a model call is abandoned")
    ap.add_argument("--log", default=os.environ.get("NANDA_HARNESS_LOG", DEFAULT_LOG), help="JSON-lines log of every prompt and decision ('-' for stdout)")
    ap.add_argument("--env-file", default=os.environ.get("NANDA_HARNESS_ENV", "~/.env"))
    ap.add_argument("--token", default=os.environ.get("NANDA_HARNESS_TOKEN"), help="the shared secret (Authorization: Bearer …)")
    ap.add_argument("--no-llm", action="store_true", help="serve the API but never call a model (tests the fallback)")
    ap.add_argument("--insecure", action="store_true", help="allow a public bind with no token (don't)")

    b = ap.add_argument_group("budget: the ceiling on model calls")
    b.add_argument("--max-per-minute", type=int, default=_int("NANDA_MAX_PER_MINUTE", 40))
    b.add_argument("--max-per-hour", type=int, default=_int("NANDA_MAX_PER_HOUR", 1200))
    b.add_argument("--max-per-day", type=int, default=_int("NANDA_MAX_PER_DAY", 6000))
    b.add_argument("--max-usd-per-day", type=float, default=_float("NANDA_MAX_USD_PER_DAY", 2.0))
    b.add_argument("--max-usd-total", type=float, default=_float("NANDA_MAX_USD_TOTAL", 20.0), help="since this process started")
    b.add_argument("--price-in", type=float, default=_float("NANDA_PRICE_IN", 0.0), help="$ per million input tokens (0: the table in limits.py)")
    b.add_argument("--price-out", type=float, default=_float("NANDA_PRICE_OUT", 0.0))

    r = ap.add_argument_group("rate limits: so one caller cannot monopolise it")
    r.add_argument("--per-ip-per-minute", type=int, default=_int("NANDA_PER_IP_PER_MINUTE", 300))
    r.add_argument("--per-server-per-minute", type=int, default=_int("NANDA_PER_SERVER_PER_MINUTE", 45))
    r.add_argument("--global-per-minute", type=int, default=_int("NANDA_GLOBAL_PER_MINUTE", 900))
    r.add_argument("--max-agents", type=int, default=_int("NANDA_MAX_AGENTS", 8))
    r.add_argument("--agents", default=os.environ.get("NANDA_HARNESS_AGENTS", ""), help="comma-separated allowlist of agent names (default: any)")
    r.add_argument("--no-trust-proxy", action="store_true", help="take the peer address, not X-Forwarded-For")
    r.add_argument("--log-health", action="store_true", help="log /healthz too (the platform probes it often)")
    args = ap.parse_args(argv)

    load_env_file(args.env_file)
    token = args.token or os.environ.get("NANDA_HARNESS_TOKEN") or None
    public = args.host not in ("127.0.0.1", "localhost", "::1")
    if public and not token and not args.insecure:
        print(
            "refusing to listen on %s with no NANDA_HARNESS_TOKEN: anyone who found the\n"
            "URL could spend the model key. Set one (--token / NANDA_HARNESS_TOKEN),\n"
            "or pass --insecure if this really is a closed network." % args.host,
            file=sys.stderr,
        )
        return 2

    key = os.environ.get("GEMINI_API_KEY") or ""
    call = None
    if args.no_llm:
        why = "--no-llm: the game will stay on its scripted policy"
    elif key:
        call = gemini_call(args.model, key, timeout=args.timeout)
        why = f"key found ({len(key)} chars, not shown)"
    else:
        why = f"no GEMINI_API_KEY in the environment or {args.env_file}; the game will stay on its scripted policy"

    pin, pout = prices_for(args.model)
    budget = Budget(
        per_minute=args.max_per_minute,
        per_hour=args.max_per_hour,
        per_day=args.max_per_day,
        usd_per_day=args.max_usd_per_day,
        usd_total=args.max_usd_total,
        price_in=args.price_in or pin,
        price_out=args.price_out or pout,
    )
    metrics = Metrics()
    log_path = None if args.log == "-" else args.log
    brain = Brain(
        model_call=call,
        model_name=args.model,
        log_path=log_path,
        min_interval=args.interval,
        budget=budget,
        metrics=metrics,
        max_agents=args.max_agents,
        allow_agents=[a.strip() for a in args.agents.split(",") if a.strip()] or None,
    )
    httpd = serve(
        brain,
        host=args.host,
        port=args.port,
        token=token,
        metrics=metrics,
        per_ip_per_minute=args.per_ip_per_minute,
        per_server_per_minute=args.per_server_per_minute,
        global_per_minute=args.global_per_minute,
        trust_proxy=not args.no_trust_proxy,
        log_health=args.log_health,
    )
    print(f"nanda-harness on http://{args.host}:{args.port}  model={args.model}  {why}")
    print(f"auth: {'a token is required on every call but /healthz' if token else 'OPEN (no token set)'}")
    print(
        "budget: %d/min, %d/hour, %d/day, $%.2f/day, $%.2f total; rate: %d/min per IP, %d/min per game server"
        % (
            args.max_per_minute,
            args.max_per_hour,
            args.max_per_day,
            args.max_usd_per_day,
            args.max_usd_total,
            args.per_ip_per_minute,
            args.per_server_per_minute,
        )
    )
    print(f"decisions -> {log_path or 'stdout'}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
