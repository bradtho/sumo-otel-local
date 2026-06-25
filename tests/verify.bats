#!/usr/bin/env bats
# Tests for the download integrity helpers (sha256_of / remote_sha256 / verify_sha256).

setup() {
    load "test_helper"
    load_script
    FILE="${BATS_TEST_TMPDIR}/payload"
    printf 'payload-contents\n' >"$FILE"
    GOOD=$(sha256_of "$FILE")
}

@test "sha256_of: produces a 64-hex digest" {
    [[ "$GOOD" =~ ^[0-9a-f]{64}$ ]]
}

@test "verify_sha256: accepts a matching digest" {
    run verify_sha256 "$FILE" "$GOOD" payload
    [ "$status" -eq 0 ]
    [[ "$output" == *"Verified payload checksum."* ]]
    [ -f "$FILE" ]
}

@test "verify_sha256: is case-insensitive about the expected hex" {
    upper=$(printf '%s' "$GOOD" | tr 'a-f' 'A-F')
    run verify_sha256 "$FILE" "$upper" payload
    [ "$status" -eq 0 ]
}

@test "verify_sha256: rejects a mismatch and deletes the file" {
    run verify_sha256 "$FILE" "deadbeef" payload
    [ "$status" -ne 0 ]
    [[ "$output" == *"mismatch"* ]]
    [ ! -f "$FILE" ]
}

@test "verify_sha256: fails closed when no expected digest is given" {
    run verify_sha256 "$FILE" "" payload
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not obtain a checksum"* ]]
}

@test "remote_sha256: selects the matching filename from a multi-entry list" {
    # Stub curl to emit a sha256sum.txt-style listing.
    curl() { printf '%s\n' \
        "1111111111111111111111111111111111111111111111111111111111111111  jq-linux-amd64" \
        "2222222222222222222222222222222222222222222222222222222222222222  jq-macos-arm64"; }
    run remote_sha256 "https://example/sha256sum.txt" "jq-macos-arm64"
    [ "$output" = "2222222222222222222222222222222222222222222222222222222222222222" ]
}

@test "remote_sha256: tolerates a leading '*' (binary marker)" {
    curl() { printf '%s\n' "3333333333333333333333333333333333333333333333333333333333333333 *kind-darwin-arm64"; }
    run remote_sha256 "https://example/checks" "kind-darwin-arm64"
    [ "$output" = "3333333333333333333333333333333333333333333333333333333333333333" ]
}

@test "remote_sha256: without a filename, uses the first field (per-asset .sha256)" {
    curl() { printf '%s\n' "4444444444444444444444444444444444444444444444444444444444444444"; }
    run remote_sha256 "https://example/kubectl.sha256"
    [ "$output" = "4444444444444444444444444444444444444444444444444444444444444444" ]
}
