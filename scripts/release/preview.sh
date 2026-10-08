#!/bin/bash
# Unnotarized macOS previews; credentials/private signing keys stay in Keychain.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "$root/scripts/release/preview_release.py" "$@"
