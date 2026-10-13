#!/bin/bash
set -eo pipefail
swiftc Scripts/ci/window-ready.swift -o dist/ci-window-ready
swiftc Scripts/ci/engine-page.swift -o dist/ci-engine-page
