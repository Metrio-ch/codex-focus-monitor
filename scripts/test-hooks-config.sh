#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
/usr/bin/python3 -m unittest discover -s "$PROJECT_ROOT/Tests/python" -p 'test_*.py'
