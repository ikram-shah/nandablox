"""The one way the gateway talks to outside code: a bounded HTTPS POST.

Outside monitors and agents are code someone else hosts, so every call to them
is treated as hostile:

  * **https only.** `http://localhost` / `http://127.0.0.1` is allowed only
    when the gateway was started with `allow_localhost` (tests, local play).
  * **no private addresses.** The host is resolved once, every address it
    resolves to must be public, and the socket connects to that *pinned*
    address (TLS still checks the certificate against the hostname). So a
    registration cannot point the gateway at Railway's private network, the
    metadata service or itself, and a DNS answer that changes between the
    check and the connect (rebinding) changes nothing.
  * **no redirects** are followed: anything but a 200 is an error.
  * **a hard deadline**: the socket timeout is the time left, and the body is
    read in chunks against the same clock.
  * **a size cap** on the answer (`max_bytes`); a longer one is an error, not
    a truncated parse.
  * **only the registration's own token** is sent. The caller passes it in;
    nothing here knows the gateway's token.
"""

from __future__ import annotations

import http.client
import ipaddress
import json
import socket
import ssl
import time
from urllib.parse import urlsplit

USER_AGENT = "nanda-gateway/1"
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")


class OutboundError(Exception):
    """A short, loggable reason. Never carries a header or a token."""


def check_url(url: str, allow_localhost: bool = False) -> str | None:
    """Why this URL may not be registered, or None if it may. No network."""
    if not isinstance(url, str) or not url or len(url) > 512:
        return "url must be a string of at most 512 characters"
    try:
        u = urlsplit(url)
    except ValueError:
        return "url does not parse"
    if u.username or u.password:
        return "url may not carry credentials; use the token field"
    if u.fragment:
        return "url may not have a fragment"
    host = (u.hostname or "").lower()
    if not host:
        return "url has no host"
    if u.scheme == "http":
        if allow_localhost and host in LOCAL_HOSTS:
            return None
        return "url must be https" + (" (http is allowed for localhost only)" if allow_localhost else "")
    if u.scheme != "https":
        return "url must be https"
    if not allow_localhost:
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            ip = None
        if host in LOCAL_HOSTS or host.endswith(".internal") or host.endswith(".local") or (ip is not None and not ip.is_global):
            return "url must be a public host"
    return None


def _public_addresses(host: str, port: int) -> list[tuple]:
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    out = []
    for family, socktype, proto, _, sockaddr in infos:
        ip = ipaddress.ip_address(sockaddr[0].split("%")[0])
        if not ip.is_global:
            raise OutboundError("host resolves to a private address")
        out.append((family, socktype, proto, sockaddr))
    if not out:
        raise OutboundError("host does not resolve")
    return out


class _PinnedHTTPS(http.client.HTTPSConnection):
    """HTTPS to an address resolved and checked in advance, SNI = hostname."""

    def __init__(self, host, port, addr, timeout, context):
        super().__init__(host, port, timeout=timeout, context=context)
        self._addr = addr

    def connect(self):
        family, socktype, proto, sockaddr = self._addr
        sock = socket.socket(family, socktype, proto)
        sock.settimeout(self.timeout)
        try:
            sock.connect(sockaddr)
            self.sock = self._context.wrap_socket(sock, server_hostname=self.host)
        except BaseException:
            sock.close()
            raise


_CTX = ssl.create_default_context()


def post_json(
    url: str,
    body: dict,
    token: str | None,
    deadline: float,
    max_bytes: int = 64 * 1024,
    allow_localhost: bool = False,
    extra_headers: dict | None = None,
):
    """POST `body` as JSON to `url`; return the parsed JSON answer.

    `deadline` is a time.monotonic() instant. Raises OutboundError with a
    short reason on anything but a 200 with a JSON body under `max_bytes`.
    """
    why = check_url(url, allow_localhost)
    if why:
        raise OutboundError(why)
    u = urlsplit(url)
    host = u.hostname or ""
    path = (u.path or "/").rstrip("/") + "/decide"
    if u.query:
        path += "?" + u.query

    def left() -> float:
        t = deadline - time.monotonic()
        if t <= 0:
            raise OutboundError("timeout")
        return t

    data = json.dumps(body).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
        "Content-Length": str(len(data)),
        **(extra_headers or {}),
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    conn = None
    try:
        if u.scheme == "http":  # localhost only, and only in local mode (check_url)
            conn = http.client.HTTPConnection(host, u.port or 80, timeout=left())
        else:
            port = u.port or 443
            if allow_localhost and host in LOCAL_HOSTS:
                addr = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)[0]
                addr = (addr[0], addr[1], addr[2], addr[4])
            else:
                addr = _public_addresses(host, port)[0]
            conn = _PinnedHTTPS(host, port, addr, timeout=left(), context=_CTX)
        conn.request("POST", path, body=data, headers=headers)
        if conn.sock is not None:
            conn.sock.settimeout(left())
        resp = conn.getresponse()
        if resp.status != 200:
            raise OutboundError(f"http {resp.status}")
        declared = resp.getheader("Content-Length")
        if declared and declared.isdigit() and int(declared) > max_bytes:
            raise OutboundError(f"answer larger than {max_bytes} bytes")
        chunks, n = [], 0
        while True:
            if conn.sock is not None:
                conn.sock.settimeout(left())
            chunk = resp.read1(8192) if hasattr(resp, "read1") else resp.read(8192)
            if not chunk:
                break
            n += len(chunk)
            if n > max_bytes:
                raise OutboundError(f"answer larger than {max_bytes} bytes")
            chunks.append(chunk)
        left()  # an answer that finished after the deadline is still late
        try:
            return json.loads(b"".join(chunks).decode("utf-8"))
        except ValueError:
            raise OutboundError("answer is not JSON") from None
    except OutboundError:
        raise
    except (socket.timeout, TimeoutError):
        raise OutboundError("timeout") from None
    except ssl.SSLError:
        raise OutboundError("tls error") from None
    except socket.gaierror:
        raise OutboundError("host does not resolve") from None
    except (ConnectionError, OSError, http.client.HTTPException) as e:
        raise OutboundError(f"connection failed ({type(e).__name__})") from None
    finally:
        if conn is not None:
            conn.close()
