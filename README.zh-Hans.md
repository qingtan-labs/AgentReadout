# AgentReadout

AgentReadout 是一款开源、原生的 macOS 菜单栏工具，集中展示 Codex 与 Claude 的剩余额度、重置时间，以及可用的每日 Token 用量。它曾叫 Gauge for Codex；为保证升级后设置和桌面组件继续可用，内部 bundle ID、URL Scheme 和部分构建路径暂时保留旧名称。

[官网](https://qingtan-labs.github.io/GaugeForCodex/) · [下载最新版本](https://github.com/qingtan-labs/GaugeForCodex/releases/latest) · [English](README.md)

## 功能

- 同时查看 Codex、Claude 的额度周期与会员等级；菜单栏突出最需要关注的一档。进度条默认，环形可选。
- 原生小、中、大号「额度」与「每日 Token」桌面组件（macOS 14+）；macOS 12–13 可使用悬浮组件。
- 每日 Token 使用 Codex 提供的日汇总与累计统计；Claude 仅使用现成客户端缓存。没有数据就显示暂不可用，不另建 Token 历史，也不估算费用。
- 自动刷新、低额度提醒、可选的 24 小时额度趋势，以及自动同步失败时的临时手动额度。
- 界面支持跟随系统外观与语言，也可单独选择；提供简体中文、英语、日语、西班牙语。
- 设置和必要的额度快照保存在本机；不读取对话正文，不发送遥测。

## 安装

从 [GitHub Releases](https://github.com/qingtan-labs/GaugeForCodex/releases/latest) 下载 Universal DMG 或 ZIP。支持 macOS 12 及以上的 Apple 芯片和 Intel Mac。原生 WidgetKit 桌面组件需要 macOS 14 及以上。

发布包采用 ad-hoc 签名，**未经过 Apple 公证**。首次运行如果被 Gatekeeper 拦截，请在系统设置的「隐私与安全性」中确认来源后手动允许。请只从本仓库的 Release 下载并核对随包提供的 SHA-256 校验值。

从源码安装：

```sh
git clone https://github.com/qingtan-labs/GaugeForCodex.git
cd GaugeForCodex/quota-overlay
./install.sh
```

源码安装脚本目前仍使用兼容路径 `~/Applications/Gauge for Codex.app`。新发布的 DMG/ZIP 内应用显示为 `AgentReadout.app`；旧版自动升级会沿用原安装路径，但应用界面名称已更新。登录自启默认关闭，升级保留已有选择。

## 数据来源与隐私

Codex 额度使用本机 Codex 的只读 `account/rateLimits/read` 接口；每日 Token 使用其现有的官方日汇总。Claude 优先读取本机客户端的现成用量缓存，必要且有本机授权时直接向 Anthropic 请求最新额度。外部服务接口可能变化，应用会明确提示同步失败或数据过期，不将缺失数据当成 0。

本项目没有自营账号或后端，也没有遥测、广告 SDK。更新检查访问 GitHub，Claude 实时同步可能访问 Anthropic。详见 [隐私说明](PRIVACY.md) 与 [技术说明](quota-overlay/README.zh-Hans.md)。

AgentReadout 为独立第三方工具，与 OpenAI 或 Anthropic 没有隶属或背书关系。源码与原创图形采用 [MIT 许可证](LICENSE)。
