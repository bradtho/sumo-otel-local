# Contributing

This document defines how we version `sumo-otel-local` and how commits / pull
requests should be written so release notes and version bumps can eventually be
automated (see the "Release automation" item in [TODO.md](TODO.md)).

## Branching & merge flow

- `dev` is the working branch; `main` is protected and only changes via pull request.
- PRs into `main` are **squash-merged**, so the **PR title becomes the commit subject
  on `main`** (e.g. `… follow-ups … (#4)`). That commit history is what release
  tooling reads — therefore **the PR title is the part that must follow the commit
  convention below.** Individual commits on `dev` are encouraged to follow it too,
  but they are squashed away and are not gating.
- After a squash-merge, `dev` is reset onto `main` so it stays a clean base.

## Commit convention — Conventional Commits

We use [Conventional Commits](https://www.conventionalcommits.org/) so notes and
SemVer bumps can be derived mechanically. The subject is:

```
<type>[optional scope][!]: <description>
```

- Use the imperative mood, lower-case, no trailing period; keep it ≲ 72 chars.
- `!` after the type/scope (or a `BREAKING CHANGE:` footer) marks a breaking change.
- Scope is optional and names the area touched, e.g. `runtime`, `secrets`, `helm`,
  `kind`, `ci`, `docs`.

| Type       | Use for                                              | Release effect       |
| ---------- | ---------------------------------------------------- | -------------------- |
| `feat`     | A user-facing feature (new flag, env knob, command)  | **MINOR** bump       |
| `fix`      | A user-facing bug fix                                | **PATCH** bump       |
| `perf`     | Performance improvement                              | PATCH (if shipped)   |
| `docs`     | Docs only                                            | none                 |
| `refactor` | Code change with no behaviour change                 | none                 |
| `test`     | Tests / verification harnesses only                  | none                 |
| `build`    | Build/dependency/tooling changes                     | none                 |
| `ci`       | CI workflow / pipeline changes                       | none                 |
| `chore`    | Housekeeping that doesn't fit elsewhere              | none                 |
| `style`    | Formatting only (`shfmt`, whitespace)                | none                 |

Anything with `!` / `BREAKING CHANGE:` forces a **MAJOR** bump (see the 0.x note below).

### Examples (drawn from real changes in this repo)

```
feat(runtime): make Docker and Podman both first-class
fix(helm): register sumologic repo before template/upgrade
ci: add mock-deployment render + KinD dry-run job
fix(secrets): stop leaking Sumo credentials on the Helm CLI
feat(cli)!: remove the implicit macOS-only default
```

## Versioning — Semantic Versioning

Releases follow [SemVer](https://semver.org/) and are tagged `vMAJOR.MINOR.PATCH`
(e.g. `v0.4.0`). The "public API" of this project is its **CLI contract**: the
flags, their semantics, the supported platforms/runtimes, the env knobs
(`CONTAINER_RUNTIME`, `MIN_MEM_MB`, `MIN_CPU`, `ASSUME_YES`, `SUMOLOGIC_ACCESS_ID/KEY`,
…), and the default behaviour of each command.

| Bump      | When                                                                              |
| --------- | --------------------------------------------------------------------------------- |
| **MAJOR** | Breaking the CLI contract — removing/renaming a flag, changing a flag's meaning, dropping a platform/runtime, or changing a default such that an existing invocation breaks. |
| **MINOR** | Backwards-compatible features — a new flag, command, env knob, runtime, or platform. |
| **PATCH** | Backwards-compatible bug fixes, plus docs/CI/refactor-only changes.               |

**Pre-1.0 (current `0.x`) caveat:** while the version is `0.y.z` the CLI is still
stabilising. We apply the pragmatic 0.x rule: a **breaking change bumps the MINOR**
(`0.4.z → 0.5.0`) and features/fixes bump the **PATCH** (`0.4.0 → 0.4.1`). Normal
rules apply once we reach `1.0.0`.

### Keep `VERSION` in sync

`sumo-otel-local.sh` carries an embedded `VERSION` constant (used by `-v`, which is
intentionally offline). It must equal the latest release tag **without** the `v`
prefix — e.g. tag `v0.4.0` ⇒ `VERSION="0.4.0"`. Until release automation lands, a
release is cut manually:

1. Open a PR whose title bumps appropriately (e.g. `feat: …` for a MINOR) and update
   `VERSION` in the same PR.
2. Squash-merge to `main`.
3. Tag `vX.Y.Z` on `main` and publish a GitHub Release with generated notes.

Once the release-automation item is done, a tool (e.g. `release-please` or
`git-cliff` + a tag workflow) will derive the bump and notes from the merged commit
subjects, so adherence to the convention above is what makes that possible.
