#!/bin/bash
# Repro for the v2AwaitCallback main-queue starvation wedge.
# See docs/c11-browser-await-main-wedge.md
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O AwaitDeadlock.swift -o /tmp/c11-awaitrepro
for c in timer mainqueue never; do
  echo "════════ CASE: $c ════════"
  /tmp/c11-awaitrepro "$c" || echo "   exit=$?"
  echo
done

# Real WKWebView delivery, varying only page state. `uncommitted` is the
# production trigger: a view never asked to load has no web process, so the
# completion handler is never invoked at all.
swiftc -O WebKitDelivery.swift -o /tmp/c11-webkitrepro
for c in loaded deadport uncommitted; do
  echo "════════ CASE: $c ════════"
  /tmp/c11-webkitrepro "$c" || echo "   exit=$?"
  echo
done
