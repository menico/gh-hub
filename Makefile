APPS ?= /Applications

.PHONY: test app install dev probe clean release release-dry
test:
	swift test

app:
	./build.sh

install: app
	rm -rf "$(APPS)/GH Hub.app" "$(APPS)/Hub.app"
	cp -R "build/GH Hub.app" "$(APPS)/GH Hub.app"
	@echo "Installed $(APPS)/GH Hub.app"

dev: app
	open "build/GH Hub.app"

probe:
	swift build && .build/debug/gh-hub --probe

clean:
	rm -rf .build build

release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.2.0"; exit 1; }
	scripts/release.sh "$(VERSION)"

release-dry:
	scripts/release.sh "$$(cat VERSION)" --dry-run
