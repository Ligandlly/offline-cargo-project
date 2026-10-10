#!/usr/bin/env bash
# restore-offline.sh —— 在离线机器上导入 cargo vendor 离线依赖
#
# 两种模式：
#   --global              把 vendor 安装到 $CARGO_HOME/vendor/offline-bundle，
#                         并写入 $CARGO_HOME/config.toml（对所有项目生效）
#   --target <项目目录>    把 vendor 与 .cargo/config.toml 复制到指定项目
#
# 可选：
#   --cargo-home <路径>   指定 CARGO_HOME（默认 $CARGO_HOME 或 ~/.cargo）
#   --no-build            导入后不执行 cargo build 校验
#   --force               覆盖已存在的 vendor 目录
#
# 示例：
#   bash scripts/restore-offline.sh --target ~/myproject
#   bash scripts/restore-offline.sh --global
set -euo pipefail

SELF_PATH="${BASH_SOURCE[0]}"
while [ -L "$SELF_PATH" ]; do
  LINK_TARGET="$(readlink "$SELF_PATH")"
  case "$LINK_TARGET" in
    /*) SELF_PATH="$LINK_TARGET" ;;
    *) SELF_PATH="$(cd "$(dirname "$SELF_PATH")" && pwd)/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SELF_PATH")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE=""
TARGET=""
CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
DO_BUILD=1
FORCE=0

BLUE='\033[1;34m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
log()  { printf "${BLUE}[restore]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[restore]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[restore]${NC} %s\n" "$*" >&2; }
die()  { printf "${RED}[restore][error]${NC} %s\n" "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$SELF_PATH" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target|-t) [[ $# -ge 2 ]] || die "--target 需要目录参数"; TARGET="$2"; shift 2 ;;
    --global|-g) MODE="global"; shift ;;
    --local|-l)  MODE="local"; shift ;;
    --cargo-home) [[ $# -ge 2 ]] || die "--cargo-home 需要路径参数"; CARGO_HOME_DIR="$2"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --force|-f) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（使用 --help 查看帮助）" ;;
  esac
done

[[ -d "$BUNDLE_DIR/vendor" ]] || die "未找到 $BUNDLE_DIR/vendor，请确认在解压后的离线包内运行本脚本"

if [ -z "$MODE" ]; then
  if [ -n "$TARGET" ]; then MODE="local"; else MODE="global"; fi
fi

CONFIG_BODY='[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "__VENDOR_DIR__"

[net]
offline = true'

write_config_file() {
  local config_file="$1" vendor_dir="$2"
  mkdir -p "$(dirname "$config_file")"
  local block
  block="$(printf '%s\n' "$CONFIG_BODY" | sed "s#__VENDOR_DIR__#${vendor_dir}#")"

  if [ ! -f "$config_file" ]; then
    printf '%s\n' "$block" > "$config_file"
    return
  fi
  if grep -q "vendored-sources" "$config_file"; then
    warn "已存在 vendored-sources 配置，跳过写入（需要覆盖请手动编辑 $config_file）"
    return
  fi
  {
    printf '\n# >>> cargo offline vendor (auto-generated) >>>\n'
    printf '%s\n' "$block"
    printf '# <<< cargo offline vendor (auto-generated) <<<\n'
  } >> "$config_file"
}

install_local() {
  local project_dir
  project_dir="$(cd "$TARGET" 2>/dev/null && pwd)" || die "目标目录不存在: $TARGET"
  log "导入模式: 项目级"
  log "目标项目: $project_dir"

  if [ -e "$project_dir/vendor" ] && [ "$FORCE" -eq 0 ]; then
    die "$project_dir/vendor 已存在，使用 --force 覆盖"
  fi
  [ "$FORCE" -eq 1 ] && rm -rf "$project_dir/vendor"

  log "复制 vendor/ ..."
  cp -a "$BUNDLE_DIR/vendor" "$project_dir/vendor"
  write_config_file "$project_dir/.cargo/config.toml" "vendor"

  if [ ! -f "$project_dir/Cargo.lock" ] && [ -f "$BUNDLE_DIR/Cargo.lock" ]; then
    cp "$BUNDLE_DIR/Cargo.lock" "$project_dir/Cargo.lock"
    log "已复制 Cargo.lock"
  fi

  ok "导入完成: $project_dir"

  if [ "$DO_BUILD" -eq 1 ]; then
    if [ -f "$project_dir/Cargo.toml" ]; then
      log "离线校验: cargo build --offline"
      ( cd "$project_dir" && cargo build --offline ) || warn "cargo build --offline 失败，请检查项目与依赖是否匹配"
    else
      warn "目标目录没有 Cargo.toml，跳过构建校验"
    fi
  fi
}

install_global() {
  local dest="$CARGO_HOME_DIR/vendor/offline-bundle"
  local config_file="$CARGO_HOME_DIR/config.toml"
  log "导入模式: 全局"
  log "CARGO_HOME: $CARGO_HOME_DIR"

  if [ -e "$dest" ] && [ "$FORCE" -eq 0 ]; then
    die "$dest 已存在，使用 --force 覆盖"
  fi
  [ "$FORCE" -eq 1 ] && rm -rf "$dest"

  mkdir -p "$(dirname "$dest")"
  log "复制 vendor/ 到 $dest ..."
  cp -a "$BUNDLE_DIR/vendor" "$dest"

  mkdir -p "$CARGO_HOME_DIR"
  write_config_file "$CARGO_HOME_DIR/config.toml" "$dest"

  ok "全局导入完成，配置写入 $config_file"
  warn "全局 source 替换对所有项目生效，且仅适用于包含这些依赖版本的项目"

  if [ "$DO_BUILD" -eq 1 ]; then
    log "如需校验，请在你的项目目录执行: cargo build --offline"
  fi
}

case "$MODE" in
  local)
    [ -n "$TARGET" ] || die "local 模式必须提供 --target <项目目录>"
    install_local
    ;;
  global) install_global ;;
  *) die "未知模式: $MODE" ;;
esac
