"""Tests for the hosted harness: auth, budget, rate limits, fallback.

What a public endpoint has to get right, with no network and no model: the
model is a function the test passes in, and the clock for the windows is a
list the test moves by hand.

Run: cd harness && python -m pytest -q
"""

from __future__ import annotations

import io
import json
import os
import pathlib
import sys
import threading
import time
import urllib.error
import urllib.request
from contextlib import redirect_stdout

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from nanda_harness.app import serve  # noqa: E402
from nanda_harness.brain import Brain  # noqa: E402
from nanda_harness.limits import Budget, RateLimiter  # noqa: E402
from nanda_harness.metrics import Metrics, percentile  # noqa: E402

from test_harness import OBS, fake_model, settle  # noqa: E402

TOKEN = "t0ken-not-in-the-repo"
ANSWER = {"quote_pct": 92, "floor_pct": 86, "reason": "undercut_rival"}


class Fixture:
    """A harness on a loopback port, with the knobs a test wants to turn."""

    def __init__(self, brain, **kw):
        self.brain = brain
        kw.setdefault("token", TOKEN)
        self.httpd = serve(brain, port=0, metrics=brain.metrics, **kw)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base(self):
        return f"http://127.0.0.1:{self.port}"

    def call(self, path, body=None, token=TOKEN, ip=None, server=None, headers=None, method=None):
        """Returns (status, parsed-json-or-text)."""
        h = dict(headers or {})
        if token:
            h["Authorization"] = f"Bearer {token}"
        if ip:
            h["X-Forwarded-For"] = ip
        if server:
            h["X-Nanda-Server"] = server
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read()), dict(r.headers)
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw), dict(e.headers)
            except ValueError:
                return e.code, raw.decode("utf-8", "replace"), dict(e.headers)

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def brain_with(answer=ANSWER, **kw):
    kw.setdefault("log_path", os.devnull)
    kw.setdefault("min_interval", 0)
    kw.setdefault("metrics", Metrics())
    return Brain(model_call=fake_model(answer), **kw)


# ----------------------------------------------------------------- the gate


def test_every_endpoint_needs_the_token_and_healthz_does_not():
    f = Fixture(brain_with())
    try:
        for path in ("/v1/health", "/metrics", "/v1/log?n=1"):
            code, body, _ = f.call(path, token=None)
            assert code == 401 and body["error"] == "unauthorized", path
            assert f.call(path)[0] == 200, path
        assert f.call("/v1/tick", OBS, token=None)[0] == 401
        assert f.call("/v1/reset", {}, token=None)[0] == 401
        # a wrong token is no better than none
        assert f.call("/v1/health", token=TOKEN + "x")[0] == 401
        assert f.call("/v1/health", token=TOKEN[:-1])[0] == 401
        # /healthz is the platform's probe: open, and says nothing secret
        code, body, _ = f.call("/healthz", token=None)
        assert code == 200 and body["ok"] and body["llm"] == "ready"
        assert TOKEN not in json.dumps(body)
        assert "agents" not in body and "budget" not in body
    finally:
        f.close()


def test_the_older_header_still_works_and_an_empty_one_does_not():
    f = Fixture(brain_with())
    try:
        assert f.call("/v1/health", token=None, headers={"x-nanda-token": TOKEN})[0] == 200
        assert f.call("/v1/health", token=None, headers={"x-nanda-token": ""})[0] == 401
        assert f.call("/v1/health", token=None, headers={"Authorization": "Bearer "})[0] == 401
        assert f.call("/v1/health", token=None, headers={"Authorization": TOKEN})[0] == 401
    finally:
        f.close()


def test_guessing_the_token_is_throttled_without_throttling_the_game():
    f = Fixture(brain_with(), auth_failures_per_minute=5)
    try:
        for _ in range(5):
            assert f.call("/v1/health", token="guess", ip="9.9.9.9")[0] == 401
        code, body, headers = f.call("/v1/health", token="guess", ip="9.9.9.9")
        assert code == 429 and int(headers["Retry-After"]) >= 1
        # even with the right token, that address is now shut out...
        assert f.call("/v1/health", ip="9.9.9.9")[0] == 429
        # ...and the real game, on its own address, never notices
        for _ in range(10):
            assert f.call("/v1/health", ip="10.0.0.1")[0] == 200
    finally:
        f.close()


# --------------------------------------------------------------- rate limits


def test_one_game_server_cannot_monopolise_the_harness():
    f = Fixture(brain_with(), per_server_per_minute=4, per_ip_per_minute=1000)
    try:
        for _ in range(4):
            assert f.call("/v1/tick", OBS, ip="1.2.3.4", server="JOB-A")[0] == 200
        code, body, headers = f.call("/v1/tick", OBS, ip="1.2.3.4", server="JOB-A")
        assert code == 429 and "game server" in body["error"]
        assert int(headers["Retry-After"]) >= 1
        # a different server on the same address is unaffected
        assert f.call("/v1/tick", OBS, ip="1.2.3.4", server="JOB-B")[0] == 200
    finally:
        f.close()


