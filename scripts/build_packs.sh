#!/bin/bash
# Regenerate every sound pack from the upstream ClickClack recordings.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
python3 Tools/generate_packs.py
