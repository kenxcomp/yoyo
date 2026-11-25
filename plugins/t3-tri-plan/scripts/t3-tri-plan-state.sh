#!/usr/bin/env bash
# t3-tri-plan-state.sh — Portable entrypoint wrapper for t3-tri-plan's Perl core state engine.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
exec perl "$HERE/t3-tri-plan-state.pl" "$@"