def test_one_address_cannot_monopolise_the_harness():
    f = Fixture(brain_with(), per_ip_per_minute=3)
    try:
        for _ in range(3):
            assert f.call("/healthz", token=None, ip="5.5.5.5")[0] == 200
        code, _, headers = f.call("/healthz", token=None, ip="5.5.5.5")
        assert code == 429 and int(headers["Retry-After"]) >= 1
        assert f.call("/healthz", token=None, ip="6.6.6.6")[0] == 200
    finally:
        f.close()


def test_a_global_ceiling_holds_whatever_the_addresses_say():
    f = Fixture(brain_with(), global_per_minute=3, per_ip_per_minute=1000)
    try:
        for i in range(3):
            assert f.call("/healthz", token=None, ip=f"7.7.7.{i}")[0] == 200
        assert f.call("/healthz", token=None, ip="7.7.7.9")[0] == 429
    finally:
        f.close()


def test_the_limiter_forgets_in_time_and_bounds_its_key_table():
    clock = [1000.0]
    lim = RateLimiter(2, span=60.0, max_keys=3, now=lambda: clock[0])
    assert lim.allow("a") == (True, 0)
    assert lim.allow("a") == (True, 0)
    ok, retry = lim.allow("a")
    assert not ok and retry == 60
    clock[0] += 61
    assert lim.allow("a") == (True, 0)
    for k in "bcdefg":
        lim.allow(k)
    assert len(lim.windows) <= 3  # a flood of keys cannot eat memory


# -------------------------------------------------------------- the budget


def test_the_budget_stops_calling_the_model_and_the_game_keeps_its_stance():
    call = fake_model(ANSWER)
    budget = Budget(per_minute=2, per_hour=100, per_day=100, usd_per_day=0, usd_total=0)
    brain = Brain(model_call=call, log_path=os.devnull, min_interval=0, budget=budget, metrics=Metrics())
    f = Fixture(brain)
    try:
        for _ in range(2):
            f.call("/v1/tick", OBS)
            settle(brain)
        assert len(call.calls) == 2  # the cap, exactly
        code, body, _ = f.call("/v1/tick", OBS)
        # over budget: still 200, still the stance the model last set, and
        # the game is told why in one word
        assert code == 200 and body["llm"] == "budget" and body["budget"] == "per_minute"
        assert body["actions"][0]["quote_pct"] == 92
        for _ in range(10):
            f.call("/v1/tick", OBS)
            settle(brain)
        assert len(call.calls) == 2  # nothing more was spent
        assert budget.snapshot()["blocked"] >= 10
        assert budget.snapshot()["blocked_by"]["per_minute"] >= 10
    finally:
        f.close()


def test_the_dollar_ceiling_counts_real_tokens_and_then_shuts_the_key_off():
    usage = {"promptTokenCount": 1_000_000, "candidatesTokenCount": 0}

    def call(prompt, schema):
        return ANSWER, 0.01, usage

    call.calls = []
    budget = Budget(per_minute=0, per_hour=0, per_day=0, usd_per_day=0.5, usd_total=0, price_in=0.30, price_out=2.50)
    brain = Brain(model_call=call, log_path=os.devnull, min_interval=0, budget=budget, metrics=Metrics())
    brain.tick(OBS)  # one call: $0.30 of a $0.50 day
    settle(brain)
    assert round(budget.snapshot()["usd"]["day"], 4) == 0.30
    assert budget.check() is None
    brain.tick(OBS)  # $0.60: over
    settle(brain)
    assert budget.check() == "usd_per_day"
    assert brain.llm_state() == "budget"
    # a day's worth of polling after that spends nothing
    before = budget.snapshot()["usd"]["day"]
    for _ in range(20):
        brain.tick(OBS)
        settle(brain)
    assert budget.snapshot()["usd"]["day"] == before


def test_the_budget_windows_expire():
    clock = [500.0]
    budget = Budget(per_minute=1, per_hour=2, per_day=3, usd_per_day=0, usd_total=0, now=lambda: clock[0])
    assert budget.reserve() is None
    assert budget.reserve() == "per_minute"
    clock[0] += 61
    assert budget.reserve() is None
    clock[0] += 61
    assert budget.reserve() == "per_hour"
    clock[0] += 3601
    assert budget.reserve() is None  # three calls today now
    clock[0] += 61  # the minute and the hour are clear; the day is not
    assert budget.reserve() == "per_day"
    clock[0] += 86401
    assert budget.reserve() is None


# ----------------------------------------------------------------- fallback


