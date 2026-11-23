#!/usr/bin/env python3
"""AGY Remote Hub v2.0 unified CLI entrypoint."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import uvicorn

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.config import load_agent_config
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.cli import build_user_parser, run_user_command
from agy_hub.gateway.config import load_gateway_config


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="server.py", description="AGY Remote Hub v2.0 CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    p_gw = subparsers.add_parser("gateway", help="Run Edge Gateway server")
    p_gw.add_argument("--config", default="gateway_config.json", help="Path to gateway config JSON")
    p_gw.add_argument("--host", default=None, help="Override bind host")
    p_gw.add_argument("--port", type=int, default=None, help="Override bind port")

    p_ag = subparsers.add_parser("agent", help="Run stateless Node Agent server")
    p_ag.add_argument("--config", default="agent_config.json", help="Path to agent config JSON")
    p_ag.add_argument("--platform", choices=["auto", "windows", "deck"], default=None, help="Override platform")
    p_ag.add_argument("--host", default=None, help="Override bind host")
    p_ag.add_argument("--port", type=int, default=None, help="Override bind port")

    p_user = subparsers.add_parser("user", help="Manage Gateway users and node permissions")
    user_sub = p_user.add_subparsers(dest="user_cmd", required=True)
    build_user_parser(user_sub)

    args = parser.parse_args(argv)
    server_dir = Path(__file__).resolve().parent

    if args.command == "user":
        return run_user_command(args)

    if args.command == "gateway":
        cfg_path = Path(args.config)
        if not cfg_path.is_absolute():
            cfg_path = (server_dir / cfg_path).resolve()
        cfg = load_gateway_config(cfg_path)
        if args.host:
            cfg = cfg.model_copy(update={"host": args.host})
        if args.port:
            cfg = cfg.model_copy(update={"port": args.port})
        app = create_gateway_app(cfg)
        uvicorn.run(app, host=cfg.host, port=cfg.port)
        return 0

    if args.command == "agent":
        cfg_path = Path(args.config)
        if not cfg_path.is_absolute():
            cfg_path = (server_dir / cfg_path).resolve()
        cfg = load_agent_config(cfg_path)
        updates: dict[str, object] = {}
        if args.platform:
            updates["platform"] = args.platform
        if args.host:
            updates["host"] = args.host
        if args.port:
            updates["port"] = args.port
        if updates:
            cfg = cfg.model_copy(update=updates)
        app = create_agent_app(cfg)
        uvicorn.run(app, host=cfg.host, port=cfg.port)
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
