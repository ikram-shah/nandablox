"""What keeps a public harness cheap and unmonopolisable.

Three things, all standard library, all thread-safe:

  Window       a sliding count over the last N seconds
  RateLimiter  one window per key (a client IP, a Roblox server's JobId)
  Budget       how many model calls are allowed per minute / hour / day, and
               how many dollars, before the harness stops calling the model

The rule the whole file exists to serve: **a budget or a rate limit may never
fail the game.** Over budget, `/v1/tick` still answers 200 with whatever stance
the agent already had (the Luau side re-stamps a stance it is handed, so the
town keeps trading); over a *rate* limit the caller gets 429, because that one
is abuse, and the game's own backoff handles it. Either way no key is spent.
"""

from __future__ import annotations

import threading
import time
from collections import deque

# Gemini list prices, dollars per million tokens (2026-10). Only used for the
# spend estimate and the dollar ceiling; override with --price-in/--price-out.
PRICES = {
    "gemini-2.5-flash": (0.30, 2.50),
    "gemini-2.5-flash-lite": (0.10, 0.40),
    "gemini-2.5-pro": (1.25, 10.00),
    "gemini-3.5-flash": (0.30, 2.50),
    "gemini-3.1-pro-preview": (1.25, 10.00),
}
DEFAULT_PRICE = (0.30, 2.50)


def prices_for(model: str) -> tuple[float, float]:
    if model in PRICES:
        return PRICES[model]
    for name, p in PRICES.items():  # gemini-2.5-flash-002 and friends
        if model.startswith(name):
            return p
    return DEFAULT_PRICE


class Window:
    """How many events happened in the last `span` seconds."""

    def __init__(self, span: float, now=time.monotonic):
        self.span = span
        self.now = now
        self.events: deque[float] = deque()

    def _trim(self, t: float) -> None:
        span = self.span
        ev = self.events
        while ev and t - ev[0] >= span:
            ev.popleft()

    def count(self) -> int:
        self._trim(self.now())
        return len(self.events)

    def add(self) -> None:
        t = self.now()
        self._trim(t)
        self.events.append(t)

    def retry_after(self) -> float:
        """Seconds until the oldest event falls out of the window."""
        if not self.events:
            return 0.0
        return max(0.0, self.span - (self.now() - self.events[0]))


class RateLimiter:
    """`limit` events per `span` seconds, per key.

    The key table is bounded: a flood of distinct keys evicts the least
    recently seen, so nobody can make the harness eat memory by inventing
    headers.
    """

    def __init__(self, limit: int, span: float = 60.0, max_keys: int = 2048, now=time.monotonic):
        self.limit = limit
        self.span = span
        self.max_keys = max_keys
        self.now = now
        self.lock = threading.Lock()
        self.windows: dict[str, Window] = {}
        self.seen: dict[str, float] = {}
        self.rejected = 0

    def _evict(self) -> None:
        while len(self.windows) > self.max_keys:
            oldest = min(self.seen, key=self.seen.__getitem__)
            self.windows.pop(oldest, None)
            self.seen.pop(oldest, None)

    def allow(self, key: str) -> tuple[bool, int]:
        """Take a slot for `key`. Returns (allowed, retry_after_seconds)."""
        if self.limit <= 0:
            return True, 0
        with self.lock:
            w = self.windows.get(key)
            if w is None:
                w = self.windows[key] = Window(self.span, now=self.now)
            self.seen[key] = self.now()
            self._evict()
            if w.count() >= self.limit:
                self.rejected += 1
                return False, max(1, int(w.retry_after() + 0.5))
            w.add()
            return True, 0

    def peek(self, key: str) -> tuple[bool, int]:
        """Is `key` already over the limit? Records nothing.

        Used for the failed-authentication window, which must count failures
        only: a limiter that charged every well-formed request would throttle
        the game itself.
        """
        if self.limit <= 0:
            return False, 0
        with self.lock:
            w = self.windows.get(key)
            if w is None or w.count() < self.limit:
                return False, 0
            return True, max(1, int(w.retry_after() + 0.5))

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "limit": self.limit,
                "span_s": self.span,
                "keys": len(self.windows),
                "rejected": self.rejected,
                "busiest": max((w.count() for w in self.windows.values()), default=0),
            }


