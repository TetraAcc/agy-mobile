"""Tool approval detection and LanguageServer interaction payload mapping."""

from __future__ import annotations

import json
from typing import Any

from agy_hub.common.schemas import ApprovalDecisionRequest, ToolApprovalItem

SCOPE_TO_PROTO: dict[str, str] = {
    "once": "PERMISSION_SCOPE_ONCE",
    "conversation": "PERMISSION_SCOPE_CONVERSATION",
    "workspace": "PERMISSION_SCOPE_WORKSPACE",
    "global": "PERMISSION_SCOPE_GLOBAL",
    "project": "PERMISSION_SCOPE_PROJECT",
}
PROTO_TO_SCOPE: dict[str, str] = {v: k for k, v in SCOPE_TO_PROTO.items()}
_SCOPE_ORDER = ("once", "conversation", "workspace", "project", "global")

# RequestedInteraction oneof fields that represent tool/action approvals.
# askQuestion and elicitation are intentionally excluded so dedicated question UI stays independent.
_APPROVAL_FIELD_META: dict[str, tuple[str, str, str, str]] = {
    # raw_field: (interaction_kind, category, title, default_action_label)
    "permission": ("permission", "other", "工具权限审批", "执行受限操作"),
    "filePermission": ("file_permission", "file", "文件访问审批", "访问工作区外或受限路径"),
    "runCommand": ("run_command", "command", "终端命令审批", "运行终端命令"),
    "sendCommandInput": ("send_command_input", "command", "终端输入审批", "向运行中终端发送输入"),
    "mcp": ("mcp", "mcp", "MCP 工具审批", "调用外部 MCP 工具"),
    "readUrlContent": ("read_url_content", "network", "网页读取审批", "读取外部网页内容"),
    "openBrowserUrl": ("browser", "browser", "打开网页审批", "在浏览器中打开网页"),
    "browserAction": ("browser", "browser", "浏览器操作审批", "执行浏览器交互"),
    "executeBrowserJavascript": ("browser", "browser", "网页脚本审批", "在网页执行 JavaScript"),
    "captureBrowserScreenshot": ("browser", "browser", "网页截图审批", "截取浏览器画面"),
    "clickBrowserPixel": ("browser", "browser", "浏览器点击审批", "点击浏览器坐标"),
    "confirmBrowserSetup": ("browser", "browser", "浏览器环境确认", "确认启用浏览器子代理"),
    "openBrowserSetup": ("browser", "browser", "打开浏览器设置", "打开浏览器环境设置"),
    "runExtensionCode": ("approval", "other", "扩展代码审批", "运行扩展代码"),
    "approvalInteraction": ("approval", "approval", "操作确认审批", "确认继续执行"),
    "deploy": ("approval", "other", "部署操作审批", "确认执行部署"),
}

_SIMPLE_CONFIRM_FIELDS = {
    "sendCommandInput",
    "mcp",
    "readUrlContent",
    "openBrowserUrl",
    "browserAction",
    "executeBrowserJavascript",
    "captureBrowserScreenshot",
    "clickBrowserPixel",
    "confirmBrowserSetup",
    "openBrowserSetup",
    "runExtensionCode",
    "approvalInteraction",
}

_BLOCK_REASON_TEXT: dict[str, str] = {
    "BLOCK_REASON_OUTSIDE_WORKSPACE": "目标路径位于当前工作区之外",
    "BLOCK_REASON_GITIGNORED": "目标路径命中 .gitignore 忽略规则",
}

_TRIGGER_SOURCE_TEXT: dict[str, str] = {
    "TYPE_EFFECTIVE_GRANT": "命中权限询问规则",
    "TYPE_DEFAULT_GRANT": "命中默认安全策略",
    "TYPE_CROSS_PROJECT_ISOLATION": "跨项目工作区隔离限制",
    "TYPE_SECURE_MODE": "当前启用了安全审批模式",
    "TYPE_DEFAULT_FALLBACK": "需要手动确认的高风险动作",
    "TYPE_FORCE_ASK_HOOK": "Pre-Tool Hook 强制要求人工审批",
}

