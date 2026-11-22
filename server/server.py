#!/usr/bin/env python3
"""
AGY 统一服务端启动入口 (Unified Server Entrypoint)
支持无参直接启动（自动检测 Windows / Deck 平台），亦可通过命令行参数或环境变量覆盖。
"""

import sys
import os
import argparse
import logging

from server_core import create_app
from aiohttp import web

def main():
    parser = argparse.ArgumentParser(description="AGY Unified Hub Server")
    parser.add_argument("--platform", choices=["windows", "deck"], default=None, help="运行平台 (默认自动探测)")
    parser.add_argument("--port", type=int, default=None, help="监听端口 (默认由平台配置指定)")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="监听地址 (默认 0.0.0.0)")
    args = parser.parse_args()

    app, port = create_app(platform_name=args.platform, port_override=args.port)
    host = args.host

    print(f"==================================================")
    print(f"  AGY Unified Hub Starting...")
    print(f"  Platform: {args.platform or ('windows' if sys.platform == 'win32' else 'deck')}")
    print(f"  Listen:   http://{host}:{port}")
    print(f"==================================================")

    web.run_app(app, host=host, port=port)

if __name__ == "__main__":
    main()
