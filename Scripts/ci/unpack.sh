#!/bin/bash
set -eo pipefail
tar -xzf "$RUNNER_TEMP/proxi-ci-dist.tar.gz"
codesign --verify --deep --strict dist/Proxi.app
codesign --verify --deep --strict 'dist/Proxi Engine.app'
