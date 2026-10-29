"""The fixed vocabulary the model may answer in, and its validation.

Nothing the model writes is ever shown to a player. It picks numbers inside a
fixed range and one `reason` code out of a closed list; the game renders its own
English from the code (roblox/src/shared/NandaTown/RedBlue/LlmPolicy.luau has the
same list and the sentences). That is why no text filter is needed: there is no
free text on either side of the wire.

Keep REASONS in step with LlmPolicy.REASONS on the Luau side; test_harness.py
checks that the two lists match by reading the Luau file.
"""

from __future__ import annotations

from typing import Any

# reason codes, per role. The Luau side renders one sentence per code.
SELLER_REASONS = [
    "undercut_rival",
    "hold_price",
    "rebuild_trust",
    "buyers_walking",
    "slow_lane",
    "impostor_nearby",
    "steady",
]
BUYER_REASONS = [
    "lowball",
    "close_fast",
    "trust_favourite",
    "avoid_impostor",
    "budget_tight",
    "steady",
]
REASONS = {"seller": SELLER_REASONS, "buyer": BUYER_REASONS}

# every number the model may move, with the range the game clamps it to
RANGES = {
    "seller": {
        # percent of this seller's list price
        "quote_pct": (70, 130),
        # the lowest percent of list it will accept when it counters
        "floor_pct": (60, 120),
    },
    "buyer": {
        # percent of the seller's quote this buyer opens at
        "offer_pct": (50, 100),
        # the most, as a percent of the quote, it will pay when it accepts
        "accept_pct": (60, 120),
    },
}

KIND = {"seller": "seller_pricing", "buyer": "buyer_bargaining"}


def response_schema(role: str) -> dict:
    """The JSON schema handed to Gemini (responseSchema), so it can only
    answer inside the vocabulary."""
    props: dict[str, Any] = {}
    for field, (lo, hi) in RANGES[role].items():
        props[field] = {
            "type": "integer",
            "description": f"an integer from {lo} to {hi}",
        }
    props["reason"] = {"type": "string", "enum": list(REASONS[role])}
    return {
        "type": "object",
        "properties": props,
        "required": list(props),
        "propertyOrdering": list(props),
    }


def _clamp(v: Any, lo: int, hi: int, default: int) -> int:
    try:
        n = int(round(float(v)))
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


def validate(role: str, raw: Any) -> dict | None:
    """Coerce a model answer into an action, or None if it is unusable.

    Out-of-range numbers are clamped rather than rejected: a model that says
    "quote at 400% of list" still means "as high as I may go". A reason code
    outside the vocabulary becomes `steady`, so nothing the model writes can
    reach a screen.
    """
    if isinstance(raw, list) and len(raw) == 1:
        # structured output sometimes arrives wrapped in a one-element array
        raw = raw[0]
    if role not in RANGES or not isinstance(raw, dict):
        return None
    action: dict[str, Any] = {"kind": KIND[role]}
    for field, (lo, hi) in RANGES[role].items():
        if field not in raw:
            return None
        action[field] = _clamp(raw[field], lo, hi, default=100)
    reason = raw.get("reason")
    action["reason"] = reason if reason in REASONS[role] else "steady"
    if role == "seller" and action["floor_pct"] > action["quote_pct"]:
        action["floor_pct"] = action["quote_pct"]
    if role == "buyer" and action["accept_pct"] < action["offer_pct"]:
        action["accept_pct"] = action["offer_pct"]
    return action
