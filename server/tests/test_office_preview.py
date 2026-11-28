"""Tests for Office document lightweight preview and inline HTML media serving."""

from __future__ import annotations

import zipfile
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.config import AgentConfig
from agy_hub.common.office_preview import OfficePreviewError, extract_office_preview_markdown
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import UserPermissionGrant
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import FakeEngineProvider


def _build_minimal_docx(path: Path) -> None:
    document_xml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>项目周报</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>已完成接口联调与预览支持。</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr>
      <w:r><w:t>支持 DOCX 表格解析</w:t></w:r>
    </w:p>
    <w:tbl>
      <w:tr>
        <w:tc><w:p><w:r><w:t>模块</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>状态 | 备注</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Preview</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>OK</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>"""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("word/document.xml", document_xml)


def _build_minimal_xlsx(path: Path) -> None:
    workbook_xml = """<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="机票报价" sheetId="1" r:id="rId1"/>
    <sheet name="空表" sheetId="2" r:id="rId2"/>
  </sheets>
</workbook>"""
    rels_xml = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet2.xml"/>
</Relationships>"""
    shared_xml = """<?xml version="1.0" encoding="UTF-8"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">
  <si><t>航司</t></si>
  <si><t>价格</t></si>
  <si><t>ANA</t></si>
</sst>"""
    sheet1_xml = """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1">
      <c r="A1" t="s"><v>0</v></c>
      <c r="C1" t="s"><v>1</v></c>
    </row>
    <row r="2">
      <c r="A2" t="s"><v>2</v></c>
      <c r="B2" t="b"><v>1</v></c>
      <c r="C2"><v>38500</v></c>
    </row>
  </sheetData>
</worksheet>"""
    sheet2_xml = """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData/>
</worksheet>"""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("xl/workbook.xml", workbook_xml)
        zf.writestr("xl/_rels/workbook.xml.rels", rels_xml)
        zf.writestr("xl/sharedStrings.xml", shared_xml)
        zf.writestr("xl/worksheets/sheet1.xml", sheet1_xml)
        zf.writestr("xl/worksheets/sheet2.xml", sheet2_xml)


def _build_minimal_pptx(path: Path) -> None:
    slide1_xml = """<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld>
    <p:spTree>
      <p:sp><p:txBody><a:p><a:r><a:t>第一页标题</a:t></a:r></a:p></p:txBody></p:sp>
      <p:sp><p:txBody><a:p><a:r><a:t>正文要点 A</a:t></a:r></a:p></p:txBody></p:sp>
    </p:spTree>
  </p:cSld>
</p:sld>"""
    slide2_xml = """<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld>
    <p:spTree>
      <p:sp><p:txBody><a:p><a:r><a:t>第二页总结</a:t></a:r></a:p></p:txBody></p:sp>
    </p:spTree>
  </p:cSld>
</p:sld>"""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("ppt/slides/slide2.xml", slide2_xml)
        zf.writestr("ppt/slides/slide1.xml", slide1_xml)


def test_extract_office_preview_markdown_all_formats(tmp_path: Path) -> None:
    docx_file = tmp_path / "report.docx"
    _build_minimal_docx(docx_file)
    md_docx, trunc_docx = extract_office_preview_markdown(docx_file)
    assert not trunc_docx
    assert "# 项目周报" in md_docx
    assert "- 支持 DOCX 表格解析" in md_docx
    assert r"状态 \| 备注" in md_docx
    assert "| Preview | OK |" in md_docx

    xlsx_file = tmp_path / "prices.xlsx"
    _build_minimal_xlsx(xlsx_file)
    md_xlsx, trunc_xlsx = extract_office_preview_markdown(xlsx_file)
    assert not trunc_xlsx
    assert "## 机票报价" in md_xlsx
    assert "| 航司 |  | 价格 |" in md_xlsx
    assert "| ANA | TRUE | 38500 |" in md_xlsx
    assert "## 空表" in md_xlsx

    pptx_file = tmp_path / "deck.pptx"
    _build_minimal_pptx(pptx_file)
    md_pptx, trunc_pptx = extract_office_preview_markdown(pptx_file)
    assert not trunc_pptx
    assert md_pptx.index("## 第 1 页") < md_pptx.index("## 第 2 页")
    assert "第一页标题" in md_pptx
    assert "第二页总结" in md_pptx


