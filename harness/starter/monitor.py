#!/usr/bin/env python3
"""A NANDA Market monitor you own: one file, standard library only.

    SLOT_TOKEN=pick-a-long-secret python3 monitor.py          # http://localhost:8801

The gateway POSTs {url}/decide with the open cases; you answer a verdict for
each case you want to decide: allow, block or escalate (send it to a human).
Cases you leave out are decided by the game's built-in rule monitor.

The rule below is deliberately NOT the built-in one. The built-in allows at
85% of market, blocks under 50% when new, and never looks at the signature
or the average rating. This one trusts well-rated sellers, blocks a bad
signature outright, and draws its lines at 80% and 60%. Change `judge` and
see what happens to the meter.
"""

import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("SLOT_TOKEN", "")
NAME = "my-monitor"


def judge(case, signatures_on):
    """One case -> (verdict, reason). Prices are integer cents."""
    price, market = case.get("price") or 0, case.get("market") or 0
    ratings, avg = case.get("ratings") or 0, case.get("rating_avg") or 0
    if case.get("signature") == "invalid":
        return "block", "bad signature"
    if case.get("twin") and not signatures_on:
        return "escalate", "twin stall and no signatures: a human must look"
    if ratings >= 3 and avg >= 4:
        return "allow", "well rated"
    if not market:
        return "escalate", "no market price"
    if price >= 0.80 * market:
        return "allow", "near the market"
    if price < 0.60 * market and ratings == 0:
        return "block", f"{round(100 - 100 * price / market)}% under market, no history"
    return "escalate", "gray zone"


def decide(tick):
    signatures_on = (tick.get("lever") or {}).get("signatures", True)
    verdicts = []
    for case in tick.get("cases", []):
        verdict, reason = judge(case, signatures_on)
        verdicts.append({"case": case["id"], "verdict": verdict, "reason": reason})
        print(f"{case['id']:>8}  {case.get('stall', '?')[:24]:<24} {case.get('price')}c vs {case.get('market')}c  -> {verdict}  ({reason})", flush=True)
    return {"verdicts": verdicts}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path.rstrip("/") != "/decide":
            return self.reply(404, {"error": "POST /decide"})
        offered = (self.headers.get("Authorization") or "")[7:]
        if TOKEN and not hmac.compare_digest(offered, TOKEN):
            return self.reply(401, {"error": "unauthorized"})
        try:
            tick = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            self.reply(200, decide(tick))
        except Exception as e:  # a bad tick should never take the monitor down
            print("error:", e, file=sys.stderr)
            self.reply(400, {"error": "bad request"})

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", 8801))
    if not TOKEN:
        print("warning: SLOT_TOKEN is not set, so anyone can call this monitor", file=sys.stderr)
    print(f"{NAME} on http://localhost:{PORT}/decide", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
