#!/bin/sh
# Tests the sampler logic on Linux/macOS. Optional argument: path to skieogame.exe (to check its fingerprints).
set -e
cd "$(dirname "$0")/tests"
export ASAN_OPTIONS=detect_leaks=0
cc -O1 -g -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=undefined -o /tmp/test_core test_core.c
/tmp/test_core "$@"
