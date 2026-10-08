#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd screenshots || exit 0
if [ -f panel.png ]; then
  width=$(sips -g pixelWidth panel.png | awk '/pixelWidth/{print $2}')
  cropw=640; croph=760
  if ! sips -c "$croph" "$cropw" --cropOffset 0 $((width - cropw)) panel.png --out panel-crop.png >/dev/null 2>&1; then
    cp panel.png panel-crop.png
  fi
  sips -Z 560 -s format jpeg -s formatOptions 65 panel-crop.png --out panel.jpg >/dev/null
fi
if [ -f panel-on.png ]; then
  width=$(sips -g pixelWidth panel-on.png | awk '/pixelWidth/{print $2}')
  if ! sips -c 760 640 --cropOffset 0 $((width - 640)) panel-on.png --out panel-on-crop.png >/dev/null 2>&1; then
    cp panel-on.png panel-on-crop.png
  fi
  sips -Z 560 -s format jpeg -s formatOptions 65 panel-on-crop.png --out panel-on.jpg >/dev/null
fi
if [ -f panel-update.png ]; then
  width=$(sips -g pixelWidth panel-update.png | awk '/pixelWidth/{print $2}')
  if ! sips -c 760 640 --cropOffset 0 $((width - 640)) panel-update.png --out panel-update-crop.png >/dev/null 2>&1; then
    cp panel-update.png panel-update-crop.png
  fi
  sips -Z 560 -s format jpeg -s formatOptions 65 panel-update-crop.png --out panel-update.jpg >/dev/null
fi
if [ -f en-panel.png ]; then
  width=$(sips -g pixelWidth en-panel.png | awk '/pixelWidth/{print $2}')
  if ! sips -c 760 640 --cropOffset 0 $((width - 640)) en-panel.png --out en-panel-crop.png >/dev/null 2>&1; then
    cp en-panel.png en-panel-crop.png
  fi
  sips -Z 560 -s format jpeg -s formatOptions 65 en-panel-crop.png --out en-panel.jpg >/dev/null
fi
# 设置窗口居中，裁到窗口附近再缩小，日志里放得下、看得清。
for name in settings sync general extensions upgrade ext-page ext-profiles engine-settings about about-after about-relocate en-profiles en-general en-automation en-sync en-extensions en-about; do
  [ -f "$name.png" ] || continue
  width=$(sips -g pixelWidth "$name.png" | awk '/pixelWidth/{print $2}')
  height=$(sips -g pixelHeight "$name.png" | awk '/pixelHeight/{print $2}')
  cropw=$((width * 9 / 10)); croph=$((height * 17 / 20))
  if ! sips -c "$croph" "$cropw" --cropOffset $((height / 20)) $(((width - cropw) / 2)) "$name.png" --out "$name-crop.png" >/dev/null 2>&1; then
    cp "$name.png" "$name-crop.png"
  fi
  sips -Z 1000 -s format jpeg -s formatOptions 60 "$name-crop.png" --out "$name.jpg" >/dev/null
done
for name in settings sync general extensions upgrade ext-page ext-profiles engine-settings about-after panel panel-on ext-panel about panel-update about-relocate en-panel en-profiles en-general en-automation en-sync en-extensions en-about; do
  [ -f "$name.jpg" ] || continue
  echo "=====BEGIN $name.jpg====="
  base64 -b 76 -i "$name.jpg"
  echo "=====END $name.jpg====="
done
# 菜单栏右半边放大 4 倍，最后打出来，日志末尾一定能看到。
if [ -f desktop.png ]; then
  width=$(sips -g pixelWidth desktop.png | awk '/pixelWidth/{print $2}')
  if sips -c 25 520 --cropOffset 0 $((width - 520)) desktop.png --out menubar-crop.png >/dev/null 2>&1; then
    sips -z 100 2080 menubar-crop.png --out menubar.png >/dev/null
    echo "=====BEGIN menubar.png====="
    base64 -b 76 -i menubar.png
    echo "=====END menubar.png====="
  fi
fi
if [ -f icon-preview.png ]; then
  sips -s format jpeg -s formatOptions 85 icon-preview.png --out icon-preview.jpg >/dev/null
  echo "=====BEGIN icon-preview.jpg====="
  base64 -b 76 -i icon-preview.jpg
  echo "=====END icon-preview.jpg====="
fi
# 签名相关的检查结果放在日志最后，截图再多也看得到。
if [ -f summary.txt ]; then
  echo "::notice title=summary::$(sed 's/%/%25/g' summary.txt | awk '{printf "%s%%0A", $0}')"
  echo "=====BEGIN summary====="
  cat summary.txt
  echo "=====END summary====="
