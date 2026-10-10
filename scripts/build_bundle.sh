#!/usr/bin/env bash
# 生成 cargo vendor 离线依赖包（tar.gz + sha256）。
#
# 输入: input/Cargo.toml
# 输出: dist/cargo-offline-issue-<N>.tar.gz
#       dist/cargo-offline-issue-<N>.tar.gz.sha256
#       dist/cargo-vendor.log
#
# 依赖环境变量: ISSUE_NUMBER, GITHUB_REPOSITORY
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISSUE_NUMBER="${ISSUE_NUMBER:-0}"
REPO="${GITHUB_REPOSITORY:-unknown/repo}"
TAG="cargo-vendor-issue-${ISSUE_NUMBER}"

WORK="$ROOT/work"
DIST="$ROOT/dist"
BUNDLE_NAME="cargo-offline-issue-${ISSUE_NUMBER}"
STAGE="$DIST/$BUNDLE_NAME"
TARBALL="$DIST/${BUNDLE_NAME}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${BUNDLE_NAME}.tar.gz"

log()  { printf '\033[1;34m[vendor]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[vendor]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[vendor][error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$ROOT/input/Cargo.toml" ]] || die "缺少 input/Cargo.toml"
command -v cargo >/dev/null 2>&1 || die "未找到 cargo"

rm -rf "$WORK" "$STAGE"
mkdir -p "$WORK" "$DIST"

log "1/6 准备项目骨架"
cp "$ROOT/input/Cargo.toml" "$WORK/Cargo.toml"
python3 "$ROOT/scripts/prepare_project.py" "$WORK"

log "2/6 生成 Cargo.lock"
( cd "$WORK" && cargo generate-lockfile )

log "3/6 执行 cargo vendor（下载依赖）"
# stdout 是 cargo 生成的 source 配置，stderr 是日志
if ! ( cd "$WORK" && cargo vendor --versioned-dirs --locked vendor ) \
        > "$DIST/cargo-vendor-config.generated.toml" 2> "$DIST/cargo-vendor.log"; then
  cat "$DIST/cargo-vendor.log" >&2
  die "cargo vendor 失败"
fi
tail -n 5 "$DIST/cargo-vendor.log" 2>/dev/null || true

log "4/6 组装离线包目录"
mkdir -p "$STAGE/.cargo" "$STAGE/scripts"
cp "$WORK/Cargo.toml" "$STAGE/Cargo.toml"
[[ -f "$WORK/Cargo.lock" ]] && cp "$WORK/Cargo.lock" "$STAGE/Cargo.lock"
cp -a "$WORK/vendor" "$STAGE/vendor"
cp "$DIST/cargo-vendor-config.generated.toml" "$STAGE/cargo-vendor-config.generated.toml"

cat > "$STAGE/.cargo/config.toml" <<'CFG'
# 由 GitHub Action 自动生成：cargo vendor 离线源替换配置
# 更多说明见同级目录 README-OFFLINE.md
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"

[net]
offline = true
CFG

install -m 0755 "$ROOT/templates/restore-offline.sh"  "$STAGE/scripts/restore-offline.sh"
install -m 0644 "$ROOT/templates/restore-offline.ps1" "$STAGE/scripts/restore-offline.ps1"

# crates 清单
ls -1 "$STAGE/vendor" > "$STAGE/crates-manifest.txt"
cp "$STAGE/crates-manifest.txt" "$DIST/crates-manifest.txt"
CRATE_COUNT="$(wc -l < "$STAGE/crates-manifest.txt" | tr -d '[:space:]')"
RUSTC_VERSION="$(rustc --version 2>/dev/null || echo unknown)"
GENERATED_AT="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

cat > "$STAGE/bundle-info.json" <<EOF
{
  "issue": ${ISSUE_NUMBER},
  "repository": "${REPO}",
  "tag": "${TAG}",
  "bundle": "${BUNDLE_NAME}.tar.gz",
  "download_url": "${DOWNLOAD_URL}",
  "crate_count": ${CRATE_COUNT},
  "rustc_version": "${RUSTC_VERSION}",
  "generated_at": "${GENERATED_AT}"
}
EOF

log "5/6 离线校验（cargo metadata --offline）"
# 在 work 目录（含占位 src）中校验，显式用 --config 指向刚生成的 vendor/
if ! ( cd "$WORK" && cargo metadata --offline --format-version 1 \
        --config 'source.crates-io.replace-with="vendored-sources"' \
        --config 'source.vendored-sources.directory="vendor"' \
        > /dev/null 2> "$DIST/verify.log" ); then
  cat "$DIST/verify.log" >&2 || true
  die "离线校验失败：vendor 内容不完整"
fi

# 生成离线说明
cat > "$STAGE/README-OFFLINE.md" <<EOF
# Cargo 离线依赖包（Issue #${ISSUE_NUMBER}）

- 生成时间：${GENERATED_AT}
- Rust 工具链：\`${RUSTC_VERSION}\`
- 包含 crate 数量：**${CRATE_COUNT}**
- 下载地址：${DOWNLOAD_URL}
- SHA256：见 \`${BUNDLE_NAME}.tar.gz.sha256\`

## 目录结构

\`\`\`text
${BUNDLE_NAME}/
├── Cargo.toml                  # 与 Issue 中提交的一致
├── Cargo.lock                  # 解析后的锁定版本
├── .cargo/config.toml          # 指向 vendor/ 的离线源替换配置
├── vendor/                     # 全部依赖源码
├── crates-manifest.txt         # 依赖清单
├── scripts/restore-offline.sh  # Linux / macOS 导入脚本
├── scripts/restore-offline.ps1 # Windows 导入脚本
└── README-OFFLINE.md
\`\`\`

## 使用方法 A：导入到你的项目（推荐）

1. 把 \`${BUNDLE_NAME}.tar.gz\` 拷贝到离线机器并解压：

   \`\`\`bash
   tar -xzf ${BUNDLE_NAME}.tar.gz
   \`\`\`

2. 执行导入脚本，把 vendor 与配置写入你的项目目录：

   \`\`\`bash
   bash ${BUNDLE_NAME}/scripts/restore-offline.sh --target /path/to/your/project
   \`\`\`

   Windows（PowerShell）：

   \`\`\`powershell
   .\\${BUNDLE_NAME}\\scripts\\restore-offline.ps1 -Target C:\\path\\to\\your\\project
   \`\`\`

3. 在项目里离线构建：

   \`\`\`bash
   cargo build --offline
   # 或
   cargo build --locked --offline
   \`\`\`

## 使用方法 B：安装到 Cargo 全局配置

适合一台机器上有多个项目、且它们都使用同一套依赖的情况：

\`\`\`bash
bash ${BUNDLE_NAME}/scripts/restore-offline.sh --global
\`\`\`

之后任意项目执行 \`cargo build --offline\` 都会从该 vendor 目录取依赖。

> ⚠️ 全局模式会覆盖 \`~/.cargo/config.toml\` 中的 source 替换配置，建议仅在专用离线环境使用。

## 常见问题

- **报错 “no matching package / failed to select a version”**：离线包只包含本 Cargo.toml
  解析出的依赖。若你的项目依赖其它 workspace 成员或 path 依赖，它们的依赖不会包含在内。
- **必须使用同一个 \`Cargo.lock\`**：离线包基于生成的 lock 文件。请用包内自带的
  \`Cargo.lock\` 覆盖你的项目，或保证版本一致。
- **私有源 / git 依赖**：公开 crates.io 依赖可正常 vendor；私有 registry 与需要认证的
  git 依赖无法在离线机器上使用。
- **工具链版本**：建议离线机器的 Rust 版本不低于生成时使用的版本。
EOF

log "6/6 打包"
tar -C "$DIST" -czf "$TARBALL" "$BUNDLE_NAME"
( cd "$DIST" && sha256sum "${BUNDLE_NAME}.tar.gz" > "${BUNDLE_NAME}.tar.gz.sha256" )
SHA="$(cut -d' ' -f1 "$DIST/${BUNDLE_NAME}.tar.gz.sha256")"
SIZE="$(du -h "$TARBALL" | cut -f1)"
rm -rf "$STAGE"

log "完成: ${BUNDLE_NAME}.tar.gz (${SIZE}, ${CRATE_COUNT} crates, sha256=${SHA:0:16}...)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "bundle_name=${BUNDLE_NAME}"
    echo "bundle_path=${TARBALL}"
    echo "sha256=${SHA}"
    echo "crate_count=${CRATE_COUNT}"
    echo "download_url=${DOWNLOAD_URL}"
  } >> "$GITHUB_OUTPUT"
fi
