#!/bin/bash
set -eo pipefail
swiftc Scripts/ci/window-ready.swift -o dist/ci-window-ready
