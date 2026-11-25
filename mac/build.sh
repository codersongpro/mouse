#!/bin/bash
# 맥용 ClassZoom을 만든다: build/ClassZoom.app 과 배포용 zip
# Xcode 없이 명령줄 도구(xcode-select --install)만 있으면 된다. GitHub Actions(macOS)에서도 이 스크립트를 쓴다.
#   build.sh            배포용: 애플 실리콘+인텔, zip + SHA-256 (ClassZoom-<버전>-mac.zip)
#   build.sh --quick    고치는 동안: 이 맥의 칩만, 실험 메뉴 포함, zip 없음
#   build.sh --run      --quick으로 만든 뒤 켜져 있던 앱을 끄고 새 앱을 띄운다
set -euo pipefail
cd "$(dirname "$0")"
ROOT=".."
MODE="${1:-release}"
case "$MODE" in release|--release|--quick|--run) ;; *) echo "모르는 옵션: $MODE"; exit 2 ;; esac
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/ClassZoom.app"
ZIP="ClassZoom-$VERSION-mac.zip"

ARCHS="arm64 x86_64"
FLAGS=()
case "$MODE" in --quick|--run) ARCHS=$(uname -m); FLAGS=(-D EXPERIMENTS) ;; esac

mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 애플 실리콘과 인텔 맥 둘 다에서 돌도록 두 번 만들어 하나로 합친다 (macOS 14 이상)
BINS=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" ${FLAGS[@]+"${FLAGS[@]}"} $(find Sources -name "*.swift" | sort) -o "$STAGE/ClassZoom-$arch"
  BINS+=("$STAGE/ClassZoom-$arch")
done
lipo -create -output "$APP/Contents/MacOS/ClassZoom" "${BINS[@]}"
cp Info.plist "$APP/Contents/"

# 그림: 위젯·안내 창의 컬러 아이콘은 두 판이 같이 쓰는 shared/, 메뉴 막대용 단색 그림은 mac/
SHARED="$ROOT/shared"
RES=("$SHARED/icon_capture_color.png" "$SHARED/icon_spotlight_color.png" "$SHARED/icon_draw_color.png" "$SHARED/icon_zoom_color.png"
     "$SHARED/icon_record_color.png" "$SHARED/icon_settings_color.png" icon_menubar.png
     glyphs/glyph_spotlight.png glyphs/glyph_draw.png glyphs/glyph_zoom.png glyphs/glyph_record.png glyphs/glyph_settings.png glyphs/glyph_capture.png)
for f in "${RES[@]}"; do
  [ -f "$f" ] || { echo "빌드 실패: 그림 파일이 없음: $f"; exit 1; }
  cp "$f" "$APP/Contents/Resources/"
done

# 앱 아이콘 (mac/icon-mac.png: 1024 캔버스에 824로 앉힌 맥 규격 그림 → AppIcon.icns)
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon-mac.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon-mac.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 개발자 인증서 없이 "자체 서명"만 한다. 받는 쪽에서 처음 한 번 "그래도 열기"가 필요하다.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
rm -rf build/ClassZoom.app
ditto "$APP" build/ClassZoom.app

if [ "$MODE" = release ] || [ "$MODE" = --release ]; then
  PKG="ClassZoom-$VERSION-mac"
  mkdir -p "$STAGE/pkg/$PKG"
  ditto "$APP" "$STAGE/pkg/$PKG/ClassZoom.app"
  cp "맥용 사용안내.txt" "$STAGE/pkg/$PKG/"
  cp "$ROOT/LICENSE" "$STAGE/pkg/$PKG/LICENSE.txt"
  ditto -c -k --norsrc --keepParent "$STAGE/pkg/$PKG" "$STAGE/$ZIP"
  # 점검: 풀어낸 앱의 서명이 살아 있고 아이콘이 들어 있는지
  mkdir -p "$STAGE/unzipped"
  ditto -x -k "$STAGE/$ZIP" "$STAGE/unzipped"
  codesign --verify --deep --strict "$STAGE/unzipped/$PKG/ClassZoom.app"
  [ -s "$STAGE/unzipped/$PKG/ClassZoom.app/Contents/Resources/AppIcon.icns" ] || { echo "빌드 실패: 앱 아이콘이 없음"; exit 1; }
  rm -f build/ClassZoom-*-mac.zip build/ClassZoom-*-mac.zip.sha256
  cp "$STAGE/$ZIP" build/
  (cd build && shasum -a 256 "$ZIP" | tee "$ZIP.sha256")
  echo "완료: build/ClassZoom.app, 배포용: build/$ZIP"
else
  echo "완료: build/ClassZoom.app ($ARCHS)"
fi

if [ "$MODE" = --run ]; then
  pkill -x ClassZoom 2>/dev/null && sleep 0.5 || true
  open -n build/ClassZoom.app
fi
