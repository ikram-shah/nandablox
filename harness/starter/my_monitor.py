import os, sys
from http.server import ThreadingHTTPServer
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import monitor

def judge(case, signatures_on):
    price, market = case.get("price") or 0, case.get("market") or 0
    ratings = case.get("ratings") or 0
    sig, twin = case.get("signature"), case.get("twin")
    vouched, stocked = case.get("vouched"), case.get("stocked")
    if sig == "invalid":
        return "block", "signature fails: impostor or forged"
    if twin and not signatures_on:
        return "escalate", "two stalls, one name, no signatures: human must pick"
    if not market:
        return "escalate", "no market price"
    gap = 1 - price / market
    pct = round(100 * gap)
    if vouched is None:  # old game build without the new fields: v1 rules
        if ratings == 0 and gap >= 0.28:
            return "block", f"{pct}% below, no history"
        if ratings == 0 and gap >= 0.04:
            return "escalate", f"{pct}% below, unvouched"
        return "allow", "near market"
    if ratings == 0 and not vouched:
        if not stocked:
            return "block", f"new, nobody vouches, empty counter ({pct}% below)"
        if gap >= 0.04:
            return "block", f"new, nobody vouches, {pct}% below: counterfeit pattern"
        return "escalate", "new and unvouched at market price: human look"
    if ratings == 0 and gap >= 0.28:
        return "escalate", f"vouched but {pct}% below: possible bought vouch"
    if ratings > 0 and gap >= 0.35:
        return "escalate", f"established seller suddenly {pct}% below"
    return "allow", "vouched or established, price plausible"

monitor.judge = judge
print("ikram-watchtower v2 on http://localhost:8801/decide", flush=True)
ThreadingHTTPServer(("127.0.0.1", 8801), monitor.Handler).serve_forever()
