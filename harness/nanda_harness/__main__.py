"""Run the harness:  python -m nanda_harness  (or harness/run.sh)

The API key is read from the environment, or from an env file (~/.env by
default) if it is not already set. It is never printed, logged or put on a
command line; the only thing said about it is whether there is one.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

from .app import serve
from .brain import Brain, gemini_call

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


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="nanda_harness", description="LLM agent harness for NANDA Town in Roblox")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--model", default=os.environ.get("NANDA_HARNESS_MODEL", "gemini-2.5-flash"))
    ap.add_argument("--interval", type=float, default=4.0, help="seconds between two model calls for the same agent")
    ap.add_argument("--timeout", type=float, default=20.0, help="seconds before a model call is abandoned")
    ap.add_argument("--log", default=DEFAULT_LOG, help="JSON-lines log of every prompt and decision")
    ap.add_argument("--env-file", default=os.environ.get("NANDA_HARNESS_ENV", "~/.env"))
    ap.add_argument("--token", default=os.environ.get("NANDA_HARNESS_TOKEN"), help="require this x-nanda-token header")
    ap.add_argument("--no-llm", action="store_true", help="serve the API but never call a model (tests the fallback)")
    args = ap.parse_args(argv)

    load_env_file(args.env_file)
    key = os.environ.get("GEMINI_API_KEY") or ""
    call = None
    if args.no_llm:
        why = "--no-llm: the game will stay on its scripted policy"
    elif key:
        call = gemini_call(args.model, key, timeout=args.timeout)
        why = f"key found ({len(key)} chars, not shown)"
    else:
        why = f"no GEMINI_API_KEY in the environment or {args.env_file}; the game will stay on its scripted policy"

    brain = Brain(model_call=call, model_name=args.model, log_path=args.log, min_interval=args.interval)
    httpd = serve(brain, host=args.host, port=args.port, token=args.token)
    print(f"nanda-harness on http://{args.host}:{args.port}  model={args.model}  {why}")
    print(f"decisions -> {args.log}")
    print("in the game (Studio): press L by the spawn to make seller-b model-driven")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