_FILE_PERM_SUBSTEP_KEYS = (
    "codeAction",
    "viewFile",
    "listDirectory",
    "grepSearch",
    "viewFileOutline",
    "viewCodeItem",
)


def _format_uri_display(uri_or_path: str) -> str:
    raw = (uri_or_path or "").strip()
    if raw.startswith("file:///"):
        tail = raw[len("file:///") :]
        # Windows drive path e.g. file:///C:/Users/... -> C:/Users/...
        if len(tail) >= 2 and tail[1] == ":":
            return tail
        return "/" + tail
    if raw.startswith("file://"):
        return raw[len("file://") :]
    return raw


def _infer_category_from_action(action: str, step_type: str) -> str:
    low_act = (action or "").strip().lower()
    low_type = (step_type or "").strip().lower()
    if any(k in low_act for k in ("command", "shell", "exec", "terminal")) or any(
        k in low_type for k in ("run_command", "send_command_input", "shell_exec")
    ):
        return "command"
    if any(k in low_act for k in ("file", "read", "write", "edit", "dir", "grep", "find", "path")) or any(
        k in low_type for k in ("code_action", "write_to_file", "view_file", "list_directory", "grep_search", "find")
    ):
        return "file"
    if "mcp" in low_act or "mcp" in low_type:
        return "mcp"
    if "browser" in low_act or "browser" in low_type:
        return "browser"
    if any(k in low_act for k in ("url", "http", "web", "fetch", "network")) or any(
        k in low_type for k in ("read_url", "search_web", "open_browser_url")
    ):
        return "network"
    return "other"


def _parse_allowed_scopes(raw_filter: Any, *, persist_blocked: bool = False) -> list[str]:
    if isinstance(raw_filter, list) and raw_filter:
        mapped: list[str] = []
        for entry in raw_filter:
            key = PROTO_TO_SCOPE.get(str(entry).strip())
            if key and key not in mapped:
                mapped.append(key)
        if mapped:
            ordered = [s for s in _SCOPE_ORDER if s in mapped]
            return ordered or mapped
    if persist_blocked:
        return ["once"]
    return ["once", "conversation", "workspace"]


def _detect_interaction_entry(step: dict[str, Any]) -> tuple[str, dict[str, Any]] | None:
    req = step.get("requestedInteraction")
    if isinstance(req, dict):
        for field in _APPROVAL_FIELD_META:
            val = req.get(field)
            if val is not None:
                return field, val if isinstance(val, dict) else {}
        return None

    for key in _FILE_PERM_SUBSTEP_KEYS:
        sub = step.get(key)
        if isinstance(sub, dict) and isinstance(sub.get("filePermissionRequest"), dict):
            return "filePermission", sub["filePermissionRequest"]
    return None


