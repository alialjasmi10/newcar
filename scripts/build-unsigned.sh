#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
PROJECT='TDS Video.xcodeproj'
SCHEME='TDS Video'
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'This build requires a current macOS/Xcode host. Use the included GitHub Actions workflow.' >&2
  exit 1
fi
xcodebuild -version | tee build/logs/xcode-version.txt
xcodebuild -list -project "$PROJECT" | tee build/logs/project-list.txt
# Test pure import logic before building the application and every embedded extension.
bash scripts/test-parsers.sh 2>&1 | tee build/logs/parser-tests.log
xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath build/SourcePackages 2>&1 | tee build/logs/packages.log
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -sdk iphoneos \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  build 2>&1 | tee build/logs/build.log
APP='build/DerivedData/Build/Products/Release-iphoneos/TDS Video.app'
test -d "$APP"
python3 scripts/verify-product.py "$APP"
# Build output only; never package a simulator .app.
PACKAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/carcast-package.XXXXXX")
trap 'rm -rf "$PACKAGE_DIR"' EXIT
mkdir "$PACKAGE_DIR/Payload"
ditto "$APP" "$PACKAGE_DIR/Payload/TDS Video.app"
ditto -c -k --keepParent "$PACKAGE_DIR/Payload" build/CarCastHub-unsigned.ipa
shasum -a 256 build/CarCastHub-unsigned.ipa > build/CarCastHub-unsigned.ipa.sha256
printf '%s\n' 'Unsigned IPA created. Signing and entitlement compatibility are still required before installation.'
