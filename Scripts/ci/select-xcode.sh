#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
latest=$(ls -d /Applications/Xcode*.app | sort -V | tail -1)
sudo xcode-select -s "$latest"
xcodebuild -version
swift --version
