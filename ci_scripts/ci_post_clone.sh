#!/bin/zsh
# Xcode Cloud runs this after cloning, before resolving packages and building.
#
# Two packages run code at build time: A2UI's build-tool plugin
# (A2UISchemaGeneratorPlugin) and swift-json-schema's macro (JSONSchemaMacro).
# Xcode runs them only after someone has chosen Trust & Enable, and records that
# choice in ~/Library/org.swift.swiftpm/security/plugins.json and macros.json.
# A CI machine has no one to click it, so this copies the records made on a Mac
# where both were trusted.
#
# Each entry names the package, the plugin or macro, and the commit it was trusted
# at (the fingerprint, matching Package.resolved). If either package moves to
# another commit, Xcode Cloud refuses it again until it is trusted at the new
# commit in Xcode and the file is copied here again.
set -eu

security_dir="$HOME/Library/org.swift.swiftpm/security"
mkdir -p "$security_dir"
cp "$CI_PRIMARY_REPOSITORY_PATH/ci_scripts/plugins.json" "$security_dir/plugins.json"
cp "$CI_PRIMARY_REPOSITORY_PATH/ci_scripts/macros.json" "$security_dir/macros.json"
