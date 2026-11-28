"""Lightweight pure-stdlib Office document preview extractor (.docx / .xlsx / .pptx -> Markdown)."""

from __future__ import annotations

import posixpath
import re
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

SUPPORTED_OFFICE_EXTENSIONS: frozenset[str] = frozenset({".docx", ".xlsx", ".pptx"})
MAX_OFFICE_FILE_BYTES = 15 * 1024 * 1024  # 15 MB
MAX_PREVIEW_CHARS = 200_000
MAX_XLSX_ROWS = 200
MAX_XLSX_COLS = 30

_WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
_SHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
_REL_ATTR_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
_DRAWING_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
_PPT_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"

_CELL_REF_RE = re.compile(r"^([A-Za-z]+)")
_HEADING_STYLE_RE = re.compile(r"^(?:heading\s*|标题\s*)([1-6])$", re.IGNORECASE)
_SLIDE_MEMBER_RE = re.compile(r"^ppt/slides/slide(\d+)\.xml$", re.IGNORECASE)
_SHEET_MEMBER_RE = re.compile(r"^xl/worksheets/sheet(\d+)\.xml$", re.IGNORECASE)


class OfficePreviewError(Exception):
    """Raised when an Office document cannot be converted to a preview."""

    def __init__(self, message: str, *, status_code: int = 422) -> None:
        super().__init__(message)
        self.status_code = status_code


def _local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def _escape_md_cell(text: str) -> str:
    cleaned = re.sub(r"\s+", " ", text or "").strip()
    return cleaned.replace("|", r"\|")


def _col_letters_to_index(ref: str) -> int | None:
    m = _CELL_REF_RE.match((ref or "").strip())
    if not m:
        return None
    letters = m.group(1).upper()
    idx = 0
    for ch in letters:
        idx = idx * 26 + (ord(ch) - ord("A") + 1)
    return idx - 1


def _parse_xml_member(zf: zipfile.ZipFile, member_name: str) -> ET.Element | None:
    try:
        raw = zf.read(member_name)
    except KeyError:
        return None
    try:
        return ET.fromstring(raw)
    except ET.ParseError as exc:
        raise OfficePreviewError(f"无法解析文档 XML 结构（{member_name}）：{exc}") from exc


def _extract_word_paragraph_text(p_elem: ET.Element) -> str:
    parts: list[str] = []
    for elem in p_elem.iter():
        lname = _local_name(elem.tag)
        if lname == "t" or lname == "delText":
            if elem.text:
                parts.append(elem.text)
        elif lname == "tab":
            parts.append("    ")
        elif lname in ("br", "cr"):
            parts.append(" ")
    return "".join(parts).strip()


def _detect_word_paragraph_prefix(p_elem: ET.Element) -> str:
    ppr = p_elem.find(f"{{{_WORD_NS}}}pPr")
    if ppr is None:
        return ""
    pstyle = ppr.find(f"{{{_WORD_NS}}}pStyle")
    if pstyle is not None:
        val = (pstyle.attrib.get(f"{{{_WORD_NS}}}val") or pstyle.attrib.get("val") or "").strip()
        if val.lower() == "title":
            return "# "
        if val.lower() == "subtitle":
            return "## "
        m = _HEADING_STYLE_RE.match(val)
        if m:
            level = int(m.group(1))
            return "#" * level + " "
    if ppr.find(f"{{{_WORD_NS}}}numPr") is not None:
        return "- "
    return ""


def _extract_docx(zf: zipfile.ZipFile) -> tuple[str, bool]:
    root = _parse_xml_member(zf, "word/document.xml")
    if root is None:
        raise OfficePreviewError("DOCX 文档缺少 word/document.xml 主体内容")

    body = root.find(f"{{{_WORD_NS}}}body")
    if body is None:
        return "", False

    blocks: list[str] = []
    for child in body:
        lname = _local_name(child.tag)
        if lname == "p":
            text = _extract_word_paragraph_text(child)
            if not text:
                continue
            prefix = _detect_word_paragraph_prefix(child)
            blocks.append(f"{prefix}{text}")
        elif lname == "tbl":
            rows_data: list[list[str]] = []
            for tr in child.findall(f"{{{_WORD_NS}}}tr"):
                row_cells: list[str] = []
                for tc in tr.findall(f"{{{_WORD_NS}}}tc"):
                    cell_paras = [
                        _extract_word_paragraph_text(p)
                        for p in tc.findall(f"{{{_WORD_NS}}}p")
                    ]
                    cell_text = " ".join(p for p in cell_paras if p)
                    row_cells.append(_escape_md_cell(cell_text))
                if row_cells:
                    rows_data.append(row_cells)
            if not rows_data:
                continue
            col_count = max(len(r) for r in rows_data)
            if col_count <= 0:
                continue
            normalized = [r + [""] * (col_count - len(r)) for r in rows_data]
            md_lines = [
                "| " + " | ".join(normalized[0]) + " |",
                "| " + " | ".join(["---"] * col_count) + " |",
            ]
            for r in normalized[1:]:
                md_lines.append("| " + " | ".join(r) + " |")
            blocks.append("\n".join(md_lines))

    return "\n\n".join(blocks), False


