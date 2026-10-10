#!/usr/bin/env bash
# 发布离线包到 GitHub Release，并在对应 Issue 中回复下载信息。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISSUE_NUMBER="${ISSUE_NUMBER:?缺少 ISSUE_NUMBER}"
REPO="${GITHUB_REPOSITORY:?缺少 GITHUB_REPOSITORY}"
TAG="cargo-vendor-issue-${ISSUE_NUMBER}"
BUNDLE_NAME="cargo-offline-issue-${ISSUE_NUMBER}"
BUNDLE="$ROOT/dist/${BUNDLE_NAME}.tar.gz"
SHA_FILE="$BUNDLE.sha256"

[[ -f "$BUNDLE" ]] || { echo "找不到 $BUNDLE" >&2; exit 1; }
[[ -f "$SHA_FILE" ]] || { echo "找不到 $SHA_FILE" >&2; exit 1; }

SHA="$(cut -d' ' -f1 "$SHA_FILE")"
SIZE="$(du -h "$BUNDLE" | cut -f1)"
URL="https://github.com/${REPO}/releases/download/${TAG}/${BUNDLE_NAME}.tar.gz"
CRATE_COUNT="$(wc -l < "$ROOT/dist/crates-manifest.txt" 2>/dev/null | tr -d '[:space:]' || echo '?')"
if [[ ! -f "$ROOT/dist/crates-manifest.txt" && -f "$ROOT/work/vendor" ]]; then
  CRATE_COUNT="$(ls -1 "$ROOT/work/vendor" | wc -l | tr -d '[:space:]')"
fi

echo "[publish] 发布 Release: $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$BUNDLE" "$SHA_FILE" --clobber --repo "$REPO"
else
  gh release create "$TAG" "$BUNDLE" "$SHA_FILE" --repo "$REPO" \
    --title "Cargo 离线依赖包 - Issue #${ISSUE_NUMBER}" \
    --notes "由 GitHub Actions 自动生成，对应 Issue #${ISSUE_NUMBER}。重新评论 \`/vendor\` 会覆盖此 Release 中的附件。" \
    --latest=false
fi

cat > /tmp/vendor-comment.md <<EOF
## ✅ Cargo 离线依赖包已生成

| 项目 | 值 |
| --- | --- |
| 文件 | \`${BUNDLE_NAME}.tar.gz\` |
| 大小 | ${SIZE} |
| 依赖数量 | ${CRATE_COUNT} 个 crate |
| SHA256 | \`${SHA}\` |
| 下载地址 | **[点此下载](${URL})** |

### 离线机器导入步骤

1. 在有网的机器下载上面的 tar.gz（或直接从 Release 页面下载），拷贝到离线机器。
2. 解压并导入到你自己的 Cargo 项目：

   \`\`\`bash
   tar -xzf ${BUNDLE_NAME}.tar.gz
   bash ${BUNDLE_NAME}/scripts/restore-offline.sh --target /path/to/your/project
   \`\`\`

   Windows PowerShell：

   \`\`\`powershell
   .\\${BUNDLE_NAME}\\scripts\\restore-offline.ps1 -Target C:\\path\\to\\your\\project
   \`\`\`

3. 离线构建：

   \`\`\`bash
   cargo build --offline
   \`\`\`

> 详细说明与常见问题见包内 \`README-OFFLINE.md\`。如需重新生成，在本 Issue 评论 \`/vendor\`。
EOF

echo "[publish] 回复 Issue #$ISSUE_NUMBER"
gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body-file /tmp/vendor-comment.md