fi
if [ -f "$RUNNER_TEMP/selftest.log" ] && ! [ -f "$RUNNER_TEMP/ci-signing-selftest.passed" ]; then
  echo "=====BEGIN 签名流程自测的最后 60 行====="
  tail -60 "$RUNNER_TEMP/selftest.log"
  echo "=====END 签名流程自测====="
fi
# 自动化页：同样裁出窗口一带缩小，放在后面，日志只看末尾几千行时也在。
# 对每种截图采用同样的处理，当前只需要自动化页。
# shellcheck disable=SC2043
for name in automation; do
  [ -f "$name.png" ] || continue
  width=$(sips -g pixelWidth "$name.png" | awk '/pixelWidth/{print $2}')
  height=$(sips -g pixelHeight "$name.png" | awk '/pixelHeight/{print $2}')
  cw=$(( width < 1000 ? width : 1000 )); ch=$(( height < 700 ? height : 700 ))
  if sips -c "$ch" "$cw" "$name.png" --out "$name-window.png" >/dev/null 2>&1; then
    sips -Z 700 -s format jpeg -s formatOptions 50 "$name-window.png" --out "$name-window.jpg" >/dev/null
    echo "=====BEGIN $name-window.jpg====="
    base64 -b 76 -i "$name-window.jpg"
    echo "=====END $name-window.jpg====="
  fi
done
# 关于页（带赞赏码）：设置窗口在屏幕正中，裁出窗口一带缩小后打在最后。
if [ -f about.png ]; then
  width=$(sips -g pixelWidth about.png | awk '/pixelWidth/{print $2}')
  height=$(sips -g pixelHeight about.png | awk '/pixelHeight/{print $2}')
  cw=$(( width < 1000 ? width : 1000 )); ch=$(( height < 700 ? height : 700 ))
  if sips -c "$ch" "$cw" about.png --out about-window.png >/dev/null 2>&1; then
    sips -Z 700 -s format jpeg -s formatOptions 50 about-window.png --out about-window.jpg >/dev/null
    echo "=====BEGIN about-window.jpg（${width}x${height} 截图的中间 ${cw}x${ch}）====="
    base64 -b 76 -i about-window.jpg
    echo "=====END about-window.jpg====="
  fi
fi
if [ -f "$RUNNER_TEMP/smoke.log" ] && ! [ -f "$RUNNER_TEMP/ci-smoke-zh.passed" ]; then
  echo "=====BEGIN 冒烟测试的最后 80 行====="
  tail -80 "$RUNNER_TEMP/smoke.log"
  echo "=====END 冒烟测试====="
fi
# 更新测试没通过时，把它的最后 100 行放在整个日志的最后。
if [ -f "$RUNNER_TEMP/update.log" ] && ! [ -f "$RUNNER_TEMP/ci-update-e2e.passed" ]; then
  echo "=====BEGIN 更新测试的最后 100 行====="
  tail -100 "$RUNNER_TEMP/update.log"
  echo "=====END 更新测试====="
fi
if [ -f "$RUNNER_TEMP/migration.log" ] && ! [ -f "$RUNNER_TEMP/ci-migration-config.passed" ]; then
  echo "=====BEGIN 迁移测试的最后 80 行====="
  tail -80 "$RUNNER_TEMP/migration.log"
  echo "=====END 迁移测试====="
fi
if [ -f "$RUNNER_TEMP/extension.log" ] && ! [ -f "$RUNNER_TEMP/ci-extension-e2e.passed" ]; then
  echo "=====BEGIN 扩展测试的最后 150 行====="
  tail -150 "$RUNNER_TEMP/extension.log"
  echo "=====END 扩展测试====="
fi
# 没通过的步骤：最后几十行另外做成一条标注，在合并请求的检查页上直接能看到。
for pair in "smoke.log:smoke-zh" "smoke-en.log:smoke-en" "migration.log:migration-config" "extension.log:extension-e2e" "update.log:update-e2e" "legacy.log:rename-e2e" "selftest.log:signing-selftest"; do
  file="$RUNNER_TEMP/${pair%%:*}"
  [ -f "$file" ] || continue
  [ -f "$RUNNER_TEMP/ci-${pair#*:}.passed" ] && continue
  echo "::error title=${pair%%:*}::$(grep -v '^=====\|^[A-Za-z0-9+/=]\{60,\}$' "$file" | cut -c1-240 | tail -40 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
done
if [ -f "$RUNNER_TEMP/legacy.log" ] && ! [ -f "$RUNNER_TEMP/ci-rename-e2e.passed" ]; then
  echo "=====BEGIN 从改名前的版本更新的最后 120 行====="
  tail -120 "$RUNNER_TEMP/legacy.log"
  echo "=====END 从改名前的版本更新====="
fi
