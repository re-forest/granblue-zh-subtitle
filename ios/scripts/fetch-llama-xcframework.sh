#!/usr/bin/env bash
set -euo pipefail

# 下載並解壓指定版本的 llama.cpp XCFramework 至 ios/Vendor/llama.xcframework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${IOS_ROOT}/Vendor"
TARGET_XCFRAMEWORK="${VENDOR_DIR}/llama.xcframework"
RELEASE_TAG="b5046"
ARCHIVE_URL="https://github.com/ggml-org/llama.cpp/releases/download/${RELEASE_TAG}/llama-${RELEASE_TAG}-xcframework.zip"
EXPECTED_SHA256="c19be78b5f00d8d29a25da41042cb7afa094cbf6280a225abe614b03b20029ab"

if [ -d "${TARGET_XCFRAMEWORK}" ]; then
  echo "已存在 ${TARGET_XCFRAMEWORK}，略過下載。"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

ARCHIVE_PATH="${TMP_DIR}/llama-${RELEASE_TAG}-xcframework.zip"
echo "正在下載 llama.cpp (${RELEASE_TAG}) XCFramework..."
curl -fL --retry 3 --retry-delay 2 -o "${ARCHIVE_PATH}" "${ARCHIVE_URL}"

ACTUAL_SHA256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
  echo "SHA-256 校驗失敗：預期 ${EXPECTED_SHA256}，實際 ${ACTUAL_SHA256}" >&2
  exit 1
fi

echo "正在解壓 llama.xcframework..."
unzip -q "${ARCHIVE_PATH}" -d "${TMP_DIR}/extracted"

FOUND_XCFRAMEWORK="$(find "${TMP_DIR}/extracted" -maxdepth 4 -type d -name "llama.xcframework" | head -n 1)"
if [ -z "${FOUND_XCFRAMEWORK}" ] || [ ! -d "${FOUND_XCFRAMEWORK}" ]; then
  echo "解壓後找不到 llama.xcframework 目錄。" >&2
  exit 1
fi

mkdir -p "${VENDOR_DIR}"
mv "${FOUND_XCFRAMEWORK}" "${TARGET_XCFRAMEWORK}"
echo "已安裝至 ${TARGET_XCFRAMEWORK}"
