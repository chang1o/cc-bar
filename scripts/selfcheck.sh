#!/bin/sh
# Compiles the UI-free core files together with scripts/selfcheck/main.swift
# and runs the assertions. No Xcode project involvement; swiftc only.
set -eu
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/ccbar-selfcheck"
swiftc -O -o "$out" \
  Core/Providers/Provider.swift \
  Core/Providers/MonitoredAccount.swift \
  Core/Credentials/Models.swift \
  Core/Credentials/CCPMKeystore.swift \
  Core/Quota/QuotaModels.swift \
  Core/Quota/QuotaPace.swift \
  Core/Quota/CodexQuotaClient.swift \
  Core/Quota/ClaudeQuotaClient.swift \
  Core/Quota/KimiQuotaClient.swift \
  Core/Quota/GLMQuotaClient.swift \
  Core/Quota/OllamaCloudQuotaClient.swift \
  scripts/selfcheck/SelfcheckStubs.swift \
  scripts/selfcheck/main.swift
"$out"
