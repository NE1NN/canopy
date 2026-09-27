#!/usr/bin/env bash
# Command Line Tools ship Swift Testing outside the default search paths. Xcode does not need this.
set -euo pipefail
developer_dir=$(xcode-select -p)
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    lib="$developer_dir/Library/Developer"
    echo "-Xswiftc -F -Xswiftc $lib/Frameworks -Xlinker -F -Xlinker $lib/Frameworks -Xlinker -rpath -Xlinker $lib/Frameworks -Xlinker -rpath -Xlinker $lib/usr/lib"
fi
