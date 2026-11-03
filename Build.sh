#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec pwsh -NoLogo -NoProfile -File "$script_dir/Build.ps1" "$@"
