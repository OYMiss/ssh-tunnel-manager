# SSH Tunnel Manager

一个以稳定和简单为目标的 macOS 原生 SwiftUI 菜单栏应用。当前版本 **2.1.1**：选择转发类型，填写 SSH 目标和端口，打开连接开关即可。

## 快速开始

1. 在托盘菜单选择「管理隧道…」，点击「添加隧道」。
2. 选择「本地」「远程」或「动态」，填写 `user@server` 或 `~/.ssh/config` 中的别名。
3. 填写需要的端口，保存后打开连接开关。

SSH 端口可以留空，沿用 SSH 配置或默认端口 22。应用记住连接开关，重新打开应用后会恢复已开启的隧道。

| 类型 | 用途 | 示例 |
| --- | --- | --- |
| 本地 | 在 Mac 上访问服务器侧的服务 | Mac 的 `localhost:8080` → 服务器的 `localhost:80` |
| 远程 | 在服务器上访问 Mac 侧的服务 | 服务器的 `localhost:8080` → Mac 的 `localhost:3000` |
| 动态 | 通过 SSH 服务器提供 SOCKS5 代理 | 在客户端应用中设置 SOCKS5 `127.0.0.1:1080` |

简单配置新建的转发默认监听 `127.0.0.1`。服务地址是从转发另一端访问的地址：本地转发由服务器访问目标服务，远程转发由 Mac 访问目标服务。动态代理需要在使用代理的应用中单独设置。

## 首次连接与手动命令

展开「首次连接帮助」，复制登录命令到终端，确认服务器指纹并检查能否登录。配置好 SSH 密钥或 ssh-agent 后，再打开隧道开关。登录检查会禁用端口转发，可以与已运行的隧道同时使用。

应用沿用现有 SSH 配置、密钥和跳板机，不保存登录密码。需要手动 setup 时在终端完成。

复杂连接可以切换到「手动命令」，例如多个转发、指定密钥、跳板机或其他监听地址：

```sh
# 本地转发
ssh -N -L 127.0.0.1:8080:localhost:80 user@server

# 远程转发
ssh -N -R 127.0.0.1:8080:localhost:3000 user@server

# 动态代理
ssh -N -D 127.0.0.1:1080 my-server

# 使用跳板机和指定密钥
ssh -N -J jump-host -i ~/.ssh/id_ed25519 -L 8080:localhost:80 user@server
```

简单表单和手动编辑共用同一条 SSH 命令。兼容的单端口命令会自动回填表单，并保留原有连接选项和监听地址；复杂命令继续使用手动编辑。未修改配置时保存不会重启连接。

命令通过 `/usr/bin/ssh` 的参数执行，不经过 shell。支持显式 TCP `-L`、`-R`、`-D` 转发及对应的 `-o` 选项；不支持 shell 运算符、远程命令、后台运行或复用控制命令。

## 精简托盘

- 每行只显示「名称 · 端口」，点击即可开关连接。
- 状态通过图标表示，顶部显示已连接数量。
- 悬停查看完整名称、转发类型和错误信息；主窗口保留详细状态。
- 长名称自动缩短，多端口只显示前两个及剩余数量。

界面使用原生菜单、窗口和编辑表单，已移除分组、配置侧边栏及旧自定义弹窗。

## 稳定连接

- 网络路径变化或唤醒后，等待网络稳定再重连；睡眠时暂停连接。
- 每条隧道串行管理进程，旧 SSH 进程组及跳板机子进程退出并回收后，才启动新连接，避免网络切换后旧进程继续占用端口。
- 停止先发送 SIGTERM，500 毫秒后仍未退出则发送 SIGKILL。关闭或删除隧道会同时取消待执行的重试。
- 重试间隔依次为 1、2、4、8、15 秒；SSH 心跳间隔 10 秒，连续 3 次无响应判定失联，连接超时为 10 秒。
- 强制独立前台连接和 `ExitOnForwardFailure=yes`，由应用统一管理心跳、超时与进程生命周期。
- 端口被其他程序占用时显示错误并重试，不按端口号杀死其他程序。
- 多个应用副本共享单实例锁；崩溃恢复会核对 PID、启动时间、可执行文件和进程组后再清理遗留进程。

「已连接」表示 SSH 已进入转发会话，且显式远程转发得到确认，不代表目标服务本身一定健康。

## 配置与升级

配置文件：

```text
~/Library/Application Support/SSHTunnelManager/tunnels.json
```

旧版平铺或分组配置会转换为完整 SSH 命令，保留名称、ID、转发参数和自动连接设置，跳过旧分隔项。首次写入前，原配置会备份到同目录的 `tunnels.before-command-ui.json`。无法读取或解析配置时会报告错误，不会用空列表覆盖原文件。

旧版未保存的临时开启状态需要手动重新开启一次。当前版本会持久化开关状态。已安装应用与 Vibe Page 副本共享同一份用户配置。

## 构建与运行

需要 **macOS 14+、Xcode 16+（Swift 6）**。

```sh
git clone https://github.com/OYMiss/ssh-tunnel-manager.git
cd ssh-tunnel-manager

xcodebuild -project SSHTunnelManager/SSHTunnelManager.xcodeproj \
  -scheme SSHTunnelManager -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO

codesign --force --deep --sign - build/Build/Products/Release/SSHTunnelManager.app
open build/Build/Products/Release/SSHTunnelManager.app
```

构建产物位于 `build/Build/Products/Release/SSHTunnelManager.app`。上面的命令使用本机 ad-hoc 签名。仓库的发布工作流在推送 `v*` 标签时构建、签名并打包 DMG。

## 测试

```sh
swift test
```

测试覆盖三种配置方式、表单与命令转换、参数保留、旧配置迁移、快速开关、网络变化、睡眠唤醒、进程组清理、端口冲突和并行隧道。集成测试使用临时密钥、隔离的本地 sshd 和 HTTP 服务验证实际转发，不连接生产服务器，也不改变 Wi-Fi/VPN 设置。

可选的现有配置兼容性检查：

```sh
SSHTUNNEL_CONFIG_CHECK="$HOME/Library/Application Support/SSHTunnelManager/tunnels.json" swift test
```

该检查复制配置到临时目录后验证，不改写原文件；未设置环境变量时会跳过这一项。

## License

MIT
