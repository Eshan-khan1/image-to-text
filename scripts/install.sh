#!/usr/bin/env bash
# Install the local OCR runtime. Safe to run more than once.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  if [ -f "$HOME/.local/bin/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.local/bin/env"
  fi
  export PATH="$HOME/.local/bin:$PATH"
fi

uv venv .venv --python 3.12
spec='mlx-vlm>=0.6.8'
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  spec='mlx-vlm[cpu]>=0.6.8'
fi
uv pip install -U "$spec" jinja2 pypdfium2 --python .venv/bin/python
