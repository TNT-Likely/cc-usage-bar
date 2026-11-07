# CCUsageBar

macOS 菜单栏应用:实时显示 [cc-switch](https://github.com/farion1231/cc-switch) 本地代理的 AI 用量、费用,以及中转站(new-api / sub2api 类)的额度百分比与重置倒计时。

A macOS menu bar app that shows live AI usage & cost from the [cc-switch](https://github.com/farion1231/cc-switch) local proxy, plus relay quota percentage and reset countdown.

纯本地运行:读取 cc-switch 的 SQLite 数据库 + 当前供应商的用量接口,无遥测、无第三方依赖(系统 SQLite + AppKit)。

## 功能

- **菜单栏标题**(单选):额度百分比 / 额度金额 / 今日金额 / 金额+生成令牌 / 生成令牌 / 请求数
- **下拉菜单**:
  - 当前供应商额度:窗口进度条 · 已用/上限/剩余 · 重置时间与倒计时 · 周期内总用量 · 今日用量 · 近 5 天每日明细
  - 本地账目:今日 / 本周 / 本月,按应用、按供应商、模型 Top、最近请求
- 每 20 秒刷新本地账目,每 60 秒刷新额度;唤醒屏幕时自动刷新

## 数据来源

| 数据 | 来源 |
|---|---|
| 本地账目 | `~/.cc-switch/cc-switch.db` 的 `proxy_request_logs`(只读) |
| 额度/重置时间 | 当前 Claude Desktop 供应商的 `/v1/usage` 接口(base URL 与密钥自动取自 cc-switch 数据库,切换供应商自动跟随;接口不可用时自动隐藏) |

本地账目各 app 来源互不重复(`claude-desktop`=proxy、`claude`=session_log、`codex`=codex_session);费用为 cc-switch 按模型定价折算的 USD。

## 构建与运行

需要 macOS 13+ 和 Xcode 命令行工具,无其他依赖:

```bash
./build.sh                                                # 编译并打包到 ~/Applications/CCUsageBar.app
nohup ~/Applications/CCUsageBar.app/Contents/MacOS/CCUsageBar &   # 启动
pkill -f MacOS/CCUsageBar                                 # 停止
```

### 开机自启(LaunchAgent)

已知问题:部分 beta 系统的 LaunchServices 会拒绝通过 `open`/双击启动本地 ad-hoc 签名的 app(报 -10825),直接运行二进制不受影响。建议用 LaunchAgent 常驻:

创建 `~/Library/LaunchAgents/local.ccusagebar.plist`(`/Users/你的用户名` 换成自己的):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.ccusagebar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/你的用户名/Applications/CCUsageBar.app/Contents/MacOS/CCUsageBar</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/tmp/ccusagebar.err.log</string>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ccusagebar.plist   # 加载
launchctl bootout gui/$(id -u)/local.ccusagebar                                  # 卸载
```

## 隐私

- 不联网上传任何数据;唯一的网络请求是查询你自己在 cc-switch 中配置的供应商用量接口
- 密钥只从本地 cc-switch 数据库读取,不会出现在本项目代码中
