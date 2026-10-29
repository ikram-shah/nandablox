"""What the harness knows about itself: counts, latencies, who is calling.

Everything here is in memory and bounded; nothing is persisted, and no
request body, prompt, API key or bearer token ever reaches it. `/metrics`
(authenticated) renders `Metrics.snapshot()`; `/healthz` renders three fields
of it and no secrets at all.
"""

from __future__ import annotations

import threading
import time
from collections import deque

SAMPLES = 512  # latency samples kept per series
CALLERS = 32  # distinct servers / IPs reported


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    i = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return s[i]


class Series:
    def __init__(self, n: int = SAMPLES):
        self.values: deque[float] = deque(maxlen=n)
        self.count = 0
        self.total = 0.0
        self.max = 0.0

    def add(self, v: float) -> None:
        self.values.append(v)
        self.count += 1
        self.total += v
        self.max = max(self.max, v)

    def snapshot(self) -> dict:
        vals = list(self.values)
        return {
            "n": self.count,
            "mean_ms": round(self.total / self.count, 1) if self.count else None,
            "p50_ms": round(percentile(vals, 0.50) or 0, 1) if vals else None,
            "p90_ms": round(percentile(vals, 0.90) or 0, 1) if vals else None,
            "max_ms": round(self.max, 1) if self.count else None,
        }


class Caller:
    __slots__ = ("requests", "first", "last", "rejected")

    def __init__(self, t: float):
        self.requests = 0
        self.first = t
        self.last = t
        self.rejected = 0


class Metrics:
    def __init__(self, now=time.time):
        self.now = now
        self.started = now()
        self.lock = threading.Lock()
        self.counters: dict[str, int] = {}
        self.status: dict[str, int] = {}
        self.model = Series()  # how long Gemini took
        self.serve = Series()  # how long the harness took to answer a tick
        self.servers: dict[str, Caller] = {}
        self.ips: dict[str, Caller] = {}

    # ------------------------------------------------------------ counting

    def bump(self, name: str, n: int = 1) -> None:
        with self.lock:
            self.counters[name] = self.counters.get(name, 0) + n

    def request(self, status: int, ip: str | None, server: str | None, rejected: bool = False) -> None:
        with self.lock:
            self.counters["requests"] = self.counters.get("requests", 0) + 1
            k = str(status)
            self.status[k] = self.status.get(k, 0) + 1
            for table, key in ((self.ips, ip), (self.servers, server)):
                if not key:
                    continue
                c = table.get(key)
                if c is None:
                    if len(table) >= CALLERS * 4:  # bounded; oldest caller goes
                        oldest = min(table, key=lambda k2: table[k2].last)
                        table.pop(oldest, None)
                    c = table[key] = Caller(self.now())
                c.requests += 1
                c.last = self.now()
                if rejected:
                    c.rejected += 1

    def model_latency(self, ms: float) -> None:
        with self.lock:
            self.model.add(ms)

    def serve_latency(self, ms: float) -> None:
        with self.lock:
            self.serve.add(ms)

    # ------------------------------------------------------------- reading

    def _callers(self, table: dict[str, Caller]) -> list[dict]:
        now = self.now()
        top = sorted(table.items(), key=lambda kv: kv[1].last, reverse=True)[:CALLERS]
        out = []
        for key, c in top:
            span = max(1e-6, c.last - c.first)
            out.append(
                {
                    "key": key,
                    "requests": c.requests,
                    "rejected": c.rejected,
                    "per_minute": round(c.requests / span * 60, 1) if c.requests > 1 else None,
                    "seen_s_ago": round(now - c.last, 1),
                    "age_s": round(span, 1),
                }
            )
        return out

    def snapshot(self) -> dict:
        with self.lock:
            counters = dict(self.counters)
            status = dict(self.status)
            model = self.model.snapshot()
            serve = self.serve.snapshot()
            ips = self._callers(self.ips)
            servers = self._callers(self.servers)
        return {
            "uptime_s": round(self.now() - self.started, 1),
            "counters": counters,
            "status": status,
            "latency": {"model": model, "serve": serve},
            "callers": {"ips": ips, "roblox_servers": servers},
        }
