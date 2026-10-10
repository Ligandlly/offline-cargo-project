#!/usr/bin/env python3
"""从 GitHub Issue / 评论正文中提取 Cargo.toml。

支持三种来源（按优先级）：
  1. fenced code block，例如 ```toml ... ```；
  2. 正文中直接粘贴的 `[package]` / `[workspace]` 段落；
  3. Issue 附件链接（GitHub user-attachments / files）。

结果写入 input/Cargo.toml，并向 GITHUB_OUTPUT 输出 found / cargo_related。
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    try:
        import tomli as tomllib  # type: ignore
    except ModuleNotFoundError:
        tomllib = None  # type: ignore

ROOT = pathlib.Path(__file__).resolve().parent.parent
INPUT_DIR = ROOT / "input"
MANIFEST_OUT = INPUT_DIR / "Cargo.toml"
ERROR_OUT = INPUT_DIR / "error.md"

FENCED_RE = re.compile(r"```[ \t]*([A-Za-z0-9_+.-]*)[ \t]*\r?\n(.*?)```", re.DOTALL)
SECTION_START_RE = re.compile(r"^[ \t]*\[(?:package|workspace)\][ \t]*$", re.MULTILINE)
URL_RE = re.compile(r"https?://[^\s<>()\[\]\"'`]+")
CARGO_RE = re.compile(r"cargo|vendor|Cargo\.toml|\[dependencies|\[package\]|\[workspace\]", re.IGNORECASE)

KNOWN_KEYS = {
    "package", "workspace", "dependencies", "dev-dependencies",
    "build-dependencies", "target", "lib", "bin", "example", "test",
    "bench", "features", "profile", "patch", "replace", "lints",
    "workspace.dependencies",
}
PREFERRED_LANGS = {"toml", "cargo", "rust", "ini", ""}


def parse_toml(text: str):
    if tomllib is None:
        return None
    try:
        return tomllib.loads(text)
    except Exception:
        return None


def score_manifest(text: str) -> int:
    data = parse_toml(text)
    if not isinstance(data, dict):
        return -1
    keys = set(data.keys())
    if not (keys & KNOWN_KEYS):
        return -1
    score = len(keys & {"package", "workspace"}) * 10
    if keys & {"dependencies", "dev-dependencies", "build-dependencies", "target"}:
        score += 5
    score += min(len(text) // 100, 5)
    return score


def trim_to_valid_toml(text: str) -> str | None:
    lines = text.splitlines()
    # 最多尝试 300 行，避免极端情况下 O(n^2) 过慢
    start = max(0, len(lines) - 300)
    for end in range(len(lines), start, -1):
        candidate = "\n".join(lines[:end]).strip()
        if not candidate:
            continue
        if score_manifest(candidate) >= 0:
            return candidate + "\n"
    return None


def from_fenced_blocks(body: str) -> str | None:
    best_text = None
    best_score = -1
    for lang, content in FENCED_RE.findall(body):
        if lang.lower() not in PREFERRED_LANGS:
            continue
        score = score_manifest(content)
        if score > best_score:
            best_score = score
            best_text = content
    if best_text is None:
        return None
    return best_text.strip() + "\n"


def from_raw_body(body: str) -> str | None:
    match = SECTION_START_RE.search(body)
    if not match:
        return None
    return trim_to_valid_toml(body[match.start():])


def is_attachment_url(url: str) -> bool:
    return (
        "github.com/user-attachments/" in url
        or ("github.com" in url and "/files/" in url)
        or "user-images.githubusercontent.com" in url
        or url.lower().endswith(".toml")
    )


def download(url: str, dest: pathlib.Path, token: str | None) -> tuple[bool, str]:
    attempts = [True, False] if token else [False]
    last_err = "下载失败"
    for use_token in attempts:
        cmd = [
            "curl", "-sSL", "-f", "--retry", "3", "--max-time", "180",
            "-H", "Accept: application/octet-stream",
        ]
        if use_token:
            cmd += ["-H", f"Authorization: Bearer {token}"]
        cmd += ["-o", str(dest), url]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True)
        except FileNotFoundError:
            return False, "系统未找到 curl"
        if proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0:
            return True, ""
        last_err = proc.stderr.strip() or f"curl 退出码 {proc.returncode}"
    return False, last_err


def from_attachments(body: str, token: str | None) -> str | None:
    for url in URL_RE.findall(body):
        url = url.rstrip(".,;:")
        if not is_attachment_url(url):
            continue
        tmp = INPUT_DIR / "attachment.toml"
        ok, err = download(url, tmp, token)
        if not ok:
            log(f"附件下载失败: {url} ({err})")
            continue
        try:
            text = tmp.read_text(encoding="utf-8", errors="replace")
        except Exception as exc:  # pragma: no cover
            log(f"附件读取失败: {url} ({exc})")
            continue
        cleaned = text.lstrip("\ufeff").strip()
        if score_manifest(cleaned) >= 0:
            log(f"使用附件: {url}")
            return cleaned + "\n"
        log(f"附件内容不是有效的 Cargo.toml: {url}")
    return None


def log(msg: str) -> None:
    print(f"[extract] {msg}", flush=True)


def write_outputs(**values: object) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        for key, value in values.items():
            fh.write(f"{key}={value}\n")


def write_error() -> None:
    ERROR_OUT.parent.mkdir(parents=True, exist_ok=True)
    ERROR_OUT.write_text(
        "## ⚠️ 未找到可用的 Cargo.toml\n\n"
        "请按下面任意一种方式重新提交，然后在本 Issue 中评论 `/vendor` 重新生成。\n\n"
        "### 方式 1：粘贴代码块（推荐）\n\n"
        "````markdown\n"
        "```toml\n"
        '[package]\nname = "demo"\nversion = "0.1.0"\nedition = "2021"\n\n'
        "[dependencies]\nserde = \"1\"\n```\n"
        "````\n\n"
        "### 方式 2：上传 Cargo.toml 附件\n\n"
        "直接把 `Cargo.toml` 文件拖拽到编辑框即可，无需其它说明。\n\n"
        "> 提示：只支持单个 Cargo.toml。若为 workspace，请把需要生成依赖的成员清单也一并说明"
        "（成员 manifest 中的第三方依赖才会被 vendored）。\n",
        encoding="utf-8",
    )


def main() -> int:
    INPUT_DIR.mkdir(parents=True, exist_ok=True)

    issue_body = (os.environ.get("ISSUE_BODY") or "").strip()
    comment_body = (os.environ.get("COMMENT_BODY") or "").strip()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

    combined = f"{comment_body}\n{issue_body}".strip()
    cargo_related = bool(CARGO_RE.search(combined)) or "user-attachments" in combined

    sources: list[tuple[str, str]] = []
    if comment_body:
        sources.append(("comment", comment_body))
    if issue_body:
        sources.append(("issue", issue_body))

    manifest = None
    used = None
    for name, body in sources:
        manifest = from_fenced_blocks(body)
        if manifest:
            used = f"{name}-codeblock"
            break
        manifest = from_raw_body(body)
        if manifest:
            used = f"{name}-raw"
            break

    if not manifest:
        manifest = from_attachments(combined, token)
        if manifest:
            used = "attachment"

    if not manifest:
        log("未找到 Cargo.toml")
        write_outputs(found="false", cargo_related=str(cargo_related).lower())
        if cargo_related:
            write_error()
        return 0

    MANIFEST_OUT.write_text(manifest, encoding="utf-8")
    (INPUT_DIR / "issue.json").write_text(
        json.dumps(
            {
                "source": used,
                "issue_url": os.environ.get("GITHUB_EVENT_PATH", ""),
                "repo": os.environ.get("GITHUB_REPOSITORY", ""),
                "run_id": os.environ.get("GITHUB_RUN_ID", ""),
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    log(f"已提取 Cargo.toml（来源: {used}，{len(manifest)} 字节）")
    write_outputs(found="true", cargo_related="true", source=used)
    return 0


if __name__ == "__main__":
    sys.exit(main())
