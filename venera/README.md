# venera（Venera 优化版）

[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/Leif-Wang-021/venera)](https://github.com/Leif-Wang-021/venera/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/Leif-Wang-021/venera?style=flat)](https://github.com/Leif-Wang-021/venera/stargazers)

[![Download](https://img.shields.io/github/v/release/Leif-Wang-021/venera)](https://github.com/Leif-Wang-021/venera/releases)
[![AUR Version](https://img.shields.io/aur/version/venera-bin)](https://aur.archlinux.org/packages/venera-bin)
[![F-Droid Version](https://img.shields.io/f-droid/v/com.github.wgh136.venera)](https://f-droid.org/packages/com.github.wgh136.venera/)

A comic reader that supports reading local and network comics.

> 本项目以 **vibecoding（氛围编程）**方式开发：在原作者思想与社区最佳实践
> 基础上，通过与 AI 结对、以日志/实测证据驱动迭代快速实现功能优化。

## 项目来源与版权

- 本仓库 **fork 自 [venera-app/venera](https://github.com/venera-app/venera)**（原作者：wgh136）。
- 原作者已停止维护，并欢迎 fork；本仓库保留原作者版权信息与原始开源协议。
- 开源协议：**GNU General Public License v3.0（GPL-3.0）**，详见 [LICENSE](LICENSE)。
- 任何再分发、修改均须遵守 GPL-3.0 要求，并保留原作者署名与本声明。

## 相对原版的优化功能

- **下载限流调度器**：NORMAL/PROBING/BACKOFF 状态机 + BURST/CRUISE 发起节奏器，
  模拟源站放行速率，显著减少“fetching image 卡顿”与风控惩罚。
- **下载可靠性**：全局指数退避+抖动、过期签名 URL 自动刷新、死链快败、
  单图隔离、死链章节跳过。
- **取消任务即删除本地文件夹**：取消后立即清理目标章节目录，失败写日志并提示。
- **“获取图片列表”与“下载图片”并行化**：有序交接门（ChapterReadyGate），
  部分列表就绪即可开始下载，同时保持原有进度语义。
- **导出压缩 Worker 化**：专用 Isolate 执行压缩，字节级进度 + 可取消 +
  `.tmp` 校验后原子改名，不再卡 UI、不再产生半成品压缩包。
- **版本号单一事实源**：只维护 pubspec.yaml，其余展示/构建版本由脚本生成，
  并有漂移守卫测试。
- **HarmonyOS 移植**：新增 `ohos/` 平台工程与 `ohos_plugins/` 原生/兼容插件，
  已打通 QuickJS 源运行时、sqlite3、网络、zip/WebDAV、阅读器全链路。
- **无头化测试通道**：`dlbench`/`dltask`/`zipbench` 等命令，便于回归与性能取证。

## Features
- Read local comics
- Use javascript to create comic sources
- Read comics from network sources
- Manage favorite comics
- Download comics
- View comments, tags, and other information of comics if the source supports
- Login to comment, rate, and other operations if the source supports

## Build from source
1. Clone the repository
2. Install flutter, see [flutter.dev](https://flutter.dev/docs/get-started/install)
3. Install rust, see [rustup.rs](https://rustup.rs/)
4. Build for your platform: e.g. `flutter build apk`
5. HarmonyOS：使用支持 `build hap` 的 Flutter-OH 工具链，在 `ohos/` 目录构建 HAP

## Create a new comic source
See [Comic Source](doc/comic_source.md)

## Thanks

### Tags Translation
[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

## Headless Mode
See [Headless Doc](doc/headless_doc.md)

## 免责声明

本项目**仅供学习、研究、技术交流参考使用**。开发者不对使用本项目产生的
任何后果负责，包括但不限于：内容版权问题、数据丢失、设备异常、网络服务
账号风险等。请遵守所在地区法律法规及目标网站服务条款，**使用风险自负**。