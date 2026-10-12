TEST_FLAGS := $(shell scripts/test-flags.sh)
SOURCES := Package.swift Sources Tests Apps

.PHONY: build test lint format app release install signing-cert e2e ios ios-install ios-shots clean

build:
	swift build

test:
	LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(TEST_FLAGS)

lint:
	swift format lint --strict --recursive $(SOURCES)

format:
	swift format --in-place --recursive $(SOURCES)

# Dev build: "Canopy Dev.app", data in ~/.canopy-dev.
app:
	scripts/bundle.sh debug dev

# Release build: "Canopy.app", data in ~/.canopy.
release:
	scripts/bundle.sh release release

install: release
	mkdir -p ~/Applications ~/.local/bin
	rm -rf ~/Applications/Canopy.app
	cp -R build/Canopy.app ~/Applications/Canopy.app
	ln -sf ~/Applications/Canopy.app/Contents/Resources/bin/canopy ~/.local/bin/canopy
	@case ":$$PATH:" in *":$$HOME/.local/bin:"*) ;; *) echo "note: add ~/.local/bin to PATH to use canopy outside Canopy";; esac

signing-cert:
	scripts/make-signing-cert.sh

e2e: app
	scripts/e2e.sh
	scripts/e2e-phone.sh
	scripts/e2e-phone-claude.sh
	scripts/e2e-hosts.sh

# The iPhone app, built for the Simulator.
ios:
	xcodebuild -project Apps/CanopyiOS/Canopy.xcodeproj -scheme Canopy -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath build/ios -quiet build

# The iPhone app, signed with your Apple ID's team and installed on the iPhone plugged into this Mac.
ios-install:
	scripts/ios-install.sh $(TEAM)

# Every screen of the iPhone app in the Simulator, in light and dark, against a dev build.
ios-shots: app
	scripts/ios-shots.sh

clean:
	rm -rf .build build
