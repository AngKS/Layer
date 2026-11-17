#!/bin/zsh
# Xcode Cloud runs this after each xcodebuild action. When the action produced an
# App Store-signed app (an archive heading for TestFlight), it writes the build's
# "What to Test" notes from the latest commit subjects. Xcode Cloud reads them from
# TestFlight/WhatToTest.en-US.txt, next to Layer.xcodeproj.
set -eu

if [[ -d "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]]; then
    notes_dir="$CI_PRIMARY_REPOSITORY_PATH/TestFlight"
    mkdir -p "$notes_dir"
    # Xcode Cloud clones shallowly, so fetch a little history first.
    git -C "$CI_PRIMARY_REPOSITORY_PATH" fetch --deepen 10 --quiet || true
    {
        echo "Build $CI_BUILD_NUMBER from ${CI_BRANCH:-main} (${CI_COMMIT:0:7})."
        echo
        git -C "$CI_PRIMARY_REPOSITORY_PATH" log -8 --no-merges --pretty=format:"- %s"
    } > "$notes_dir/WhatToTest.en-US.txt"
fi
