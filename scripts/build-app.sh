#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
swift build -c release --product StockWidget
task_binary_dir="$(swift build -c release --show-bin-path)"
task_app="${1:-$task_root/dist/StockWidget.app}"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_binary_dir/StockWidget" "$task_app/Contents/MacOS/StockWidget"
cp "$task_root/packaging/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/LICENSE" "$task_app/Contents/Resources/LICENSE"
swift "$task_root/scripts/draw-icon.swift" "$task_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.stockwidget.app "$task_app"
codesign --verify --strict "$task_app"
print "Built: $task_app"