def test_a_dead_model_never_becomes_a_dead_endpoint():
    brain = Brain(model_call=fake_model(None, fail=True), log_path=os.devnull, min_interval=0, metrics=Metrics())
    f = Fixture(brain)
    try:
        for _ in range(3):
            code, body, _ = f.call("/v1/tick", OBS)
            settle(brain)
            assert code == 200 and body["actions"] == []  # the game is scripted meanwhile
        assert f.call("/healthz", token=None)[1]["ok"]
        m = f.call("/metrics")[1]
        assert m["counters"]["model_errors"] >= 3
        assert m["counters"]["fallbacks"] >= 3
        assert m["fallbacks"] >= 3
    finally:
        f.close()


def test_a_caller_cannot_conjure_up_agents_to_spend_the_key_on():
    call = fake_model(ANSWER)
    brain = Brain(model_call=call, log_path=os.devnull, min_interval=0, max_agents=2, metrics=Metrics())
    flood = dict(OBS)
    flood["agents"] = [dict(OBS["agents"][0], name=f"seller-{i}") for i in range(50)]
    brain.tick(flood)
    settle(brain)
    assert len(call.calls) <= 2 and len(brain.agents) <= 2
    # and an allowlist pins it to the agents the game actually has
    call2 = fake_model(ANSWER)
    pinned = Brain(model_call=call2, log_path=os.devnull, min_interval=0, allow_agents=["seller-b"], metrics=Metrics())
    pinned.tick(flood)
    settle(pinned)
    assert call2.calls == []
    pinned.tick(OBS)
    settle(pinned)
    assert len(call2.calls) == 1


def test_junk_in_the_body_is_a_400_not_a_crash():
    f = Fixture(brain_with())
    try:
        assert f.call("/v1/tick", [1, 2, 3])[0] == 400
        assert f.call("/v1/tick", {"agents": "not a list"})[0] == 200
        assert f.call("/v1/tick", {"agents": [None, 7, {"name": 1}]})[0] == 200
        assert f.call("/v1/nope", {})[0] == 404
        assert f.call("/v1/nope")[0] == 404
    finally:
        f.close()


# ------------------------------------------------------------------ metrics


def test_metrics_say_what_it_cost_how_long_it_took_and_who_called():
    brain = brain_with()
    f = Fixture(brain)
    try:
        for _ in range(3):
            f.call("/v1/tick", OBS, ip="203.0.113.7", server="JOB-X")
            settle(brain)
        m = f.call("/metrics")[1]
        assert m["counters"]["model_calls"] >= 2
        assert m["latency"]["model"]["p50_ms"] is not None
        assert m["latency"]["model"]["p90_ms"] is not None
        assert m["latency"]["serve"]["p90_ms"] is not None
        assert m["budget"]["calls"] >= 2 and "usd" in m["budget"]
        assert m["decisions"] >= 2
        assert any(c["key"] == "203.0.113.7" for c in m["callers"]["ips"])
        assert any(c["key"] == "JOB-X" for c in m["callers"]["roblox_servers"])
        assert m["status"]["200"] >= 3
        assert m["limits"]["roblox_server"]["limit"] > 0
    finally:
        f.close()


def test_percentiles():
    assert percentile([], 0.5) is None
    assert percentile([5], 0.9) == 5
    assert percentile(list(range(1, 101)), 0.5) == 51  # nearest rank
    assert percentile(list(range(1, 101)), 0.9) == 90


# ------------------------------------------------------------------ secrets


def test_no_log_line_and_no_response_ever_carries_the_token_or_the_key():
    key = "AIzaSy-NOT-A-REAL-KEY-0123456789"
    os.environ["GEMINI_API_KEY"] = key
    brain = brain_with()
    out = io.StringIO()
    f = Fixture(brain)
    try:
        with redirect_stdout(out):
            f.call("/v1/tick", OBS, ip="198.51.100.4", server="JOB-Y")
            settle(brain)
            f.call("/v1/health")
            f.call("/metrics")
            f.call("/v1/health", token="guess")  # a 401, whose attempt is logged
            f.call("/healthz", token=None)
            time.sleep(0.2)
        logged = out.getvalue()
        assert "ev\": \"http" in logged or '"ev": "http"' in logged
        assert TOKEN not in logged and key not in logged
        assert "guess" not in logged  # not even the attempt
        bodies = json.dumps([f.call(p)[1] for p in ("/metrics", "/v1/health")])
        assert TOKEN not in bodies and key not in bodies
    finally:
        os.environ.pop("GEMINI_API_KEY", None)
        f.close()


def test_the_readme_and_the_place_carry_no_live_token():
    """Whatever ends up in the repo, it is not the secret itself."""
    root = pathlib.Path(__file__).resolve().parents[2]
    for rel in ("harness/README.md", "roblox/src/shared/NandaTown/RedBlue/Config.luau", "README.md", "roblox/README.md"):
        text = (root / rel).read_text(encoding="utf-8")
        assert "AIzaSy" not in text, rel
        for line in text.splitlines():
            if "NANDA_HARNESS_TOKEN" in line or "LLM_TOKEN" in line:
                assert "=" not in line or "env" in line.lower() or '""' in line or "Secret" in line or "#" in line or "--" in line, line
