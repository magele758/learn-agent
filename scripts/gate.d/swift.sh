# 技术栈适配：Swift Package Manager（Package.swift）。Xcode 工程请在 scripts/gate.local.sh 中用 xcodebuild 覆盖。

swift_detect() { manifest_dirs Package.swift; }

swift_lint() {
  if command -v swiftlint >/dev/null 2>&1 && [ -f .swiftlint.yml ]; then
    echo "  \$ swiftlint --strict"; swiftlint --strict
  else
    echo "  · 未配置 swiftlint（跳过）"
  fi
}

swift_unit() {
  if [ -d Tests ]; then echo "  \$ swift test"; swift test; else echo "  \$ swift build"; swift build; fi
}
