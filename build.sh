#!/bin/zsh
# 编译 CCUsageBar 并打包成 ~/Applications/CCUsageBar.app
set -e
cd "$(dirname "$0")"

APP=~/Applications/CCUsageBar.app
mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/CCUsageBar" -lsqlite3

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>CCUsageBar</string>
    <key>CFBundleDisplayName</key>       <string>CCUsageBar</string>
    <key>CFBundleIdentifier</key>        <string>local.ccusagebar.CCUsageBar</string>
    <key>CFBundleExecutable</key>        <string>CCUsageBar</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
</dict>
</plist>
EOF

# 屏蔽本地未签名 app 的重复通知
codesign --force --sign - "$APP" 2>/dev/null || true
echo "✅ 已生成 $APP"