def _extract_step_context_fields(step: dict[str, Any]) -> tuple[str, str, str, dict[str, Any]]:
    """Extract fallback (target, cwd, shell_name, extra_detail) from step payload."""
    detail: dict[str, Any] = {}
    rc = step.get("runCommand")
    if isinstance(rc, dict):
        target = str(
            rc.get("proposedCommandLine")
            or rc.get("commandLine")
            or rc.get("command")
            or ""
        ).strip()
        args = rc.get("args")
        if not target and rc.get("command"):
            target = " ".join([str(rc["command"]), *(str(a) for a in (args or []))])
        cwd = str(rc.get("cwd") or "").strip()
        shell = str(rc.get("shellName") or "").strip()
        if rc.get("sandboxOverride") is True:
            detail["sandbox_override"] = True
        return target, cwd, shell, detail

    sci = step.get("sendCommandInput")
    if isinstance(sci, dict):
        if sci.get("terminate") is True:
            detail["terminate"] = True
            return "[终止运行中终端命令]", "", "", detail
        txt = str(sci.get("input") or "")
        detail["command_id"] = str(sci.get("commandId") or "")
        return txt, "", "", detail

    mcp = step.get("mcpTool")
    if isinstance(mcp, dict):
        server = str(mcp.get("serverName") or "").strip()
        tc = mcp.get("toolCall") if isinstance(mcp.get("toolCall"), dict) else {}
        tname = str(tc.get("name") or "").strip()
        args_json = str(tc.get("argumentsJson") or "").strip()
        if server:
            detail["server_name"] = server
        if tname:
            detail["tool_name"] = tname
        if args_json:
            detail["arguments_json"] = args_json
        label = f"{server}/{tname}" if server and tname else (tname or server)
        return label, "", "", detail

    ru = step.get("readUrlContent")
    if isinstance(ru, dict):
        return str(ru.get("url") or "").strip(), "", "", detail

    obu = step.get("openBrowserUrl")
    if isinstance(obu, dict):
        return str(obu.get("url") or "").strip(), "", "", detail

    bs = step.get("browserSubagent")
    if isinstance(bs, dict):
        task = str(bs.get("taskName") or bs.get("task") or "").strip()
        return task, "", "", detail

    ej = step.get("executeBrowserJavascript")
    if isinstance(ej, dict):
        code = str(ej.get("javascript") or ej.get("code") or "").strip()
        return code, "", "", detail

    for key in _FILE_PERM_SUBSTEP_KEYS:
        sub = step.get(key)
        if not isinstance(sub, dict):
            continue
        uri = (
            sub.get("absolutePathUri")
            or sub.get("directoryPathUri")
            or sub.get("searchPathUri")
            or sub.get("absoluteUri")
            or (sub.get("actionSpec") or {}).get("targetFile")
            or ""
        )
        if uri:
            return _format_uri_display(str(uri)), "", "", detail

    wt = step.get("writeToFile")
    if isinstance(wt, dict) and wt.get("targetFileUri"):
        return _format_uri_display(str(wt["targetFileUri"])), "", "", detail

    return "", "", "", detail


