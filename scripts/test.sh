#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
test_dir=$(mktemp -d /private/tmp/quotabar-unit-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

swiftc -parse-as-library \
  Sources/QuotaBar/Models.swift \
  Sources/QuotaBar/Protocol.swift \
  Sources/QuotaBar/Services.swift \
  Sources/QuotaBar/CodexAppServerClient.swift \
  Sources/QuotaBar/ClaudeUsageClient.swift \
  Tests/QuotaBarTests/QuotaBarUnitRunner.swift \
  -o "$test_dir/QuotaBarUnitRunner"

"$test_dir/QuotaBarUnitRunner"
