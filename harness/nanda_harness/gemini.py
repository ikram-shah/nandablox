"""The smallest possible Gemini client: one REST call, standard library only.

The key comes from the environment (GEMINI_API_KEY, normally out of the
operator's ~/.env). It is sent in the x-goog-api-key header, never in a URL, a
log line or an error message.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"


class GeminiError(RuntimeError):
    pass


class Gemini:
    def __init__(self, api_key: str, model: str = "gemini-2.5-flash", timeout: float = 20.0, thinking: int = 0):
        self.api_key = api_key
        self.model = model
        self.timeout = timeout
        self.thinking = thinking

    def json_call(self, prompt: str, schema: dict, temperature: float = 0.4) -> tuple[dict, float, dict]:
        """Ask for one JSON object matching `schema`.

        Returns (parsed, seconds, usage). Raises GeminiError on anything else.
        """
        body = {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseSchema": schema,
                "temperature": temperature,
                "maxOutputTokens": 2048,
            },
        }
        if self.thinking is not None and "flash" in self.model:
            # an in-game agent wants an answer in about a second, not a plan.
            # Only the flash models accept a zero budget; the pro models
            # answer 400 to it, so they are left to think as they like (and
            # take ~7-12 s, which the game hides anyway).
            body["generationConfig"]["thinkingConfig"] = {"thinkingBudget": self.thinking}
        req = urllib.request.Request(
            ENDPOINT.format(model=self.model),
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json", "x-goog-api-key": self.api_key},
            method="POST",
        )
        t0 = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                payload = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:  # never echo the request headers
            raise GeminiError(f"HTTP {e.code} from {self.model}") from None
        except Exception as e:
            raise GeminiError(f"{type(e).__name__} calling {self.model}") from None
        seconds = time.monotonic() - t0
        try:
            text = payload["candidates"][0]["content"]["parts"][0]["text"]
            parsed = json.loads(text)
        except Exception:
            raise GeminiError(f"no JSON answer from {self.model}") from None
        return parsed, seconds, payload.get("usageMetadata", {})
