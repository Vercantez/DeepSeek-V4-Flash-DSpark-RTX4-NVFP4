#!/usr/bin/env python3
"""Small sticky reverse proxy for OpenAI-compatible vLLM backends.

The router keeps requests for the same tenant/session on the same GPU host so
prefix/KV caches stay useful across multi-turn traffic. It can use static
ROUTER_BACKENDS or discover private IPs from an EC2 Auto Scaling Group.
"""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Iterable


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class BackendState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._backends: list[str] = []
        self._healthy: set[str] = set()
        self._rr = 0

    def replace(self, backends: Iterable[str], healthy: Iterable[str]) -> None:
        ordered = sorted(set(backends))
        healthy_set = set(healthy)
        with self._lock:
            self._backends = ordered
            self._healthy = healthy_set

    def snapshot(self) -> tuple[list[str], list[str]]:
        with self._lock:
            return list(self._backends), sorted(self._healthy)

    def choose(self, key: str | None) -> str | None:
        with self._lock:
            candidates = [b for b in self._backends if b in self._healthy]
            if not candidates:
                return None
            if key:
                return max(
                    candidates,
                    key=lambda b: hashlib.sha256(f"{key}\0{b}".encode()).digest(),
                )
            backend = candidates[self._rr % len(candidates)]
            self._rr += 1
            return backend


STATE = BackendState()


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    return int(value) if value else default


BACKEND_PORT = env_int("BACKEND_PORT", 8000)
DISCOVERY_INTERVAL = env_int("DISCOVERY_INTERVAL", 15)
HEALTH_TIMEOUT = env_int("HEALTH_TIMEOUT", 3)
REQUEST_TIMEOUT = env_int("REQUEST_TIMEOUT", 900)
AWS_REGION = os.environ.get("AWS_REGION", "us-east-2")
AWS_ASG_NAME = os.environ.get("AWS_ASG_NAME", "")
ROUTER_API_KEY = os.environ.get("ROUTER_API_KEY", "")


def normalize_backend(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    if "://" not in value:
        value = f"http://{value}"
    parsed = urllib.parse.urlparse(value)
    port = parsed.port or BACKEND_PORT
    return f"{parsed.scheme}://{parsed.hostname}:{port}"


def static_backends() -> list[str]:
    raw = os.environ.get("ROUTER_BACKENDS", "")
    return [b for b in (normalize_backend(v) for v in raw.split(",")) if b]


def discover_asg_backends() -> list[str]:
    if not AWS_ASG_NAME:
        return []

    asg_cmd = [
        "aws",
        "autoscaling",
        "describe-auto-scaling-groups",
        "--region",
        AWS_REGION,
        "--auto-scaling-group-names",
        AWS_ASG_NAME,
        "--query",
        "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId",
        "--output",
        "text",
    ]
    instance_ids = [
        value
        for value in subprocess.check_output(asg_cmd, text=True).split()
        if value and value != "None"
    ]
    if not instance_ids:
        return []

    ec2_cmd = [
        "aws",
        "ec2",
        "describe-instances",
        "--region",
        AWS_REGION,
        "--instance-ids",
        *instance_ids,
        "--query",
        "Reservations[].Instances[?State.Name=='running'].PrivateIpAddress",
        "--output",
        "text",
    ]
    ips = subprocess.check_output(ec2_cmd, text=True).split()
    return [normalize_backend(f"http://{ip}:{BACKEND_PORT}") for ip in ips]


def is_healthy(backend: str) -> bool:
    try:
        with urllib.request.urlopen(
            f"{backend}/v1/models", timeout=HEALTH_TIMEOUT
        ) as response:
            return 200 <= response.status < 300
    except Exception:
        return False


def discovery_loop() -> None:
    while True:
        backends = static_backends()
        try:
            backends.extend(discover_asg_backends())
        except Exception as exc:
            print(f"ASG discovery failed: {exc}", flush=True)

        healthy = [backend for backend in sorted(set(backends)) if is_healthy(backend)]
        STATE.replace(backends, healthy)
        print(
            f"router backends={sorted(set(backends))} healthy={healthy}",
            flush=True,
        )
        time.sleep(DISCOVERY_INTERVAL)


def sticky_key(headers, body: bytes) -> str | None:
    for header in ("x-sticky-key", "x-session-id", "x-conversation-id", "x-user-id"):
        value = headers.get(header)
        if value:
            return value.strip()

    try:
        payload = json.loads(body.decode("utf-8"))
    except Exception:
        payload = {}

    user = payload.get("user")
    if isinstance(user, str) and user:
        return f"user:{user}"

    messages = payload.get("messages")
    if isinstance(messages, list) and messages:
        first = messages[0]
        if isinstance(first, dict):
            content = first.get("content")
            if isinstance(content, str) and content:
                digest = hashlib.sha256(content[:4096].encode()).hexdigest()
                return f"prefix:{digest}"

    auth = headers.get("authorization")
    if auth:
        return f"auth:{hashlib.sha256(auth.encode()).hexdigest()}"
    return None


class RouterHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, indent=2).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            _, healthy = STATE.snapshot()
            self.send_json(200 if healthy else 503, {"healthy": healthy})
            return
        if self.path == "/router/backends":
            backends, healthy = STATE.snapshot()
            self.send_json(200, {"backends": backends, "healthy": healthy})
            return
        self.proxy()

    def do_POST(self) -> None:
        self.proxy()

    def do_OPTIONS(self) -> None:
        self.proxy()

    def proxy(self) -> None:
        if ROUTER_API_KEY:
            expected = f"Bearer {ROUTER_API_KEY}"
            if self.headers.get("authorization") != expected:
                self.send_json(401, {"error": "unauthorized"})
                return

        content_length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(content_length) if content_length else b""
        backend = STATE.choose(sticky_key(self.headers, body))
        if not backend:
            self.send_json(503, {"error": "no healthy GPU backend"})
            return

        parsed = urllib.parse.urlparse(backend)
        conn = http.client.HTTPConnection(
            parsed.hostname, parsed.port or BACKEND_PORT, timeout=REQUEST_TIMEOUT
        )
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "host"
        }
        headers["host"] = parsed.netloc
        headers["x-forwarded-for"] = self.client_address[0]
        headers["x-routed-backend"] = backend

        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            response = conn.getresponse()
            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                if key.lower() not in HOP_BY_HOP_HEADERS:
                    self.send_header(key, value)
            self.send_header("x-routed-backend", backend)
            self.send_header("connection", "close")
            self.end_headers()
            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except BrokenPipeError:
            pass
        except Exception as exc:
            self.send_json(502, {"error": f"backend proxy failed: {exc}"})
        finally:
            conn.close()


def main() -> None:
    host = os.environ.get("ROUTER_HOST", "0.0.0.0")
    port = env_int("ROUTER_PORT", 8080)
    threading.Thread(target=discovery_loop, daemon=True).start()
    server = ThreadingHTTPServer((host, port), RouterHandler)
    print(f"sticky router listening on {host}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
