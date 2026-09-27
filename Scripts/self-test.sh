#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/self-test-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/self-test-cache"
swiftc -sdk "${SDKROOT:-$(xcrun --show-sdk-path)}" -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$PWD/.build/self-test-cache" \
    Sources/ON1Editor/Models.swift \
    Sources/ON1Editor/StyleEngine.swift \
    Sources/ON1Editor/ImagePipeline.swift \
    Sources/ON1Editor/ON1Bridge.swift \
    Tests/SelfTest.swift -o .build/on1-self-test
.build/on1-self-test
