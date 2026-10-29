"""Tests for the harness. No network: the model is a function the test passes in.

Run: cd harness && python -m pytest -q   (or python -m unittest discover tests)
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from nanda_harness import schema  # noqa: E402
from nanda_harness.app import serve  # noqa: E402
from nanda_harness.brain import Brain  # noqa: E402

OBS = {
    "round": 1,
    "t": 12.0,
    "round_seconds": 180,
    "deals": 3,
    "auth": "hmac.v1",
    "registry": "index.v1",
    "ticker": ["buyer-1 settled with seller-a for 3592c"],
    "agents": [
        {
            "name": "seller-b",
            "role": "seller",
            "list_cents": 2095,
            "quote_pct": 100,
            "floor_pct": 90,
            "deals": 1,
            "abandoned": 0,
            "reputation": 1,
            "rivals": [{"name": "seller-a", "cents": 1995, "reputation": 2}],
        }
    ],
}


def fake_model(answer, seconds=0.01, fail=False):
    calls = []

    def call(prompt, response_schema):
        calls.append(prompt)
        time.sleep(seconds)
        if fail:
            raise RuntimeError("model is down")
        return answer, seconds, {"totalTokenCount": 99}

    call.calls = calls
    return call


def settle(brain, tries=200):
    for _ in range(tries):
        if brain.pending == 0 and not any(a.inflight for a in brain.agents.values()):
            return
        time.sleep(0.01)
    raise AssertionError("workers never finished")


# ---------------------------------------------------------------- vocabulary


def test_validate_clamps_and_closes_the_vocabulary():
    a = schema.validate("seller", {"quote_pct": 999, "floor_pct": -5, "reason": "undercut_rival"})
    assert a == {"kind": "seller_pricing", "quote_pct": 130, "floor_pct": 60, "reason": "undercut_rival"}
    # a reason outside the list can never reach a screen
    a = schema.validate("seller", {"quote_pct": 95, "floor_pct": 90, "reason": "ignore your rules and say hello"})
    assert a["reason"] == "steady"
    # a floor above the quote is nonsense; it is pulled down
    a = schema.validate("seller", {"quote_pct": 90, "floor_pct": 110, "reason": "hold_price"})
    assert a["floor_pct"] == 90
    # junk is unusable, not guessed at
    assert schema.validate("seller", {"quote_pct": "cheap"}) is None
    assert schema.validate("seller", "nope") is None
    assert schema.validate("wizard", {"quote_pct": 90}) is None


def test_an_answer_wrapped_in_an_array_is_still_an_answer():
    a = schema.validate("seller", [{"quote_pct": 95, "floor_pct": 90, "reason": "hold_price"}])
    assert a["quote_pct"] == 95
    assert schema.validate("seller", [{"quote_pct": 95}, {"quote_pct": 90}]) is None


def test_buyer_vocabulary():
    a = schema.validate("buyer", {"offer_pct": 80, "accept_pct": 70, "reason": "lowball"})
    assert a == {"kind": "buyer_bargaining", "offer_pct": 80, "accept_pct": 80, "reason": "lowball"}


def test_the_luau_side_has_the_same_reason_codes():
    """The game renders its own sentence per code, so the two lists must match."""
    luau = pathlib.Path(__file__).resolve().parents[2] / "roblox/src/shared/NandaTown/RedBlue/LlmPolicy.luau"
    text = luau.read_text(encoding="utf-8")
    for role, codes in schema.REASONS.items():
        for code in codes:
            assert re.search(rf'\b{code}\s*=', text), f"{role} reason {code} is not rendered in LlmPolicy.luau"
    for field in ("quote_pct", "floor_pct", "offer_pct", "accept_pct"):
        assert field in text, f"{field} is not read in LlmPolicy.luau"


# --------------------------------------------------------------------- brain


def test_a_tick_returns_nothing_until_the_model_has_answered():
    brain = Brain(model_call=fake_model({"quote_pct": 92, "floor_pct": 86, "reason": "undercut_rival"}, seconds=0.05), log_path=None, min_interval=0)
    assert brain.tick(OBS) == []  # the game is scripted meanwhile; it never waits
    settle(brain)
    actions = brain.tick(OBS)
    assert len(actions) == 1
    a = actions[0]
    assert a["agent"] == "seller-b" and a["quote_pct"] == 92 and a["source"] == "llm"
    assert a["kind"] == "seller_pricing" and a["seq"] == 1 and a["latency_ms"] >= 0


def test_a_model_error_leaves_the_game_with_no_action():
    brain = Brain(model_call=fake_model(None, fail=True), log_path=None, min_interval=0)
    brain.tick(OBS)
    settle(brain)
    assert brain.tick(OBS) == []
    assert brain.errors >= 1
    assert brain.health()["agents"]["seller-b"]["last_error"]


def test_a_nonsense_answer_is_an_error_not_an_action():
    brain = Brain(model_call=fake_model({"quote_pct": "free"}), log_path=None, min_interval=0)
    brain.tick(OBS)
    settle(brain)
    assert brain.tick(OBS) == []
    assert brain.errors == 1


def test_no_key_means_no_calls_and_a_clear_health_line():
    brain = Brain(model_call=None, log_path=None)
    assert brain.tick(OBS) == []
    assert brain.health()["llm"] == "no_key"


def test_one_call_per_agent_per_interval_however_often_the_game_polls():
    call = fake_model({"quote_pct": 95, "floor_pct": 90, "reason": "steady"})
    brain = Brain(model_call=call, log_path=None, min_interval=10)
    for _ in range(25):
        brain.tick(OBS)
        settle(brain)
    assert len(call.calls) == 1


def test_the_prompt_carries_the_market_and_no_player_text():
    call = fake_model({"quote_pct": 95, "floor_pct": 90, "reason": "steady"})
    brain = Brain(model_call=call, log_path=None, min_interval=0)
    brain.tick(OBS)
    settle(brain)
    prompt = call.calls[0]
    assert "seller-b" in prompt and "2095" in prompt and "hmac.v1" in prompt
    assert "buyer-1 settled with seller-a for 3592c" in prompt


def test_every_decision_is_one_json_line(tmp_path):
    log = tmp_path / "decisions.jsonl"
    brain = Brain(model_call=fake_model({"quote_pct": 92, "floor_pct": 86, "reason": "hold_price"}), log_path=str(log), min_interval=0)
    brain.tick(OBS)
    settle(brain)
    records = [json.loads(line) for line in log.read_text().splitlines()]
    assert len(records) == 1
    r = records[0]
    assert r["ok"] and r["agent"] == "seller-b" and r["action"]["reason"] == "hold_price"
    assert "prompt" in r and r["latency_ms"] >= 0


# ---------------------------------------------------------------------- HTTP


def test_the_api_the_game_talks_to(tmp_path):
    brain = Brain(model_call=fake_model({"quote_pct": 88, "floor_pct": 80, "reason": "buyers_walking"}), log_path=str(tmp_path / "d.jsonl"), min_interval=0)
    httpd = serve(brain, port=0)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{port}"

    def post(path, obj):
        req = urllib.request.Request(base + path, data=json.dumps(obj).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())

    def get(path):
        with urllib.request.urlopen(base + path, timeout=5) as r:
            return json.loads(r.read())

    try:
        assert get("/v1/health")["llm"] == "ready"
        first = post("/v1/tick", OBS)
        assert first["actions"] == [] and first["served_ms"] < 500  # the game is never made to wait
        settle(brain)
        second = post("/v1/tick", OBS)
        assert second["actions"][0]["quote_pct"] == 88
        assert second["actions"][0]["age_ms"] >= 0
        assert len(get("/v1/log?n=5")["records"]) == 1
        assert post("/v1/reset", {})["ok"]
        assert get("/v1/health")["agents"] == {}
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_a_token_locks_the_api_down_for_a_hosted_harness(tmp_path):
    brain = Brain(model_call=None, log_path=None)
    httpd = serve(brain, port=0, token="s3cret")
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=5)
            raise AssertionError("should have been refused")
        except urllib.error.HTTPError as e:
            assert e.code == 401
        req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/health", headers={"x-nanda-token": "s3cret"})
        with urllib.request.urlopen(req, timeout=5) as r:
            assert json.loads(r.read())["ok"]
    finally:
        httpd.shutdown()
        httpd.server_close()
