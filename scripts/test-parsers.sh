#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun --sdk macosx swiftc -swift-version 5 'TDS Video/Hub/HubModels.swift' tests/ParserTests.swift -o build/parser-tests
build/parser-tests