def _load_xlsx_shared_strings(zf: zipfile.ZipFile) -> list[str]:
    root = _parse_xml_member(zf, "xl/sharedStrings.xml")
    if root is None:
        return []
    strings: list[str] = []
    for si in root.findall(f"{{{_SHEET_NS}}}si"):
        parts: list[str] = []
        for elem in si.iter():
            if _local_name(elem.tag) == "t" and elem.text:
                parts.append(elem.text)
        strings.append("".join(parts))
    return strings


def _resolve_xlsx_sheets(zf: zipfile.ZipFile) -> list[tuple[str, str]]:
    wb_root = _parse_xml_member(zf, "xl/workbook.xml")
    rels_root = _parse_xml_member(zf, "xl/_rels/workbook.xml.rels")
    rel_map: dict[str, str] = {}
    if rels_root is not None:
        for rel in rels_root:
            if _local_name(rel.tag) != "Relationship":
                continue
            rid = rel.attrib.get("Id", "")
            target = rel.attrib.get("Target", "").strip()
            if not rid or not target:
                continue
            if target.startswith("/"):
                member = target.lstrip("/")
            else:
                member = posixpath.normpath(posixpath.join("xl", target))
            rel_map[rid] = member

    sheets: list[tuple[str, str]] = []
    available = set(zf.namelist())
    if wb_root is not None:
        sheets_elem = wb_root.find(f"{{{_SHEET_NS}}}sheets")
        if sheets_elem is not None:
            for s_elem in sheets_elem.findall(f"{{{_SHEET_NS}}}sheet"):
                name = (s_elem.attrib.get("name") or "Sheet").strip() or "Sheet"
                rid = s_elem.attrib.get(f"{{{_REL_ATTR_NS}}}id") or s_elem.attrib.get("r:id") or ""
                member = rel_map.get(rid, "")
                if member and member in available:
                    sheets.append((name, member))

    if sheets:
        return sheets

    fallback: list[tuple[int, str, str]] = []
    for member in available:
        m = _SHEET_MEMBER_RE.match(member)
        if m:
            idx = int(m.group(1))
            fallback.append((idx, f"Sheet{idx}", member))
    fallback.sort(key=lambda item: item[0])
    return [(name, member) for _, name, member in fallback]


def _extract_xlsx_cell_value(cell: ET.Element, shared_strings: list[str]) -> str:
    cell_type = cell.attrib.get("t", "")
    if cell_type == "inlineStr":
        is_elem = cell.find(f"{{{_SHEET_NS}}}is")
        if is_elem is None:
            return ""
        return "".join(
            elem.text
            for elem in is_elem.iter()
            if _local_name(elem.tag) == "t" and elem.text
        )

    v_elem = cell.find(f"{{{_SHEET_NS}}}v")
    if v_elem is None or v_elem.text is None:
        return ""
    raw = v_elem.text
    if cell_type == "s":
        try:
            idx = int(raw)
        except ValueError:
            return raw
        if 0 <= idx < len(shared_strings):
            return shared_strings[idx]
        return raw
    if cell_type == "b":
        return "TRUE" if raw == "1" else "FALSE"
    return raw


def _extract_xlsx(zf: zipfile.ZipFile) -> tuple[str, bool]:
    shared_strings = _load_xlsx_shared_strings(zf)
    sheets = _resolve_xlsx_sheets(zf)
    if not sheets:
        raise OfficePreviewError("XLSX 文档未包含可读的工作表")

    sections: list[str] = []
    truncated = False

    for sheet_name, member in sheets:
        ws_root = _parse_xml_member(zf, member)
        if ws_root is None:
            continue
        sheet_data = ws_root.find(f"{{{_SHEET_NS}}}sheetData")
        if sheet_data is None:
            sections.append(f"## {sheet_name}\n\n> （工作表为空）")
            continue

        row_elems = sheet_data.findall(f"{{{_SHEET_NS}}}row")
        sheet_rows: list[list[str]] = []
        row_capped = False
        col_capped = False
        max_col_seen = 0

        for row_elem in row_elems:
            if len(sheet_rows) >= MAX_XLSX_ROWS:
                row_capped = True
                truncated = True
                break
            row_cells: dict[int, str] = {}
            next_seq_col = 0
            for c_elem in row_elem.findall(f"{{{_SHEET_NS}}}c"):
                col_idx = _col_letters_to_index(c_elem.attrib.get("r", ""))
                if col_idx is None:
                    col_idx = next_seq_col
                next_seq_col = col_idx + 1
                if col_idx >= MAX_XLSX_COLS:
                    col_capped = True
                    truncated = True
                    continue
                val = _escape_md_cell(_extract_xlsx_cell_value(c_elem, shared_strings))
                if val:
                    row_cells[col_idx] = val
                    if col_idx + 1 > max_col_seen:
                        max_col_seen = col_idx + 1

            if not row_cells:
                continue
            dense_row = [row_cells.get(i, "") for i in range(max_col_seen)]
            sheet_rows.append(dense_row)

        if not sheet_rows or max_col_seen == 0:
            sections.append(f"## {sheet_name}\n\n> （工作表无数据）")
            continue

        normalized = [r + [""] * (max_col_seen - len(r)) for r in sheet_rows]
        md_lines = [
            f"## {sheet_name}",
            "",
            "| " + " | ".join(normalized[0]) + " |",
            "| " + " | ".join(["---"] * max_col_seen) + " |",
        ]
        for r in normalized[1:]:
            md_lines.append("| " + " | ".join(r) + " |")
        if row_capped or col_capped:
            notes: list[str] = []
            if row_capped:
                notes.append(f"最多展示前 {MAX_XLSX_ROWS} 行")
            if col_capped:
                notes.append(f"最多展示前 {MAX_XLSX_COLS} 列")
            md_lines.append("")
            md_lines.append(f"> （已截断：{'，'.join(notes)}，完整表格请下载原文件）")
        sections.append("\n".join(md_lines))

    return "\n\n".join(sections), truncated


