#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_macos_ci
# 发布时用 Developer ID 证书签名：这里造一张临时的自签名证书，把导入钥匙串、找证书、签名、校验、启动走一遍。
# 输出另存一份：失败时最后一步把末尾打在日志最后（前面是几万行截图）。
exec > >(tee "$RUNNER_TEMP/selftest.log") 2>&1
work="$RUNNER_TEMP/signing-selftest"
rm -rf "$work" && mkdir -p "$work"
cat > "$work/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Proxi CI Test
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$work/openssl.cnf" -keyout "$work/key.pem" -out "$work/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/cert.p12" -passout pass:ci-test
: > "$work/env"
CERTIFICATE_P12_BASE64="$(base64 -i "$work/cert.p12")" CERTIFICATE_PASSWORD=ci-test GITHUB_ENV="$work/env" Scripts/import-certificate.sh
cat "$work/env"
identity=$(awk -F= '/^CODESIGN_IDENTITY=/{print $2}' "$work/env")
keychain=$(awk -F= '/^CODESIGN_KEYCHAIN=/{print $2}' "$work/env")
[ -n "$identity" ] && [ -n "$keychain" ] || { echo "导入脚本没有给出签名身份和钥匙串"; exit 1; }
CODESIGN_IDENTITY="$identity" CODESIGN_KEYCHAIN="$keychain" VERSION=0.0.0 ARCHS="" THIN_ARCHIVES=1 Scripts/build-app.sh
for app in dist/Proxi.app dist/thin-arm64/Proxi.app; do
  code=$app
    info=$(codesign -dvv "$code" 2>&1)
    echo "$info" | grep -q "Authority=Proxi CI Test" || { echo "$info"; echo "$code 不是用证书签的"; exit 1; }
    echo "$info" | grep -q "flags=.*runtime" || { echo "$info"; echo "$code 没有开 hardened runtime"; exit 1; }
    echo "$info" | grep -q "^Timestamp=" || { echo "$info"; echo "$code 没有安全时间戳"; exit 1; }
done
codesign -dvv dist/Proxi.app 2>&1 | grep -E "^(Authority|Timestamp|TeamIdentifier)=|flags=" | tee -a screenshots/summary.txt
# 用证书签名的程序照样能启动。
dist/Proxi.app/Contents/MacOS/Proxi >/dev/null 2>&1 &
wait_json dist/Proxi.app/Contents/MacOS/Proxi 'has("proxy")'
pgrep -x Proxi >/dev/null || { echo "用证书签名的程序没有在运行"; exit 1; }
stop_app Proxi
security delete-keychain "$keychain"
# 公证脚本的流程：用假的 xcrun（只模拟 notarytool 和 stapler）和假的 spctl 走一遍通过、没通过、没有凭据，
# 以及公证通过但系统检查说没公证（照常发布、记警告）、系统检查因为别的原因不通过（失败）。
fake="$work/fakebin"
mkdir -p "$fake"
cat > "$fake/xcrun" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "notarytool submit") echo '{"id":"00000000-0000-4000-8000-000000000000","message":"Successfully uploaded file"}' ;;
  "notarytool wait") echo "{\"id\":\"$3\",\"status\":\"${FAKE_NOTARY_STATUS:-Accepted}\",\"message\":\"Processing complete\"}" ;;
  "notarytool log") echo '{"issues":[{"message":"fake notary issue"}]}' ;;
  "stapler staple"|"stapler validate") echo "The $2 action worked!" ;;
  *) echo "fake xcrun: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$fake/spctl" <<'EOF'
#!/bin/bash
case "${FAKE_SPCTL:-accepted}" in
  accepted) echo "${@: -1}: accepted"; echo "source=Notarized Developer ID" ;;
  unnotarized) echo "${@: -1}: rejected" >&2; echo "source=Unnotarized Developer ID" >&2; exit 3 ;;
  *) echo "${@: -1}: rejected" >&2; echo "source=no usable signature" >&2; exit 3 ;;
esac
EOF
chmod +x "$fake/xcrun" "$fake/spctl"
cp dist/Proxi-macos-arm64.zip "$work/test.zip"
PATH="$fake:$PATH" NOTARY_APPLE_ID=ci@example.com NOTARY_PASSWORD=x NOTARY_TEAM_ID=ABCDE12345 Scripts/notarize.sh "$work/test.zip"
ditto -x -k "$work/test.zip" "$work/unzipped"
codesign --verify --deep --strict "$work/unzipped/Proxi.app"
if PATH="$fake:$PATH" FAKE_NOTARY_STATUS=Invalid NOTARY_APPLE_ID=ci@example.com NOTARY_PASSWORD=x NOTARY_TEAM_ID=ABCDE12345 \
    Scripts/notarize.sh "$work/test.zip" > "$work/invalid.log" 2>&1; then
  cat "$work/invalid.log"; echo "公证没通过时脚本应该失败"; exit 1
fi
grep -q "fake notary issue" "$work/invalid.log" || { cat "$work/invalid.log"; echo "公证没通过时没有打印苹果的日志"; exit 1; }
if ! PATH="$fake:$PATH" FAKE_SPCTL=unnotarized SPCTL_TRIES=2 SPCTL_INTERVAL=1 NOTARY_APPLE_ID=ci@example.com NOTARY_PASSWORD=x NOTARY_TEAM_ID=ABCDE12345 \
    Scripts/notarize.sh "$work/test.zip" > "$work/unnotarized.log" 2>&1; then
  cat "$work/unnotarized.log"; echo "公证通过、只是系统检查说没公证时应该照常发布"; exit 1
fi
grep -q "::warning::" "$work/unnotarized.log" || { cat "$work/unnotarized.log"; echo "系统检查说没公证时没有记警告"; exit 1; }
if PATH="$fake:$PATH" FAKE_SPCTL=other SPCTL_TRIES=2 SPCTL_INTERVAL=1 NOTARY_APPLE_ID=ci@example.com NOTARY_PASSWORD=x NOTARY_TEAM_ID=ABCDE12345 \
    Scripts/notarize.sh "$work/test.zip" > "$work/rejected.log" 2>&1; then
  cat "$work/rejected.log"; echo "系统检查因为别的原因不通过时脚本应该失败"; exit 1
fi
if Scripts/notarize.sh "$work/test.zip" > "$work/nocreds.log" 2>&1; then
  cat "$work/nocreds.log"; echo "没有公证凭据时脚本应该失败"; exit 1
fi
echo "公证脚本的五种情况都符合预期" | tee -a screenshots/summary.txt
# 公证脚本用到的命令和参数，这个 Xcode 里都有。
for command in submit wait; do
  help=$(xcrun notarytool "$command" --help 2>&1)
  for option in --key --key-id --issuer --apple-id --password --team-id --output-format; do
    echo "$help" | grep -qE -- "${option}( |,|\$)" || { echo "$help"; echo "notarytool ${command} 没有 ${option} 参数"; exit 1; }
  done
done
xcrun notarytool log --help >/dev/null
xcrun --find stapler
echo "签名流程自测通过"

mark_pass signing-selftest
