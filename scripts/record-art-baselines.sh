#!/bin/sh
# Copyright (c) 2026 Colin Tay
# SPDX-License-Identifier: MIT
# Re-records the art baselines in Tests/AgentriseAppTests/Fixtures/art (every PNG plus RECORDED.txt).
# The reference is CI's macOS job: after recording locally, push, and if CI's renders differ, replace the
# fixtures with the "scene-snapshots" artifact's art/ folder. Usage: scripts/record-art-baselines.sh
set -eu
cd "$(dirname "$0")/.."
AGENTRISE_RECORD_ART=1 swift test --filter ArtSnapshotTests
echo "Recorded: Tests/AgentriseAppTests/Fixtures/art ($(ls Tests/AgentriseAppTests/Fixtures/art | grep -c '\.png$') images)"
