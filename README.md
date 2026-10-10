# Cargo Vendor 离线依赖包生成器

在 GitHub Issue 中提交一个 `Cargo.toml`，本仓库的 GitHub Action 会自动：

1. 解析 Issue 里的 `Cargo.toml`（代码块或附件）；
2. 执行 `cargo vendor` 下载全部依赖源码；
3. 打包成 `cargo-offline-issue-<N>.tar.gz`（含 `vendor/`、`.cargo/config.toml`、`Cargo.lock`、导入脚本）；
4. 上传到 Release，并在 Issue 中回复下载地址与使用方法。

离线机器拿到压缩包后，运行附带的 `restore-offline.sh` / `restore-offline.ps1` 即可完成导入，随后可 `cargo build --offline`。

## 使用方法

### 1. 新建 Issue 提交 Cargo.toml

**方式 A：粘贴代码块（推荐）**

````markdown
```toml
[package]
name = "demo"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }
tokio = { version = "1", features = ["full"] }
```
````

**方式 B：上传附件**

把 `Cargo.toml` 文件拖拽进 Issue 编辑框，正文无需额外内容。

### 2. 等待 Action 完成

Action 完成后会在 Issue 中回复：

```
✅ Cargo 离线依赖包已生成
下载地址: https://github.com/<owner>/<repo>/releases/download/cargo-vendor-issue-<N>/cargo-offline-issue-<N>.tar.gz
```

### 3. 在离线机器导入

```bash
# 1) 解压
tar -xzf cargo-offline-issue-<N>.tar.gz

# 2) 导入到你的项目（把 vendor 与 .cargo/config.toml 放好）
bash cargo-offline-issue-<N>/scripts/restore-offline.sh --target /path/to/your/project

# 3) 离线构建
cd /path/to/your/project
cargo build --offline
```

Windows PowerShell：

```powershell
.\cargo-offline-issue-<N>\scripts\restore-offline.ps1 -Target C:\path\to\your\project
```

若希望一次导入供所有项目使用：

```bash
bash cargo-offline-issue-<N>/scripts/restore-offline.sh --global
```

### 4. 重新生成

在 Issue 中评论 `/vendor` 即可重新生成并覆盖 Release 附件。

## 仓库结构

```
.github/workflows/cargo-vendor.yml   # GitHub Action 主流程
scripts/
  extract_manifest.py                # 从 Issue 提取 Cargo.toml（代码块/附件）
  prepare_project.py                 # 补齐 src/、workspace 成员等占位文件
  build_bundle.sh                    # cargo vendor + 组装 + 校验 + 打包
  publish.sh                         # 创建 Release 并回复 Issue
templates/
  restore-offline.sh                 # Linux/macOS 导入脚本
  restore-offline.ps1                # Windows 导入脚本
```

## 工作原理

导入脚本生成的 `.cargo/config.toml` 使用 Cargo 的 source replacement，把 crates.io 指向本地 `vendor/`：

```toml
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"

[net]
offline = true
```

## 限制

- **单个 Cargo.toml**：只解析一个 manifest。workspace 的通配成员（如 `crates/*`）无法自动补全，
  其成员依赖可能缺失；如需完整依赖，请说明成员清单。
- **path / 私有依赖**：本地 path 依赖与需要认证的私有 registry、私有 git 依赖无法离线使用。
- **版本一致**：离线包基于本次生成的 `Cargo.lock`，请用包内 `Cargo.lock` 覆盖项目，保证版本一致。
- **工具链**：离线机器的 Rust 版本建议不低于生成时的版本。

## 权限

工作流需要 `contents: write`（创建 Release）和 `issues: write`（回复 Issue），已在 workflow 中声明。
仓库 `Settings → Actions → General → Workflow permissions` 建议允许写入（默认 `GITHUB_TOKEN` 权限已在本工作流中显式提升）。

## 本地调试

```bash
pip install tomli        # Python < 3.11
mkdir -p input
cp /path/to/Cargo.toml input/Cargo.toml
ISSUE_NUMBER=1 GITHUB_REPOSITORY=owner/repo bash scripts/build_bundle.sh
```

产物位于 `dist/`。