class Budget:
    """The ceiling on model calls: counts per minute/hour/day and dollars.

    `reserve()` is the only way to start a model call. It is atomic: it either
    records the call and returns None, or returns the name of the cap that
    said no. `spend()` adds the real cost once the answer (and its token
    count) is back.

    The dollar ceilings are a rolling 24 hours and a total since the process
    started. A restart forgets the total; that is stated in the README rather
    than papered over, because a container that restarts hourly would
    otherwise look protected and not be.
    """

    def __init__(
        self,
        per_minute: int = 40,
        per_hour: int = 1200,
        per_day: int = 6000,
        usd_per_day: float = 2.0,
        usd_total: float = 20.0,
        price_in: float = DEFAULT_PRICE[0],
        price_out: float = DEFAULT_PRICE[1],
        now=time.monotonic,
    ):
        self.caps = {"minute": per_minute, "hour": per_hour, "day": per_day}
        self.usd_per_day = usd_per_day
        self.usd_total = usd_total
        self.price_in = price_in
        self.price_out = price_out
        self.now = now
        self.lock = threading.Lock()
        self.windows = {
            "minute": Window(60.0, now=now),
            "hour": Window(3600.0, now=now),
            "day": Window(86400.0, now=now),
        }
        self.spend_day: deque[tuple[float, float]] = deque()  # (t, usd)
        self.spent_total = 0.0
        self.calls = 0
        self.blocked = 0
        self.blocked_by: dict[str, int] = {}
        self.tokens_in = 0
        self.tokens_out = 0

    # ------------------------------------------------------------- dollars

    def _spend_day(self) -> float:
        t = self.now()
        while self.spend_day and t - self.spend_day[0][0] >= 86400.0:
            self.spend_day.popleft()
        return sum(usd for _, usd in self.spend_day)

    def cost(self, usage: dict) -> float:
        """Dollars for one call, from Gemini's usageMetadata."""
        if not isinstance(usage, dict):
            return 0.0
        tin = int(usage.get("promptTokenCount") or 0)
        tout = int(usage.get("candidatesTokenCount") or 0)
        tout += int(usage.get("thoughtsTokenCount") or 0)
        if not tin and not tout:
            total = int(usage.get("totalTokenCount") or 0)
            tin, tout = total, 0
        return (tin * self.price_in + tout * self.price_out) / 1_000_000.0

    def spend(self, usage: dict) -> float:
        usd = self.cost(usage)
        with self.lock:
            self._spend_day()
            self.spend_day.append((self.now(), usd))
            self.spent_total += usd
            self.tokens_in += int((usage or {}).get("promptTokenCount") or 0)
            self.tokens_out += int((usage or {}).get("candidatesTokenCount") or 0)
        return usd

    # --------------------------------------------------------------- gating

    def _why_blocked(self) -> str | None:
        for name, w in self.windows.items():
            cap = self.caps[name]
            if cap > 0 and w.count() >= cap:
                return f"per_{name}"
        if self.usd_per_day > 0 and self._spend_day() >= self.usd_per_day:
            return "usd_per_day"
        if self.usd_total > 0 and self.spent_total >= self.usd_total:
            return "usd_total"
        return None

    def check(self) -> str | None:
        """Which cap would refuse a call right now, or None. Records nothing."""
        with self.lock:
            return self._why_blocked()

    def reserve(self) -> str | None:
        """Take a slot for one model call, or say which cap refused."""
        with self.lock:
            why = self._why_blocked()
            if why:
                self.blocked += 1
                self.blocked_by[why] = self.blocked_by.get(why, 0) + 1
                return why
            for w in self.windows.values():
                w.add()
            self.calls += 1
            return None

    def release(self) -> None:
        """Hand a reservation back (the call never happened)."""
        with self.lock:
            for w in self.windows.values():
                if w.events:
                    w.events.pop()
            self.calls = max(0, self.calls - 1)

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "calls": self.calls,
                "blocked": self.blocked,
                "blocked_by": dict(self.blocked_by),
                "state": self._why_blocked() or "ok",
                "used": {name: w.count() for name, w in self.windows.items()},
                "caps": dict(self.caps),
                "usd": {
                    "day": round(self._spend_day(), 6),
                    "total": round(self.spent_total, 6),
                    "cap_day": self.usd_per_day,
                    "cap_total": self.usd_total,
                },
                "tokens": {"in": self.tokens_in, "out": self.tokens_out},
                "price_per_mtok": {"in": self.price_in, "out": self.price_out},
            }
