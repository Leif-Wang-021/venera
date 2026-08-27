# venera（Venera 优化版）

A comic reader that supports reading local and network comics.

[![License](https://img.shields.io/github/license/Leif-Wang-021/venera)](https://github.com/Leif-Wang-021/venera/blob/main/LICENSE)
[![stars](https://img.shields.io/github/stars/Leif-Wang-021/venera?style=flat)](https://github.com/Leif-Wang-021/venera/stargazers)
[![Download](https://img.shields.io/github/v/release/Leif-Wang-021/venera)](https://github.com/Leif-Wang-021/venera/releases)

> 本项目以 **Vibe Coding** 方式开发。

## 项目来源与版权

- 本仓库 **fork 自 [venera-app/venera](https://github.com/venera-app/venera)**（原作者：wgh136）。
- 原作者已停止维护，本仓库保留原作者版权信息与原始开源协议。
- 开源协议：**GNU General Public License v3.0（GPL-3.0）**，详见 [LICENSE](venera/LICENSE)。

## 相对上游的优化功能

- 下载限流调度：NORMAL/PROBING/BACKOFF 状态机 + BURST/CRUISE 发起节奏器，减少 fetching image 卡顿与风控惩罚。
- 下载可靠性：指数退避+抖动、过期签名 URL 自动刷新、死链快败/单图隔离/章节跳过。
- 取消任务即删除本地文件夹；列表获取与图片下载两阶段并行（ChapterReadyGate 有序交接）。
- 导出压缩 Worker 化：字节级进度 + 可取消 + `.tmp` 校验后原子改名，不再卡 UI。
- 版本号单一事实源：只维护 pubspec.yaml，生成与漂移守卫测试保证一致。
- **HarmonyOS 移植**：新增 `ohos/` 平台工程与 `ohos_plugins/` 插件层，已打通 QuickJS 源运行时、sqlite3、网络、zip/WebDAV、阅读器全链路。
- 无头化测试通道：`dlbench`/`dltask`/`zipbench` 等，便于回归与性能取证。

## 仓库结构

- `venera/`：Flutter 应用主工程（Windows / Android / HarmonyOS 源码）
- `venera/ohos/`：HarmonyOS 平台工程
- `venera/ohos_plugins/`：HarmonyOS 兼容/原生化插件
- `log/`：开发日志（含鸿蒙专线日志）

## 构建

1. 进入 `venera/`
2. 安装 Flutter（鸿蒙构建需 Flutter-OH 工具链）
3. `flutter build apk` / `flutter build windows` / `flutter build hap`

## 免责声明

本项目**仅供学习、研究、技术交流参考使用**。开发者不对使用本项目产生的
任何后果负责，包括但不限于：内容版权问题、数据丢失、设备异常、网络服务
账号风险等。请遵守所在地区法律法规及目标网站服务条款，**使用风险自负**。