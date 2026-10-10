#!/usr/bin/env python3
"""为 `cargo vendor` 准备一个可解析的项目骨架。

用户通常只上传一个 Cargo.toml，缺少 src/ 源码、build.rs、workspace 成员等，
cargo 会因为找不到目标文件而报错。本脚本根据 manifest 补齐最小占位文件，
只影响依赖解析（vendor），不会影响用户真实项目。

用法: python3 prepare_project.py <work-dir>
"""
from __future__ import annotations

import glob
import pathlib
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    try:
        import tomli as tomllib  # type: ignore
    except ModuleNotFoundError:
        print("[prepare] 需要 Python 3.11+ 或安装 tomli", file=sys.stderr)
        sys.exit(1)

KNOWN_TARGET_KEYS = ("bin", "example", "test", "bench")


def log(msg: str) -> None:
    print(f"[prepare] {msg}", flush=True)


def load_manifest(path: pathlib.Path) -> dict:
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def sanitize_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "-", name).strip("-")
    if not cleaned or cleaned[0].isdigit():
        cleaned = f"stub-{cleaned}" if cleaned else "stub-crate"
    return cleaned


def touch(path: pathlib.Path) -> bool:
    if path.exists():
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("", encoding="utf-8")
    return True


def ensure_package_targets(work: pathlib.Path, data: dict, created: list[str]) -> None:
    pkg = data.get("package", {})
    if not isinstance(pkg, dict):
        return

    # 显式 [lib] path
    lib = data.get("lib", {})
    if isinstance(lib, dict) and lib.get("path"):
        if touch(work / lib["path"]):
            created.append(lib["path"])

    # 默认 lib.rs / main.rs，保证至少有一个可解析目标
    if touch(work / "src" / "lib.rs"):
        created.append("src/lib.rs")
    if touch(work / "src" / "main.rs"):
        created.append("src/main.rs")

    # 显式 build 脚本
    build = pkg.get("build")
    if isinstance(build, str) and build and touch(work / build):
        created.append(build)

    # [[bin]] / [[example]] / [[test]] / [[bench]]
    for key in KNOWN_TARGET_KEYS:
        entries = data.get(key, [])
        if isinstance(entries, dict):
            entries = [entries]
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            explicit = entry.get("path")
            if explicit:
                if touch(work / explicit):
                    created.append(explicit)
                continue
            name = entry.get("name")
            if not name:
                continue
            default_dir = {
                "bin": "src/bin",
                "example": "examples",
                "test": "tests",
                "bench": "benches",
            }[key]
            rel = f"{default_dir}/{name}.rs"
            if touch(work / rel):
                created.append(rel)


def ensure_workspace_members(work: pathlib.Path, data: dict, created: list[str]) -> None:
    ws = data.get("workspace")
    if not isinstance(ws, dict):
        return
    members = ws.get("members", [])
    if isinstance(members, str):
        members = [members]
    if not isinstance(members, list):
        return

    workspace_deps = ws.get("dependencies", {})
    if not isinstance(workspace_deps, dict):
        workspace_deps = {}

    for member in members:
        if not isinstance(member, str):
            continue
        if any(ch in member for ch in "*?["):
            log(f"跳过通配 workspace 成员: {member}（无法自动创建，依赖可能缺失）")
            continue
        member_dir = (work / member).resolve()
        try:
            member_dir.relative_to(work.resolve())
        except ValueError:
            log(f"跳过越界 workspace 成员: {member}")
            continue
        member_dir.mkdir(parents=True, exist_ok=True)
        manifest = member_dir / "Cargo.toml"
        if not manifest.exists():
            name = sanitize_name(pathlib.Path(member).name or "member")
            # 把 [workspace.dependencies] 注入占位成员，确保这些依赖会被 vendor
            dep_lines = "".join(
                f'"{dep_name}" = {{ workspace = true }}\n' for dep_name in workspace_deps
            )
            manifest.write_text(
                f'[package]\nname = "{name}"\nversion = "0.0.0"\nedition = "2021"\n\n'
                f"[dependencies]\n{dep_lines}",
                encoding="utf-8",
            )
            created.append(f"{member}/Cargo.toml")
        if touch(member_dir / "src" / "lib.rs"):
            created.append(f"{member}/src/lib.rs")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    work = pathlib.Path(sys.argv[1]).resolve()
    manifest_path = work / "Cargo.toml"
    if not manifest_path.exists():
        print(f"[prepare] 未找到 {manifest_path}", file=sys.stderr)
        return 1

    try:
        data = load_manifest(manifest_path)
    except Exception as exc:
        print(f"[prepare] Cargo.toml 解析失败: {exc}", file=sys.stderr)
        return 1

    created: list[str] = []
    ensure_package_targets(work, data, created)
    ensure_workspace_members(work, data, created)

    if created:
        log(f"补齐占位文件 {len(created)} 个: {', '.join(sorted(set(created))[:12])}"
            + (" ..." if len(created) > 12 else ""))
    else:
        log("无需补齐占位文件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
