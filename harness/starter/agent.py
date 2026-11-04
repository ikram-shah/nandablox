#!/usr/bin/env python3
"""A NANDA Market trader you own: one file, standard library only.

    SLOT_TOKEN=pick-a-long-secret python3 agent.py            # http://localhost:8802

The gateway POSTs {url}/decide with the traders you drive this tick (the
`decisions`); you answer an action for each one you want to move. Today the
only action is `set_price`, in integer cents. Traders you leave out keep the
game's built-in policy.

This seller undercuts when nothing sold, raises the price when stock is
running out and selling, and otherwise drifts toward the market price.
Change `price_for` to write a better one (or a fraud).
"""

import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("SLOT_TOKEN", "")
NAME = "my-agent"


def price_for(d):
    """One trader's decision -> a new price in cents, or None to leave it."""
    price, market = d.get("price") or 0, d.get("market") or 0
    if not market or d.get("stock", 0) <= 0:
        return None
    sold = d.get("sold_last_min") or 0
    if sold == 0:
        new = min(price, market) * 0.95  # nobody buys: undercut
    elif sold >= 3 and d.get("stock", 0) <= 3:
        new = price * 1.05  # selling out: charge more
    else:
        new = (price + market) / 2  # drift toward the market
    new = max(0.6 * market, min(1.4 * market, new))
    return int(round(new))


def decide(tick):
    actions = []
    for d in tick.get("decisions", []):
        p = price_for(d)
        if p is not None and p != d.get("price"):
            actions.append({"agent": d["agent"], "set_price": p})
            print(f"{d['agent']:>12} {d.get('good')}: {d.get('price')}c -> {p}c  (market {d.get('market')}c, sold {d.get('sold_last_min')})", flush=True)
    return {"actions": actions}


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
        except Exception as e:
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
    PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", 8802))
    if not TOKEN:
        print("warning: SLOT_TOKEN is not set, so anyone can call this agent", file=sys.stderr)
    print(f"{NAME} on http://localhost:{PORT}/decide", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
