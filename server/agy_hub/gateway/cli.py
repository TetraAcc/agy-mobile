"""Gateway admin CLI for multi-user governance (hub.db)."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from agy_hub.common.schemas import UserPermissionGrant
from agy_hub.gateway.db import HubDatabase


def _parse_grants(raw_nodes: list[str], can_write: bool, can_delete: bool) -> list[UserPermissionGrant]:
    grants: list[UserPermissionGrant] = []
    for item in raw_nodes:
        for part in item.split(","):
            nid = part.strip()
            if nid:
                grants.append(UserPermissionGrant(node_id=nid, can_write=can_write, can_delete=can_delete))
    return grants


def build_user_parser(subparsers: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    p_add = subparsers.add_parser("add", help="Create a new user")
    p_add.add_argument("--db", default="hub.db", help="Path to hub.db")
    p_add.add_argument("--username", required=True)
    p_add.add_argument("--password", required=True)
    p_add.add_argument("--display-name", default="")
    p_add.add_argument("--role", choices=["admin", "member"], default="member")
    p_add.add_argument("--nodes", nargs="*", default=[], help="Allowed node IDs")
    p_add.add_argument("--default-node", default="")
    p_add.add_argument("--readonly", action="store_true", help="Grant read-only node access")
    p_add.add_argument("--allow-delete", action="store_true", help="Allow delete_session on nodes")

    p_list = subparsers.add_parser("list", help="List all users")
    p_list.add_argument("--db", default="hub.db")

    p_pwd = subparsers.add_parser("passwd", help="Reset a user password")
    p_pwd.add_argument("--db", default="hub.db")
    p_pwd.add_argument("--username", required=True)
    p_pwd.add_argument("--password", required=True)

    p_grant = subparsers.add_parser("grant", help="Grant node access to a user")
    p_grant.add_argument("--db", default="hub.db")
    p_grant.add_argument("--username", required=True)
    p_grant.add_argument("--node", required=True)
    p_grant.add_argument("--readonly", action="store_true")
    p_grant.add_argument("--allow-delete", action="store_true")

    p_revoke = subparsers.add_parser("revoke", help="Revoke node access from a user")
    p_revoke.add_argument("--db", default="hub.db")
    p_revoke.add_argument("--username", required=True)
    p_revoke.add_argument("--node", required=True)

    p_disable = subparsers.add_parser("disable", help="Disable a user and revoke sessions")
    p_disable.add_argument("--db", default="hub.db")
    p_disable.add_argument("--username", required=True)

    p_enable = subparsers.add_parser("enable", help="Enable a disabled user")
    p_enable.add_argument("--db", default="hub.db")
    p_enable.add_argument("--username", required=True)

    p_kick = subparsers.add_parser("kick", help="Revoke all active refresh sessions for a user")
    p_kick.add_argument("--db", default="hub.db")
    p_kick.add_argument("--username", required=True)


def run_user_command(args: argparse.Namespace) -> int:
    db = HubDatabase(Path(args.db))
    try:
        cmd = args.user_cmd
        if cmd == "add":
            grants = _parse_grants(args.nodes, can_write=not args.readonly, can_delete=args.allow_delete)
            profile = db.create_user(
                username=args.username,
                password=args.password,
                display_name=args.display_name,
                role=args.role,
                default_node=args.default_node,
                grants=grants,
            )
            print(f"[+] Created user '{profile.username}' (role={profile.role}, nodes={profile.allowed_nodes})")
            return 0

        if cmd == "list":
            users = db.list_users()
            if not users:
                print("(no users)")
                return 0
            for u in users:
                perms = ", ".join(
                    f"{nid}(w={int(g.can_write)},d={int(g.can_delete)})"
                    for nid, g in u.node_permissions.items()
                )
                print(f"{u.id}\t{u.username}\trole={u.role}\tactive={u.is_active}\tdefault={u.default_node}\tnodes=[{perms}]")
            return 0

        if cmd == "passwd":
            ok = db.update_password(args.username, args.password)
            print("[+] Password updated" if ok else "[-] User not found", file=sys.stdout if ok else sys.stderr)
            return 0 if ok else 1

        if cmd == "grant":
            ok = db.grant_node(args.username, args.node, can_write=not args.readonly, can_delete=args.allow_delete)
            print("[+] Permission granted" if ok else "[-] User not found", file=sys.stdout if ok else sys.stderr)
            return 0 if ok else 1

        if cmd == "revoke":
            ok = db.revoke_node(args.username, args.node)
            print("[+] Permission revoked" if ok else "[-] User or grant not found", file=sys.stdout if ok else sys.stderr)
            return 0 if ok else 1

        if cmd == "disable":
            ok = db.set_user_active(args.username, False)
            print("[+] User disabled" if ok else "[-] User not found", file=sys.stdout if ok else sys.stderr)
            return 0 if ok else 1

        if cmd == "enable":
            ok = db.set_user_active(args.username, True)
            print("[+] User enabled" if ok else "[-] User not found", file=sys.stdout if ok else sys.stderr)
            return 0 if ok else 1

        if cmd == "kick":
            cnt = db.revoke_all_user_sessions(args.username)
            print(f"[+] Revoked {cnt} active session(s)")
            return 0

        return 1
    finally:
        db.close()
