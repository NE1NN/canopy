# Builds canopy-box as static Linux binaries, and runs the portable tests with tmux and git at hand.
# The static Linux SDK is published for Swift 6.4.1, which the swift images do not have, so swiftly installs it.
FROM swift:6.4
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update -q \
    && apt-get install -qy --no-install-recommends tmux git curl ca-certificates gnupg zip unzip \
    && rm -rf /var/lib/apt/lists/*
ENV SWIFTLY_HOME_DIR=/opt/swiftly SWIFTLY_BIN_DIR=/opt/swiftly/bin SWIFTLY_TOOLCHAINS_DIR=/opt/swiftly/toolchains
# swiftly verifies the toolchain's signature. It can exit 1 over a note about other packages after installing, so
# what it installed is checked by running it.
RUN cd /tmp && curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" \
    && tar zxf "swiftly-$(uname -m).tar.gz" \
    && ./swiftly init --quiet-shell-followup --assume-yes --skip-install \
    && { /opt/swiftly/bin/swiftly install 6.4.1 --assume-yes || true; } \
    && rm -rf /tmp/swiftly* \
    && ln -s "$(ls -d /opt/swiftly/toolchains/*6.4.1*)" /opt/swift-6.4.1 \
    && /opt/swift-6.4.1/usr/bin/swift --version 2>&1 | grep -q 'Swift version 6.4.1'
ENV PATH=/opt/swift-6.4.1/usr/bin:$PATH
# Fetched with curl and checked here: swift sdk install's own download can abort as it finishes.
ARG SDK=swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
RUN cd /tmp && curl -fsSLO "https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/$SDK" \
    && echo "cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c  $SDK" | sha256sum -c - \
    && swift sdk install --swift-sdks-path /opt/swift-sdks "/tmp/$SDK" \
    && rm "/tmp/$SDK" \
    && mkdir -p /opt/swift-sdks/configuration \
    && chmod -R a+rX /opt/swiftly /opt/swift-sdks