def _parse_single_waiting_step(
    step: dict[str, Any],
    *,
    session_id: str,
    trajectory_id: str,
    step_index: int,
) -> ToolApprovalItem | None:
    if step.get("status") != "CORTEX_STEP_STATUS_WAITING":
        return None
    detected = _detect_interaction_entry(step)
    if detected is None:
        return None

    raw_field, spec = detected
    step_type = str(step.get("type") or "")
    meta = _APPROVAL_FIELD_META.get(
        raw_field,
        ("approval", "other", "工具操作审批", "确认执行操作"),
    )
    interaction_kind, category, title, default_action = meta

    ctx_target, cwd, shell_name, detail = _extract_step_context_fields(step)
    action_label = default_action
    target = ctx_target
    reason = ""
    allowed_scopes = ["once"]
    suggested_pattern = ""
    editable_command = False

    if raw_field == "permission":
        resource = spec.get("resource") if isinstance(spec.get("resource"), dict) else {}
        res_action = str(resource.get("action") or "").strip()
        res_target = str(resource.get("target") or "").strip()
        category = _infer_category_from_action(res_action, step_type)
        if category == "command":
            title = "终端命令权限审批"
            editable_command = True
        elif category == "file":
            title = "文件操作权限审批"
        elif category == "mcp":
            title = "MCP 工具权限审批"
        elif category == "browser":
            title = "浏览器操作权限审批"
        elif category == "network":
            title = "网络访问权限审批"
        action_label = str(spec.get("actionDescription") or "").strip() or res_action or default_action
        if res_target:
            target = _format_uri_display(res_target) if category == "file" else res_target
        if spec.get("shellName"):
            shell_name = str(spec["shellName"]).strip()
        persist_blocked = str(spec.get("persistSuggestionType") or "") == "PERSIST_SUGGESTION_TYPE_BLOCKED"
        allowed_scopes = _parse_allowed_scopes(
            spec.get("approvalScopeFilter"),
            persist_blocked=persist_blocked,
        )
        suggested_pattern = str(spec.get("suggestedPersistPattern") or "").strip()
        reason = str(spec.get("reason") or "").strip()
        trig = spec.get("triggerSource") if isinstance(spec.get("triggerSource"), dict) else {}
        if not reason and trig:
            trig_desc = _TRIGGER_SOURCE_TEXT.get(str(trig.get("type") or ""), "")
            trig_detail = str(trig.get("detail") or "").strip()
            reason = f"{trig_desc}（{trig_detail}）" if trig_desc and trig_detail else (trig_desc or trig_detail)
        if res_action:
            detail["resource_action"] = res_action
        if res_target:
            detail["resource_target"] = res_target
        if spec.get("onceCoversTask") is True:
            detail["once_covers_task"] = True
        if spec.get("persistMatchesConversation") is True:
            detail["persist_matches_conversation"] = True

    elif raw_field == "filePermission":
        abs_uri = str(spec.get("absolutePathUri") or "").strip()
        if abs_uri:
            target = _format_uri_display(abs_uri)
            detail["absolute_path_uri"] = abs_uri
        is_dir = bool(spec.get("isDirectory"))
        detail["is_directory"] = is_dir
        block_reason = str(spec.get("blockReason") or "").strip()
        if block_reason:
            detail["block_reason"] = block_reason
            reason = _BLOCK_REASON_TEXT.get(block_reason, block_reason)
        action_label = "授权访问目录" if is_dir else "授权访问文件"
        allowed_scopes = ["once", "conversation", "workspace"]

    elif raw_field == "runCommand":
        editable_command = True
        reason = "等待确认在终端执行以下命令"

    elif raw_field == "deploy":
        opts = spec.get("deployTargetOptions")
        if isinstance(opts, list) and opts:
            detail["deploy_target_options"] = opts
            first = opts[0] if isinstance(opts[0], dict) else {}
            target = str(first.get("name") or first.get("id") or json.dumps(first, ensure_ascii=False))

    md = step.get("metadata") if isinstance(step.get("metadata"), dict) else {}
    created_at = str(md.get("createdAt") or "").strip()
    approval_id = f"{trajectory_id or session_id}:{step_index}:{raw_field}"

    return ToolApprovalItem(
        approval_id=approval_id,
        session_id=session_id,
        trajectory_id=trajectory_id,
        step_index=step_index,
        step_type=step_type,
        interaction_kind=interaction_kind,
        raw_interaction_field=raw_field,
        category=category,  # type: ignore[arg-type]
        title=title,
        action_label=action_label,
        target=target,
        cwd=cwd,
        reason=reason,
        shell_name=shell_name,
        can_remember=len([s for s in allowed_scopes if s != "once"]) > 0,
        allowed_scopes=allowed_scopes,
        suggested_persist_pattern=suggested_pattern,
        editable_command=editable_command,
        detail=detail,
        created_at=created_at,
    )


def extract_pending_approvals(
    steps: list[dict[str, Any]],
    *,
    session_id: str,
    trajectory_id: str,
    base_step_offset: int = 0,
) -> list[ToolApprovalItem]:
    """Scan steps (and nested subtrajectories) for CORTEX_STEP_STATUS_WAITING tool approvals."""
    items: list[ToolApprovalItem] = []
    for idx, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        abs_idx = base_step_offset + idx
        parsed = _parse_single_waiting_step(
            step,
            session_id=session_id,
            trajectory_id=trajectory_id,
            step_index=abs_idx,
        )
        if parsed is not None:
            items.append(parsed)

        sub = step.get("subtrajectory")
        if isinstance(sub, dict):
            sub_steps = sub.get("steps")
            sub_tid = str(sub.get("trajectoryId") or trajectory_id).strip()
            if isinstance(sub_steps, list) and sub_steps:
                items.extend(
                    extract_pending_approvals(
                        sub_steps,
                        session_id=session_id,
                        trajectory_id=sub_tid,
                        base_step_offset=0,
                    )
                )
    return items


