#!/usr/bin/env bash
# Re-render the README architecture diagrams from their sources in docs/.
# Deps: d2 (https://d2lang.com), python 'diagrams' package (pip install diagrams), graphviz
set -euo pipefail
cd "$(dirname "$0")/.."

d2 --sketch --theme 104 --dark-theme 200 docs/topology.d2 docs/topology.svg
python3 docs/appstack.py
echo "rendered: docs/topology.svg docs/appstack.png"
