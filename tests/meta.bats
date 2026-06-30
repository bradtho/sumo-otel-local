#!/usr/bin/env bats
# Repo-convention guards: cross-file invariants that aren't shell units but would
# silently rot if a contributor edited one file and forgot its sibling. These keep
# the Conventional-Commits machinery (CONTRIBUTING.md ↔ the PR-title lint workflow ↔
# release-please) from drifting apart.

setup() {
    load "test_helper"
    REPO="${BATS_TEST_DIRNAME}/.."
    CONTRIB="${REPO}/CONTRIBUTING.md"
    WF="${REPO}/.github/workflows/pr-title.yml"
}

# The allowed `type` column from CONTRIBUTING.md's commit-convention table. Each row
# starts `| `feat` | …`, so splitting on backticks yields the type in field 2; the
# version/bump tables use `| **MAJOR** |` (no leading backtick) and don't match.
contrib_types() {
    awk -F'`' '/^\| `[a-z]+`/ {print $2}' "$CONTRIB" | sort -u
}

# The types the PR-title workflow accepts: the bare lowercase tokens listed under the
# `types: |` block, stopping at the next YAML key (e.g. `requireScope:`).
workflow_types() {
    awk '
        /^[[:space:]]*types:[[:space:]]*\|/ { grab = 1; next }
        grab {
            if (NF == 1 && $1 ~ /^[a-z]+$/) { print $1; next }
            grab = 0
        }
    ' "$WF" | sort -u
}

@test "meta: PR-title workflow exists and pins the action to a commit SHA" {
    [ -f "$WF" ]
    # SHA-pinned (40-hex) with the human-readable version in a trailing comment, not a
    # mutable @vN/@main tag. A moved tag can't silently change what runs in CI.
    grep -Eq 'uses:[[:space:]]*amannn/action-semantic-pull-request@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' "$WF"
}

@test "meta: every workflow action is pinned to a full 40-char commit SHA" {
    # Supply-chain guard: any third-party action added later with a floating @vN/@branch
    # tag (instead of an immutable SHA) fails here. Local reusable workflows (./...) are
    # exempt. The trailing '# vX.Y.Z' comment is a separate token, so it's ignored.
    local bad
    bad=$(grep -rhoE 'uses:[[:space:]]+[^[:space:]]+' "${REPO}/.github/workflows/" \
        | awk '{print $2}' \
        | grep -vE '^\./' \
        | grep -vE '@[0-9a-f]{40}$' || true)
    if [ -n "$bad" ]; then
        echo "These workflow actions are NOT pinned to a 40-char commit SHA:" >&2
        echo "$bad" >&2
    fi
    [ -z "$bad" ]
}

@test "meta: workflow allowed-types match CONTRIBUTING.md exactly (no drift)" {
    local c w
    c=$(contrib_types)
    w=$(workflow_types)
    # Both sides must be non-empty (guards against a parse that silently matches
    # nothing and then trivially "agrees").
    [ -n "$c" ]
    [ -n "$w" ]
    if [ "$c" != "$w" ]; then
        echo "CONTRIBUTING.md types vs pr-title.yml types differ:" >&2
        diff <(echo "$c") <(echo "$w") >&2 || true
        return 1
    fi
}

@test "meta: workflow triggers on PR title edits (the 'edited' activity type)" {
    # Without `edited`, fixing a bad title would never re-run the check.
    grep -Eq 'types:[[:space:]]*\[[^]]*edited' "$WF"
}

@test "meta: ci.yml cancels superseded runs (concurrency, cancel-in-progress: true)" {
    local ci="${REPO}/.github/workflows/ci.yml"
    grep -Eq '^concurrency:' "$ci"
    grep -Eq 'cancel-in-progress:[[:space:]]*true' "$ci"
}

@test "meta: release-please serializes but never cancels a release (cancel-in-progress: false)" {
    # A release must not be aborted mid-tag/-publish, so it queues rather than cancels.
    local rp="${REPO}/.github/workflows/release-please.yml"
    grep -Eq '^concurrency:' "$rp"
    grep -Eq 'cancel-in-progress:[[:space:]]*false' "$rp"
}
