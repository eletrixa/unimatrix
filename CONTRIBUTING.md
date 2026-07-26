# Contributing

unimatrix is passively maintained — a single-operator bash tool shared because it might
be useful. Contributions are welcome and reviews are best-effort; there is no SLA. Open an
issue before starting a large PR so we can agree on direction first. Small fixes (typos,
one-line bugs, doc corrections) can go straight to a PR.

## The gate — `./check.sh` must be green before anything is done

```bash
./check.sh
```

It runs, in order: `shellcheck -x` on the shell sources, `bats tests/`, and a PII/secret
gate over the tracked content dirs (rejects stray emails not on `.pii-allowlist`, absolute
home paths, employer names, and API-key prefixes). A red gate is not done.

## How we work

- **Spec-driven TDD.** Specs come before code. Read the spec index at
  [`specs/README.md`](specs/README.md) and the project rules in
  [`rules/unimatrix/`](rules/unimatrix/) before touching the bus, spawning a worker, or
  building the loop. Write (or update) the spec first, then a failing `bats` test, then the
  code that makes it pass.
- **File headers.** Every source file carries the header described in
  [`rules/file-headers.md`](rules/file-headers.md). Add it on creation; update it when you
  touch a file whose header has drifted. Bundle header changes with the code change.
- **Changelog.** Every user-facing change gets a `[Unreleased]` entry in `CHANGELOG.md`, in
  the same commit as the change — never a separate commit. Do not bump the version or cut a
  release; only the maintainer does that.

## Licensing of contributions

Unless you explicitly state otherwise, any contribution intentionally submitted for
inclusion shall be dual-licensed as MIT OR Apache-2.0, without additional terms.
