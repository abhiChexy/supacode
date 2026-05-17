"""HTTP client used by orchestrator tools to call back into Supacode."""

from __future__ import annotations

from typing import Any

import aiohttp


class SupacodeBridge:
    """Thin async wrapper around aiohttp for calling the Supacode bridge.

    All endpoints live on 127.0.0.1:<port>/commands/<verb> and accept JSON.
    """

    def __init__(self, port: int, shared_token: str = "") -> None:
        self._base = f"http://127.0.0.1:{port}"
        self._headers: dict[str, str] = {}
        if shared_token:
            self._headers["Authorization"] = f"Bearer {shared_token}"
        self._session: aiohttp.ClientSession | None = None

    async def __aenter__(self) -> "SupacodeBridge":
        self._session = aiohttp.ClientSession(headers=self._headers)
        return self

    async def __aexit__(self, *exc: Any) -> None:
        if self._session is not None:
            await self._session.close()
            self._session = None

    async def post(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        assert self._session is not None, "SupacodeBridge used outside async context"
        async with self._session.post(self._base + path, json=body) as resp:
            resp.raise_for_status()
            if resp.status == 204 or resp.content_length == 0:
                return {}
            return await resp.json()
