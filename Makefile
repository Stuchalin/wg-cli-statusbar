VERSION ?= 0.1.0

.PHONY: build run release test clean

build:
	swift build

run: build
	.build/debug/WGStatusBar

release:
	scripts/build-app.sh $(VERSION)

# CLT ships no XCTest — point SwiftPM at Xcode's toolchain.
test:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

clean:
	swift package clean
	rm -rf build
