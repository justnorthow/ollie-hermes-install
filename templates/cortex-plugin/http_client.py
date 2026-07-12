import json
import urllib.request
import urllib.error
from urllib.parse import urlencode
from typing import Any


class CortexHttpClient:
    def __init__(self, base_url: str, api_key: str = ""):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key or ""

    def _headers(self, extra: dict | None = None) -> dict:
        headers = dict(extra or {})
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def get(self, path: str, params: dict | None = None) -> Any:
        url = f"{self.base_url}{path}"
        if params:
            url += "?" + urlencode({k: v for k, v in params.items() if v is not None})
        req = urllib.request.Request(url, headers=self._headers(), method="GET")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"GET {path} failed: {e.code}") from e

    def post(self, path: str, body: Any = None) -> Any:
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode() if body is not None else b""
        req = urllib.request.Request(
            url,
            data=data,
            headers=self._headers({"Content-Type": "application/json"}),
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                content = resp.read()
                return json.loads(content) if content else None
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"POST {path} failed: {e.code}") from e

    def patch(self, path: str) -> None:
        url = f"{self.base_url}{path}"
        req = urllib.request.Request(url, data=b"", headers=self._headers(), method="PATCH")
        try:
            with urllib.request.urlopen(req, timeout=10):
                pass
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"PATCH {path} failed: {e.code}") from e

    def put(self, path: str, body: Any) -> None:
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            url,
            data=data,
            headers=self._headers({"Content-Type": "application/json"}),
            method="PUT",
        )
        try:
            with urllib.request.urlopen(req, timeout=10):
                pass
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"PUT {path} failed: {e.code}") from e

    def is_reachable(self) -> bool:
        try:
            self.get("/health")
            return True
        except Exception:
            return False
