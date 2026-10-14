TEST_FLAGS := $(shell scripts/test-flags.sh)
SOURCES := Package.swift Sources Tests Apps

.PHONY: build test linux box box-builder lint format app release install signing-cert e2e ios ios-install ios-shots clean

build:
	swift build

test:
	LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(TEST_FLAGS)

# Docker, as this user, so file permissions hold as they do on a host, with the image `box-builder` makes.
DOCKER_BOX := docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp -v "$(CURDIR)":/src -w /src canopy-box-builder

# The image canopy-box builds in: Swift 6.4.1 with its static Linux SDK, and tmux and git for the tests. Made once.
box-builder:
	@docker image inspect canopy-box-builder >/dev/null 2>&1 || docker build -t canopy-box-builder scripts/box-builder

# The portable modules and canopy-box, built and tested on Linux, apart from the Mac's own build folder.
linux: box-builder
	$(DOCKER_BOX) sh -c 'swift build --scratch-path .build/linux -Xswiftc -warnings-as-errors \
		&& LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --scratch-path .build/linux'

# canopy-box for x86_64 and arm64 Linux hosts: static binaries with nothing to install beside them.
box: box-builder
	$(DOCKER_BOX) sh -c 'set -e; for arch in x86_64 aarch64; do \
		flags="-c release --swift-sdks-path /opt/swift-sdks --swift-sdk $$arch-swift-linux-musl --scratch-path .build/box"; \
		swift build $$flags --product canopy-box -Xswiftc -warnings-as-errors -Xlinker -s; \
		mkdir -p build/box/$$arch && cp "$$(swift build $$flags --show-bin-path)/canopy-box" build/box/$$arch/; \
	done'

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
	scripts/e2e-chat-claude.sh
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
