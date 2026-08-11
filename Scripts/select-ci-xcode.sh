#!/bin/zsh

# Pick an Xcode that can build this package's SPM dependencies.
# PermissionFlow (swift-tools-version 6.2) needs Swift 6.2+.
set -euo pipefail

MIN_MAJOR="${LISTEN_TO_ME_MIN_SWIFT_MAJOR:-6}"
MIN_MINOR="${LISTEN_TO_ME_MIN_SWIFT_MINOR:-2}"

swift_bin_for_developer_dir() {
  local developer_dir="$1"
  local candidate
  for candidate in \
    "$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" \
    "$developer_dir/usr/bin/swift"
  do
    if [[ -x "$candidate" ]]; then
      print -- "$candidate"
      return 0
    fi
  done
  return 1
}

swift_meets_minimum() {
  local developer_dir="$1"
  local swift_bin line major minor
  swift_bin="$(swift_bin_for_developer_dir "$developer_dir")" || return 1

  line="$("$swift_bin" --version 2>/dev/null | head -n 1)"
  if [[ "$line" =~ 'Swift version ([0-9]+)\.([0-9]+)' ]]; then
    major="${match[1]}"
    minor="${match[2]}"
  else
    return 1
  fi

  if (( major > MIN_MAJOR )); then
    return 0
  fi
  if (( major == MIN_MAJOR && minor >= MIN_MINOR )); then
    return 0
  fi
  return 1
}

select_developer_dir() {
  local app developer_dir
  local -a apps
  local -A seen

  apps=(
    /Applications/Xcode_26.3.app
    /Applications/Xcode_26.2.app
    /Applications/Xcode_26.1.1.app
    /Applications/Xcode_26.1.app
    /Applications/Xcode_26.0.1.app
    /Applications/Xcode_26.0.app
    /Applications/Xcode-beta.app
    /Applications/Xcode.app
  )
  apps+=(/Applications/Xcode_26*.app(N))
  apps+=(/Applications/Xcode_27*.app(N))

  for app in "${apps[@]}"; do
    [[ -d "$app" ]] || continue
    [[ -n "${seen[$app]:-}" ]] && continue
    seen[$app]=1
    developer_dir="$app/Contents/Developer"
    if swift_meets_minimum "$developer_dir"; then
      print -- "$developer_dir"
      return 0
    fi
  done
  return 1
}

DEVELOPER_DIR="$(select_developer_dir)" || {
  print -u2 "No Xcode found with Swift ${MIN_MAJOR}.${MIN_MINOR}+."
  print -u2 "Install Xcode 26+ on this machine, or lower a dependency's swift-tools-version."
  ls -d /Applications/Xcode*.app 2>/dev/null || true
  exit 1
}

case "${1:-}" in
  --print)
    print -- "$DEVELOPER_DIR"
    exit 0
    ;;
  --system)
    sudo xcode-select -s "$DEVELOPER_DIR"
    ;;
esac

export DEVELOPER_DIR
print "Using $DEVELOPER_DIR"
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -version
DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift --version
