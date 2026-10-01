# Gauge for Codex

Gauge for Codex 是一款独立的原生 macOS 菜单栏额度工具，不绑定 Codex 窗口。

## 体验设计

- 菜单栏默认显示大号本地化百分比和一条细进度条。
- 菜单列出所有可用额度周期，顶部始终显示剩余最少、最需要关注的一档。
- 按系统语言、地区和时区显示倒计时及准确重置日期。
- 启动时、每 60 秒、睡眠唤醒后、额度重置后，以及过期时打开菜单都会自动同步。
- 短暂同步失败时保留上次成功值，超过 5 分钟会明确标记“数据可能已过期”。
- 菜单栏拥挤时可切换“仅百分比”紧凑模式。
- 提供可拖动的小号、中号桌面组件，并根据桌面焦点自动切换系统底色与毛玻璃效果。
- 默认每天检查一次更新，可关闭、手动检查，也支持经校验后自动安装。
- 支持英语、简体中文、日语和西班牙语。
- 支持 macOS 12 及以上系统的 Apple Silicon 与 Intel Mac。
- 不发送遥测数据。

## 数据与兼容性

Gauge for Codex 会短暂启动 Codex 随附的 `codex app-server --stdio`，调用只读方法 `account/rateLimits/read`。解析器优先选择准确的 Codex 额度桶，兼容主要/次要周期及旧版数据结构。

这是本机集成接口，不是公开稳定 API。未来 Codex 更新后可能需要适配；自动同步不可用时仍可手动填写。程序不会读取浏览器 Cookie、聊天正文或账号密码，也不会发起模型生成请求。本工具与 OpenAI 无隶属或背书关系。

## 构建与安装

    cd quota-overlay
    ./build.sh
    ./install.sh

安装位置为 `~/Applications/Gauge for Codex.app`，登录启动项名称为 `com.qingtanlabs.gaugeforcodex`。

桌面组件直接集成在菜单栏进程中，不依赖 Apple 开发者证书或扩展注册；Xcode Command Line Tools 即可完成整个应用的构建和测试。