def _extract_pptx_paragraphs(container: ET.Element) -> list[str]:
    paragraphs: list[str] = []
    for p in container.findall(f".//{{{_DRAWING_NS}}}p"):
        runs = [t.text for t in p.findall(f".//{{{_DRAWING_NS}}}t") if t.text]
        line = "".join(runs).strip()
        if line:
            paragraphs.append(line)
    return paragraphs


def _extract_pptx(zf: zipfile.ZipFile) -> tuple[str, bool]:
    slide_entries: list[tuple[int, str]] = []
    for member in zf.namelist():
        m = _SLIDE_MEMBER_RE.match(member)
        if m:
            slide_entries.append((int(m.group(1)), member))
    slide_entries.sort(key=lambda item: item[0])

    if not slide_entries:
        raise OfficePreviewError("PPTX 文档未包含可读的幻灯片页面")

    sections: list[str] = []
    for slide_no, member in slide_entries:
        slide_root = _parse_xml_member(zf, member)
        if slide_root is None:
            continue
        lines: list[str] = []
        seen: set[str] = set()
        sp_tree = slide_root.find(f".//{{{_PPT_NS}}}spTree")
        shapes = list(sp_tree) if sp_tree is not None else [slide_root]
        for shape in shapes:
            for para in _extract_pptx_paragraphs(shape):
                if para not in seen:
                    seen.add(para)
                    lines.append(para)

        header = f"## 第 {slide_no} 页"
        if lines:
            sections.append(f"{header}\n\n" + "\n\n".join(lines))
        else:
            sections.append(f"{header}\n\n> （本页无文本内容）")

    return "\n\n".join(sections), False


def extract_office_preview_markdown(target: Path) -> tuple[str, bool]:
    """Convert .docx / .xlsx / .pptx file into a lightweight Markdown preview."""
    if not target.exists() or not target.is_file():
        raise OfficePreviewError("File not found", status_code=404)

    suffix = target.suffix.lower()
    if suffix not in SUPPORTED_OFFICE_EXTENSIONS:
        raise OfficePreviewError(
            "暂不支持该格式的在线预览，请下载原文件查看",
            status_code=415,
        )

    try:
        file_size = target.stat().st_size
    except OSError as exc:
        raise OfficePreviewError(f"无法读取文件信息: {exc}", status_code=404) from exc

    if file_size > MAX_OFFICE_FILE_BYTES:
        raise OfficePreviewError(
            f"文件超过预览上限（最大 {MAX_OFFICE_FILE_BYTES // (1024 * 1024)} MB），请下载原文件查看",
            status_code=413,
        )

    try:
        with zipfile.ZipFile(target, "r") as zf:
            if suffix == ".docx":
                md_text, truncated = _extract_docx(zf)
            elif suffix == ".xlsx":
                md_text, truncated = _extract_xlsx(zf)
            else:
                md_text, truncated = _extract_pptx(zf)
    except OfficePreviewError:
        raise
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError, OSError) as exc:
        raise OfficePreviewError(
            "无法解析该 Office 文档（可能已加密或文件损坏），请下载查看",
            status_code=422,
        ) from exc

    cleaned = md_text.strip()
    if not cleaned:
        return "> （文档未提取到可展示的文本内容，请下载原文件查看）", truncated

    if len(cleaned) > MAX_PREVIEW_CHARS:
        cleaned = (
            cleaned[:MAX_PREVIEW_CHARS].rstrip()
            + "\n\n> （预览内容过长已截断，完整内容请下载原文件查看）"
        )
        truncated = True

    return cleaned, truncated
