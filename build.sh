#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="NotNow"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
ARCHIVE_PATH="$ROOT_DIR/build/${SCHEME}.xcarchive"
EXPORT_PATH="$ROOT_DIR/build/export"

echo "==> Building scheme: ${SCHEME} (${CONFIGURATION})"

rm -rf "${DERIVED_DATA_PATH}" "${ARCHIVE_PATH}" "${EXPORT_PATH}"
mkdir -p "${DERIVED_DATA_PATH}" "${EXPORT_PATH}"

xcodebuild \
  -project "${ROOT_DIR}/NotNow.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -archivePath "${ARCHIVE_PATH}" \
  archive
echo "==> Copying .app from archive to ${EXPORT_PATH}"

ARCHIVE_APP_DIR="${ARCHIVE_PATH}/Products/Applications"

if [[ ! -d "${ARCHIVE_APP_DIR}" ]]; then
  echo "ERROR: Archive completed but no Products/Applications directory found in ${ARCHIVE_PATH}" >&2
  exit 1
fi

APP_IN_ARCHIVE="$(find "${ARCHIVE_APP_DIR}" -maxdepth 1 -type d -name '*.app' | head -n 1 || true)"

if [[ -z "${APP_IN_ARCHIVE}" ]]; then
  echo "ERROR: No .app found inside archive at ${ARCHIVE_APP_DIR}" >&2
  exit 1
fi

FINAL_APP_PATH="${EXPORT_PATH}/${SCHEME}.app"
rm -rf "${FINAL_APP_PATH}"
cp -R "${APP_IN_ARCHIVE}" "${FINAL_APP_PATH}"

echo "==> Final app: ${FINAL_APP_PATH}"

