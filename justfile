set shell := ["bash", "-euc"]

# Native builds stay outside cloud-synced folders (resource forks break signing).
derived_data := env_var_or_default("IOS_DERIVED_DATA", env_var("HOME") + "/Library/Developer/Xcode/DerivedData/MediaCenter")
test_destination := env_var_or_default("IOS_TEST_DESTINATION", "platform=iOS Simulator,name=iPhone 17")
# ssh host of the Mac the phone is paired to; empty = install from this Mac
install_host := env_var_or_default("IOS_INSTALL_HOST", "")

default:
    @just --list

# Regenerate both native Xcode projects from their project.yml specs.
gen:
    XCODEGEN="$(realpath "$(command -v xcodegen)")"; for p in ios macos; do "$XCODEGEN" generate --quiet --spec "apps/$p/project.yml"; done

# Poller + shared Swift model tests; `just test ios` / `just test macos` runs that app's synthetic XCUITest suite.
test *platforms:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{platforms}}" ]; then
      uv run pytest -m "not integration"
      swift test --package-path packages/MediaKit --jobs 2 --scratch-path "{{derived_data}}/MediaKit"
      exit 0
    fi
    just gen
    for p in {{platforms}}; do
      case "$p" in
        ios) destination="{{test_destination}}" ;;
        macos) destination="platform=macOS" ;;
        *) echo "unknown platform '$p' (ios, macos)"; exit 1 ;;
      esac
      xcodebuild -project "apps/$p/MediaCenter.xcodeproj" -scheme MediaCenter \
        -derivedDataPath "{{derived_data}}/$p" -destination "$destination" \
        -resultBundlePath "{{derived_data}}/$p-$(date +%s).xcresult" \
        -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
    done

# All static analysis plus unsigned iPhone Simulator and Mac builds (read-only).
check: gen
    uv run ruff check . && uv run ruff format --check .
    for t in sign_ios_test ios_workflow_test macos_release_test verify_macos_signing_test; do python3 "scripts/$t.py" -q; done
    xcodebuild -project apps/ios/MediaCenter.xcodeproj -scheme MediaCenter -derivedDataPath "{{derived_data}}/ios" \
      -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -quiet build
    xcodebuild -project apps/macos/MediaCenter.xcodeproj -scheme MediaCenter -derivedDataPath "{{derived_data}}/macos" \
      -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -quiet build

fmt:
    uv run ruff format . && uv run ruff check --fix .

# Debug app on the simulator/Mac (`just run ios|macos [--synthetic --test-id <uuid>]`) or one poller ingestion (`just run poller`).
run target="ios" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{target}}" in
      poller) modal run app.py; exit 0 ;;
      ios|macos) just gen ;;
      *) echo "unknown target '{{target}}' (ios, macos, poller)"; exit 1 ;;
    esac
    if [ "{{target}}" = macos ]; then
      xcodebuild -project apps/macos/MediaCenter.xcodeproj -scheme MediaCenter -derivedDataPath "{{derived_data}}/macos" \
        -destination "platform=macOS" -configuration Debug CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -quiet build
      app="{{derived_data}}/macos/Build/Products/Debug/MediaCenter.app"
      open -n "$app" --args {{args}}
      echo "running $app"
      exit 0
    fi
    xcodebuild -project apps/ios/MediaCenter.xcodeproj -scheme MediaCenter -derivedDataPath "{{derived_data}}/ios" \
      -destination "{{test_destination}}" -configuration Debug CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -quiet build
    name=$(printf '%s' "{{test_destination}}" | sed -n 's/.*name=\([^,]*\).*/\1/p')
    id=$(printf '%s' "{{test_destination}}" | sed -n 's/.*id=\([^,]*\).*/\1/p')
    udid=${id:-$(xcrun simctl list devices available --json | jq -r --arg n "$name" '[.devices[][] | select(.name == $n)][0].udid // empty')}
    [ -n "$udid" ] || { echo "no available simulator for '{{test_destination}}' (xcrun simctl list devices)"; exit 1; }
    app="{{derived_data}}/ios/Build/Products/Debug-iphonesimulator/MediaCenter.app"
    bundle=$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl install "$udid" "$app"
    xcrun simctl launch --terminate-running-process "$udid" "$bundle" {{args}} >/dev/null
    echo "bundle=$bundle simulator=$udid"

# Install a verified Ad Hoc .ipa on IOS_DEVICE_ID, from this Mac or through IOS_INSTALL_HOST.
install ipa:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${IOS_DEVICE_ID:?Set IOS_DEVICE_ID to the enrolled device identifier}"
    artifact="$(cd "$(dirname "{{ipa}}")" && pwd)/$(basename "{{ipa}}")"
    cmd="xcrun devicectl device install app --device $IOS_DEVICE_ID"
    if [ -z "{{install_host}}" ]; then
      $cmd "$artifact" && exit 0
    else
      remote="/tmp/$(basename "$artifact")"
      scp -q -o ConnectTimeout=5 "$artifact" "{{install_host}}:/tmp/" \
        && ssh -o ConnectTimeout=5 "{{install_host}}" "$cmd '$remote'; rc=\$?; rm -f '$remote'; exit \$rc" && exit 0
    fi
    echo "install failed: the phone is not reachable over the local network"
    echo "artifact: $artifact"
    echo "  tailnet  just ota $artifact   (install link, one tap, any network)"
    echo "  cable    plug the phone into the paired Mac, then: $cmd '$artifact'"
    exit 1

# Serve a verified .ipa as a tailnet install page (blocks while serving; OTA_TTL seconds, default 900).
ota ipa:
    ./scripts/ota-install.sh "{{ipa}}"

# Stream logs from the deployed poller
logs:
    modal app logs media-center

# The modal CLI rejects process-substitution FIFOs, hence the stdin script.
# Push .env.tpl secrets into the poller's Modal secret store (no plaintext on disk).
sync-secrets:
    op inject -i .env.tpl | uv run scripts/sync_secrets.py media-center

# Poller fallback deploy; normally CI deploys on push to main
deploy: test sync-secrets
    uv run modal deploy app.py