def test_extract_office_preview_error_cases(tmp_path: Path) -> None:
    legacy_doc = tmp_path / "legacy.doc"
    legacy_doc.write_bytes(b"legacy binary")
    with pytest.raises(OfficePreviewError) as exc_info:
        extract_office_preview_markdown(legacy_doc)
    assert exc_info.value.status_code == 415

    corrupt_docx = tmp_path / "corrupt.docx"
    corrupt_docx.write_bytes(b"not a zip archive")
    with pytest.raises(OfficePreviewError) as bad_exc:
        extract_office_preview_markdown(corrupt_docx)
    assert bad_exc.value.status_code == 422


def test_gateway_office_preview_and_inline_html_media(tmp_path: Path) -> None:
    brain_dir = tmp_path / "brain"
    scratch_dir = tmp_path / "scratch"
    brain_dir.mkdir(parents=True)
    scratch_dir.mkdir(parents=True)

    _build_minimal_docx(brain_dir / "summary.docx")
    (brain_dir / "legacy.doc").write_bytes(b"legacy")
    (brain_dir / "demo.html").write_text("<html><body><h1>Preview</h1></body></html>", encoding="utf-8")

    registry = RootRegistry({"brain": brain_dir, "scratch": scratch_dir})
    secret = "test-internal-secret-for-office-preview-123"
    agent_cfg = AgentConfig(platform="windows", internal_secret=secret, data_dir=tmp_path / "agent")
    provider = FakeEngineProvider(agent_cfg, registry, brain_dir, tmp_path / "state.vscdb", scratch_dir)
    agent_app = create_agent_app(agent_cfg, provider=provider, registry=registry)
    transport = httpx.ASGITransport(app=agent_app)
    http_client = httpx.AsyncClient(transport=transport, base_url="http://agent.local")

    db = HubDatabase(tmp_path / "hub.db")
    db.create_user(
        username="viewer",
        password="viewer-password-123",
        display_name="Viewer",
        role="member",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=False, can_delete=False)],
    )
    gw_cfg = GatewayConfig(
        signing_secret="jwt-secret-key-for-testing-only-32bytes",
        internal_secret=secret,
        nodes={"win": NodeConfig(name="Windows PC", base_url="http://agent.local", is_local=False)},
    )
    gw_app = create_gateway_app(gw_cfg, db=db, http_client=http_client, enable_monitor=True)

    with TestClient(gw_app) as client:
        login = client.post(
            "/api/v2/auth/login",
            json={"username": "viewer", "password": "viewer-password-123"},
        )
        hdr = {"Authorization": f"Bearer {login.json()['tokens']['access_token']}"}

        prev = client.get(
            "/api/v2/nodes/win/files/preview",
            params={"root_id": "brain", "path": "summary.docx"},
            headers=hdr,
        )
        assert prev.status_code == 200
        body = prev.json()
        assert body["name"] == "summary.docx"
        assert "# 项目周报" in body["content"]
        assert "| Preview | OK |" in body["content"]

        unsupported = client.get(
            "/api/v2/nodes/win/files/preview",
            params={"root_id": "brain", "path": "legacy.doc"},
            headers=hdr,
        )
        assert unsupported.status_code == 415

        html_media = client.get(
            "/api/v2/nodes/win/media",
            params={"root_id": "brain", "path": "demo.html"},
            headers=hdr,
        )
        assert html_media.status_code == 200
        assert html_media.headers.get("content-type", "").startswith("text/html")
        assert "<h1>Preview</h1>" in html_media.text
