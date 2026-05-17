"""Entrypoint for the Supacode orchestrator sidecar.

Reads --supacode-port from argv, picks its own random port, prints
`SIDECAR_PORT=<port>\\n` to stdout so the parent Swift process can read
it, then runs the aiohttp server until killed.
"""

from __future__ import annotations

import argparse
import asyncio
import sys

from .server import run_server


def main() -> None:
    parser = argparse.ArgumentParser(prog="orchestrator-sidecar")
    parser.add_argument(
        "--supacode-port",
        type=int,
        required=True,
        help="Port where the Supacode Swift bridge HTTP server is listening on 127.0.0.1",
    )
    parser.add_argument(
        "--sidecar-port",
        type=int,
        default=0,
        help="Port to bind the sidecar's HTTP+WS server on (0 = let OS choose).",
    )
    parser.add_argument(
        "--shared-token",
        type=str,
        default="",
        help="Defense-in-depth bearer token required on every cross-process call.",
    )
    args = parser.parse_args()

    try:
        asyncio.run(
            run_server(
                supacode_port=args.supacode_port,
                bind_port=args.sidecar_port,
                shared_token=args.shared_token,
            )
        )
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