def build_user_interaction_payload(
    step: dict[str, Any],
    *,
    trajectory_id: str,
    step_index: int,
    decision: ApprovalDecisionRequest,
) -> dict[str, Any]:
    """Build HandleCascadeUserInteractionRequest.interaction payload for a waiting step."""
    if step.get("status") != "CORTEX_STEP_STATUS_WAITING":
        raise ValueError(f"步骤 #{step_index} 当前不处于等待审批状态 ({step.get('status', 'unknown')})")

    detected = _detect_interaction_entry(step)
    if detected is None:
        raise ValueError(f"步骤 #{step_index} 未包含可审批的交互请求")

    raw_field, spec = detected
    expected = (decision.interaction_field or "").strip()
    if expected and expected != raw_field:
        raise ValueError(f"交互类型不匹配：预期 {expected}，实际为 {raw_field}")

    is_allow = decision.decision == "allow"
    payload: dict[str, Any] = {
        "trajectoryId": trajectory_id,
        "stepIndex": int(step_index),
    }

    if raw_field == "permission":
        persist_blocked = str(spec.get("persistSuggestionType") or "") == "PERSIST_SUGGESTION_TYPE_BLOCKED"
        allowed_scopes = _parse_allowed_scopes(
            spec.get("approvalScopeFilter"),
            persist_blocked=persist_blocked,
        )
        if is_allow:
            if decision.scope not in allowed_scopes:
                raise ValueError(f"该操作不支持授权范围 '{decision.scope}'（允许范围：{', '.join(allowed_scopes)}）")
            scope_proto = SCOPE_TO_PROTO[decision.scope]
        else:
            scope_proto = "PERMISSION_SCOPE_ONCE"

        perm_body: dict[str, Any] = {
            "allow": is_allow,
            "scope": scope_proto,
        }
        if not is_allow and decision.deny_reason.strip():
            perm_body["userDenyInstruction"] = decision.deny_reason.strip()
        if is_allow and decision.edited_target is not None and decision.edited_target.strip():
            perm_body["editedTarget"] = decision.edited_target.strip()
        if decision.sandbox_override:
            perm_body["sandboxOverride"] = True
        payload["permission"] = perm_body
        return payload

    if raw_field == "filePermission":
        abs_uri = str(spec.get("absolutePathUri") or "").strip()
        if not abs_uri:
            ctx_target, _, _, _ = _extract_step_context_fields(step)
            abs_uri = ctx_target
        scope_proto = SCOPE_TO_PROTO.get(decision.scope, "PERMISSION_SCOPE_ONCE") if is_allow else "PERMISSION_SCOPE_ONCE"
        payload["filePermission"] = {
            "allow": is_allow,
            "scope": scope_proto,
            "absolutePathUri": abs_uri,
        }
        return payload

    if raw_field == "runCommand":
        rc = step.get("runCommand") if isinstance(step.get("runCommand"), dict) else {}
        proposed = str(rc.get("proposedCommandLine") or rc.get("commandLine") or "").strip()
        submitted = (
            decision.edited_target.strip()
            if (is_allow and decision.edited_target is not None and decision.edited_target.strip())
            else proposed
        )
        payload["runCommand"] = {
            "confirm": is_allow,
            "proposedCommandLine": proposed,
            "submittedCommandLine": submitted,
            "sandboxOverride": bool(decision.sandbox_override),
        }
        return payload

    if raw_field == "deploy":
        opts = spec.get("deployTargetOptions") if isinstance(spec.get("deployTargetOptions"), list) else []
        deploy_body: dict[str, Any] = {"cancel": not is_allow}
        if is_allow and opts and isinstance(opts[0], dict):
            deploy_body["deployTarget"] = opts[0]
        payload["deploy"] = deploy_body
        return payload

    if raw_field in _SIMPLE_CONFIRM_FIELDS:
        payload[raw_field] = {"confirm": is_allow}
        return payload

    raise ValueError(f"暂不支持的交互审批类型: {raw_field}")
