#!/bin/bash
set -eo pipefail
for script in Scripts/ci/*.sh; do bash -n "$script"; done
shellcheck -x -S warning Scripts/ci/*.sh
python3 -m unittest discover -s Scripts/ci -p 'test_*.py'
