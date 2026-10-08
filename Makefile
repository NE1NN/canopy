TEST_FLAGS := $(shell scripts/test-flags.sh)
SOURCES := Package.swift Sources Tests

.PHONY: build test lint format app release install signing-cert e2e clean

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
	scripts/e2e-hosts.sh

clean:
	rm -rf .build build
