set shell := ["bash", "-euo", "pipefail", "-c"]

app := "CodexAPI"
app_bundle := app + ".app"
dist_dir := "dist"

# List available recipes.
default:
    @just --list

# Run the app from SwiftPM.
run:
    swift run {{app}}

# Build a debug binary.
build:
    swift build

# Build a release binary.
release:
    swift build -c release

# Run unit tests.
test:
    swift test

# Build the menu-bar app bundle.
app:
    scripts/build-app.sh

# Build and open the app bundle.
open-app: app
    open -n {{app_bundle}}

# Stop any running app instance.
stop:
    pkill -x {{app}} || true

# Rebuild and restart the app bundle.
restart: app
    pkill -x {{app}} || true
    sleep 1
    open -n {{app_bundle}}

# Build a distributable zip under dist/.
package:
    scripts/package-dist.sh

# Alias for package.
dist: package

# Print local proxy health.
health:
    curl -sS -i http://127.0.0.1:1455/health

# Remove generated build, app, and distribution artifacts.
clean:
    rm -rf .build {{app_bundle}} {{dist_dir}}

