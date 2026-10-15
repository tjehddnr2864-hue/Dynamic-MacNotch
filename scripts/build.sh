#!/bin/bash
# Dynamic MacNotch.app 빌드 + 애드혹 서명 (Apple Developer 인증서 불필요)
# Builds "Dynamic MacNotch.app" and ad-hoc signs it (no Apple Developer certificate needed).
#
# 사용법 / Usage: scripts/build.sh [--dev] [--zip] [--install] [--run]
#   --dev      개발용 명령(scripts/notchctl)·진단 로그 포함 / include dev commands & diagnostics
#   --zip      배포용 zip 생성 / create the release zip in build/
#   --install  /Applications 에 설치 / install into /Applications
#   --run      빌드한(또는 설치한) 앱 실행 / launch the app
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Dynamic MacNotch"
EXE="DynamicMacNotch"
BUNDLE_ID="com.dynamicmacnotch.app"
MIN_OS="14.0"

DEV=0; ZIP=0; INSTALL=0; RUN=0
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=1 ;;
    --zip) ZIP=1 ;;
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

SWIFT_FLAGS=(
  -c release --arch arm64
  # 빌드한 컴퓨터의 경로(/Users/...)가 실행 파일에 남지 않게 한다 / keep local paths out of the binary
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
)
[ "$DEV" = 1 ] && SWIFT_FLAGS+=(-Xswiftc -DDEV)
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$EXE" "$APP/Contents/MacOS/$EXE"
strip -x "$APP/Contents/MacOS/$EXE"   # 디버그 심볼 제거 / drop local symbols
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/ko.lproj "$APP/Contents/Resources/"
# MediaRemote 어댑터: Apple 서명 perl에 로드되어 '모든 미디어'의 재생 정보를 읽는다
# MediaRemote adapter: loaded into Apple-signed perl to read now-playing info for any app
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -mmacosx-version-min="$MIN_OS" -framework Foundation \
  -o "$APP/Contents/Resources/libMRAdapter.dylib" Sources/MediaRemoteAdapter/adapter.m
cp Sources/MediaRemoteAdapter/run.pl "$APP/Contents/Resources/mr_run.pl"
# 지정 요구사항을 번들 ID로 고정해, 업데이트해도 macOS 권한(TCC)이 유지되게 한다.
# Pin the designated requirement to the bundle ID so permissions survive updates.
codesign --force --deep --sign - \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --deep --strict "$APP"
echo "빌드 완료 / built: $APP"

if [ "$ZIP" = 1 ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  OUT="build/Dynamic-MacNotch-$VERSION.zip"
  rm -f "$OUT"
  (cd build && ditto -c -k --keepParent "$NAME.app" "$(basename "$OUT")")
  (cd build && shasum -a 256 "$(basename "$OUT")" | tee "$(basename "$OUT").sha256")
fi

if [ "$INSTALL" = 1 ]; then
  pkill -x "$EXE" 2>/dev/null || true
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  APP="/Applications/$NAME.app"
  echo "설치 완료 / installed: $APP"
fi

if [ "$RUN" = 1 ]; then
  pkill -x "$EXE" 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
