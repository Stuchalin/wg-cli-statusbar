VERSION ?= 0.1.0

.PHONY: build release test clean

build:
	swift build

release:
	scripts/build-app.sh $(VERSION)

test:
	swift test

clean:
	swift package clean
	rm -rf build
