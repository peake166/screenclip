#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build/App/Contents/MacOS .build/App/Contents/Resources .build/AppIcon.iconset
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework SwiftUI -framework Translation -framework Vision -framework NaturalLanguage -framework Security -framework ServiceManagement \
  Sources/*.swift \
  -o .build/App/Contents/MacOS/ScreenClip
for icon_size in 16 32 128 256 512; do
  sips -z "$icon_size" "$icon_size" Assets/AppIcon.png --out ".build/AppIcon.iconset/icon_${icon_size}x${icon_size}.png" >/dev/null
  icon_retina=$((icon_size * 2))
  sips -z "$icon_retina" "$icon_retina" Assets/AppIcon.png --out ".build/AppIcon.iconset/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns .build/AppIcon.iconset -o .build/App/Contents/Resources/AppIcon.icns
ditto Resources/ThirdPartyLicenses .build/App/Contents/Resources/ThirdPartyLicenses
cp LICENSE NOTICE.md .build/App/Contents/Resources/
cat > .build/App/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScreenClip</string>
<key>CFBundleIdentifier</key><string>com.local.screenclip</string>
<key>CFBundleName</key><string>截图助手</string>
<key>CFBundleDisplayName</key><string>截图助手</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5.0</string>
<key>CFBundleVersion</key><string>16</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint .build/App/Contents/Info.plist
screenclip_identity="${SCREENCLIP_SIGN_IDENTITY:-}"
if [[ -z "$screenclip_identity" ]]; then
  screenclip_identity=$(security find-identity -v -p codesigning | sed -nE '/"(Apple Development|Developer ID Application):/s/^[[:space:]]*[0-9]+\) ([A-F0-9]{40}).*/\1/p' | head -n 1)
fi
if [[ -z "$screenclip_identity" ]]; then
  print -u2 "No development signing identity found; ad hoc builds require new screen permission after updates."
  screenclip_identity="-"
fi
codesign --force --timestamp=none --sign "$screenclip_identity" .build/App
destination="${1:-dist/截图助手.app}"
ditto .build/App "$destination"
codesign --verify --deep --strict "$destination"
