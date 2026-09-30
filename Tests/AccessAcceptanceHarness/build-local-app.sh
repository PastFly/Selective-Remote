#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
swift test --filter 'CloudAccessTests/deviceCodesHaveLocalizedSafeCopy' >/private/tmp/access-acceptance-build-test.log 2>&1

link_list=.build/out/Intermediates.noindex/SelectiveRemote.build/Debug/SelectiveRemoteTests-p.build/Objects-normal/arm64/SelectiveRemoteTests.LinkFileList
module_object=$(tr ' ' '\n' < "$link_list" | rg '/ExecutableModules/SelectiveRemote--.*-testable\.o$' | head -1)
test -n "$module_object"
module_name=$(basename "$module_object" .o)
module_dir=".build/out/Intermediates.noindex/SelectiveRemote.build/Debug/${module_name}-t.build/Objects-normal/arm64"
bridge_map=.build/out/Intermediates.noindex/GeneratedModuleMaps/PTYBridge.modulemap

swiftc -emit-executable Tests/AccessAcceptanceHarness/main.swift \
  "$module_object" .build/out/Products/Debug/PTYBridge.o \
  -I "$module_dir" -I .build/out/Products/Debug \
  -Xcc "-fmodule-map-file=$bridge_map" -Xcc -I -Xcc Sources/PTYBridge/include \
  -o /private/tmp/AccessAcceptanceHarness

for mode in valid invalid; do
  bundle="/private/tmp/AccessAcceptance-${mode}.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp /private/tmp/AccessAcceptanceHarness "$bundle/Contents/MacOS/AccessAcceptanceHarness"
  cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.selectiveremote.accessacceptance.${mode}</string>
<key>CFBundleName</key><string>Access Acceptance ${mode}</string>
<key>CFBundleExecutable</key><string>AccessAcceptanceHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
done
echo 'Built test-only apps: /private/tmp/AccessAcceptance-valid.app and /private/tmp/AccessAcceptance-invalid.app'
