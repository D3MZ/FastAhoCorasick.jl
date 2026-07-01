#!/usr/bin/env bash
# Reproduce the Julia-vs-Rust benchmark end-to-end.
#   ./bench/run.sh [corpus_bytes]
set -euo pipefail
cd "$(dirname "$0")/.."
BYTES="${1:-6000000}"

echo "==> generating corpus ($BYTES bytes)"
julia bench/make_corpus.jl "$BYTES" bench/corpus.txt

echo "==> building native Rust reference (release, lto)"
( cd bench/rust_ref && cargo build --release --quiet )

echo "==> running benchmark"
julia --project=. bench/bench.jl bench/corpus.txt
