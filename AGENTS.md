# Venera 项目约定（Agent 指南）

## 项目概况

- Flutter 多平台客户端：Android / Windows / Linux / iOS / macOS / HarmonyOS(OHOS)。
- 仓库根目录即本目录；Flutter 工程在 `venera/`。
- 三平台主力构建：Android（apk，含 Rust `rhttp`）/ Windows（exe + Inno Setup 安装包）/ HarmonyOS（hap，hvigor）。
- 发布包归档目录：`dist/`（已在 `.gitignore` 中，不入库）。

## 本机工具链（实测）

| 工具 | 路径 |
| --- | --- |
| Flutter（ohos 分支） | `F:\flutter_ohos\bin\flutter.bat` |
| ohpm / hvigor | `D:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin\ohpm.bat`、`...\hvigor\bin\hvigorw.bat` |
| Rust / cargo | `C:\Users\26981\.cargo\bin\cargo.exe` |
| Android SDK | `C:\tools\android-sdk`（platform-tools / build-tools / ndk / cmake 齐全） |
| Node | `D:\Program Files\nodejs\node.exe` |

> 环境注意：`pwsh` 沙箱下直接执行 `.bat` 可能被拒绝；`git` 需带 `-c safe.directory=<repo>`，否则报 `dubious ownership`。

## 定期清理（重要约定）

清理入口：`scripts/clean_artifacts.ps1`

```bash
pwsh scripts/clean_artifacts.ps1                      # dry-run，只预览
pwsh scripts/clean_artifacts.ps1 -Execute             # 归档发布包到 dist/ 后清理
pwsh scripts/clean_artifacts.ps1 -Execute -IncludeBackups   # 连同本地备份/实验目录
```

规则：

1. **可重建产物随时可清**（满仓约 4.9 GB）：`venera/build`、`venera/ohos/entry/build`、`venera/.dart_tool/flutter_build`、`venera/windows/flutter/ephemeral`、`venera/ohos/entry/src/main/resources/rawfile/flutter_assets`、`venera/ohos_plugins/*/android/.cxx`、`venera/ohos/oh_modules`、`venera/ohos/.hvigor`、`venera/ohos/entry/.cxx`、`venera/android/.gradle`。
2. **清理前必须确认目标内没有被 Git 跟踪的文件**——脚本已内置该保护，禁止绕过；新增清理目标时同样适用。
3. **发布包先归档再清理**：apk / hap / exe / ipa / zip（≥5 MB）按 SHA256 去重后进 `dist/`。
4. `log/` 是项目开发记录（历史 7 个已入库），**保留**；新增日志不再入库（已 ignore）。
5. 不要删除 `tools/procdump.exe`（本地 native 崩溃抓取工具）。

## 清理后的重建

| 目标 | 命令 |
| --- | --- |
| `.dart_tool` / `windows/flutter/ephemeral` | `flutter pub get` |
| Android APK | `flutter build apk --release` |
| Windows exe / 安装包 | `flutter build windows --release`，再 `python venera/windows/build.py` |
| 鸿蒙依赖 | `ohpm install`（重建 `ohos/oh_modules`） |
| 鸿蒙 HAP | **先走 Flutter 侧构建**生成 `rawfile/flutter_assets`，再用 hvigor/DevEco 打包；直接跑 hvigor 会打出缺 flutter_assets 的坏包 |

## 参考文档

- `doc/venera-download-system.md`：下载系统架构与移植指南（含 OHOS 专项）。
- `log/product_log_*.txt`：各阶段开发记录（问题、构建状态、环境信息）。
