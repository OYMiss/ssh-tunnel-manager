# SSH Tunnel Manager

一个简单、稳定的 macOS 原生 SwiftUI SSH 隧道管理器，支持本地转发、远程转发和 SOCKS5 动态代理。

填写 SSH 目标和端口即可连接，也可以直接编辑 SSH 命令。支持修改连接名称、托盘快捷开关，以及网络切换和睡眠唤醒后的自动重连。

需要 macOS 14+，认证使用现有 SSH 密钥或 ssh-agent。

## 构建

使用 Xcode 16+ 打开 `SSHTunnelManager/SSHTunnelManager.xcodeproj`，或运行：

```sh
xcodebuild -project SSHTunnelManager/SSHTunnelManager.xcodeproj -scheme SSHTunnelManager -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO
```

MIT License
