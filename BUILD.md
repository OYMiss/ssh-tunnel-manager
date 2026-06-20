# Build

## Release 构建（禁用签名）

```bash
xcodebuild -project "SSHTunnelManager/SSHTunnelManager.xcodeproj" \
  -scheme SSHTunnelManager \
  -configuration Release \
  -derivedDataPath "SSHTunnelManager/build" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

产物在 `SSHTunnelManager/build/Build/Products/Release/SSHTunnelManager.app`。

## 快速语法检查（不链接）

```bash
swiftc -parse SSHTunnelManager/SSHTunnelManager/Models/Tunnel.swift \
  SSHTunnelManager/SSHTunnelManager/SSHTunnelManagerApp.swift \
  SSHTunnelManager/SSHTunnelManager/Services/ConfigStore.swift \
  SSHTunnelManager/SSHTunnelManager/Services/TunnelManager.swift \
  SSHTunnelManager/SSHTunnelManager/Views/Components/StatusIndicator.swift \
  SSHTunnelManager/SSHTunnelManager/Views/MainWindow/ContentView.swift \
  SSHTunnelManager/SSHTunnelManager/Views/MainWindow/TunnelDetailView.swift \
  SSHTunnelManager/SSHTunnelManager/Views/MainWindow/TunnelListView.swift \
  SSHTunnelManager/SSHTunnelManager/Views/MenuBar/MenuBarView.swift
```

## CI

`.github/workflows/release.yml` 在推送 `v*` tag 时自动构建、签名并打包 DMG。
