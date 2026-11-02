#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
./Scripts/build-app.sh
open "./dist/ReelForge.app"
