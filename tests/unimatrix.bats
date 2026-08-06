#!/usr/bin/env bats
# Tests for the ./unimatrix thin router: spec 16's verb -> script dispatch (argv/env passthrough,
# resolving its own dir regardless of caller cwd) plus spec 17's FR-3 `install` and FR-4 `here`
# operator verbs.
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  tests/unimatrix.bats
# Deps:    bats-core, jq (install/here tests)
# Tested:  n/a — this is the test file
#
# Design constraints:
# - The router execs targets via its OWN resolved dir, never $PATH — so PATH shims would not be
#   seen by it. Each dispatch test copies the real ./unimatrix into a scratch "fake-repo" alongside
#   stub swarm-run.sh / swarm-loop.sh / swarm-mon.sh / src/swarm-ctl, and asserts on what each stub
#   recorded to a shared calls.log rather than on real script behavior.
# - Stub log lines are "<basename> argc=<N> args=(<space-joined argv>) BUSDIR=<val>" — argc
#   disambiguates zero args from one empty-string arg, which plain "$*" cannot.
# - FR-3/FR-4 tests (`cmd_install`/`cmd_here`) source a STANDALONE engine copy and call the function
#   directly against a FAKE $HOME tree passed via `env HOME=...` — NEVER the real HOME, never the
#   real ~/.claude*/settings.json. See `_fake_engine` below.

REPO_ROOT="$BATS_TEST_DIRNAME/.."

setup() {
  FAKE="$BATS_TEST_TMPDIR/fake-repo"
  LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$FAKE/src"

  cp "$REPO_ROOT/unimatrix" "$FAKE/unimatrix"
  chmod +x "$FAKE/unimatrix"

  for name in swarm-run.sh swarm-loop.sh swarm-mon.sh; do
    cat > "$FAKE/$name" <<STUB
#!/usr/bin/env bash
printf '%s argc=%s args=(%s) BUSDIR=%s\n' "\$(basename "\$0")" "\$#" "\$*" "\${BUSDIR:-}" >> "$LOG"
exit 0
STUB
    chmod +x "$FAKE/$name"
  done

  cat > "$FAKE/src/swarm-ctl" <<STUB
#!/usr/bin/env bash
printf '%s argc=%s args=(%s) BUSDIR=%s\n' "\$(basename "\$0")" "\$#" "\$*" "\${BUSDIR:-}" >> "$LOG"
exit 0
STUB
  chmod +x "$FAKE/src/swarm-ctl"
}

@test "unimatrix call <lane> <prompt> routes to swarm-run.sh with argv preserved" {
  run "$FAKE/unimatrix" call glm "hi"
  [ "$status" -eq 0 ]
  grep -qF "swarm-run.sh argc=3 args=(call glm hi)" "$LOG"
}

@test "unimatrix run (no further args) routes to swarm-run.sh with a single empty-string arg" {
  run "$FAKE/unimatrix" run
  [ "$status" -eq 0 ]
  grep -qF "swarm-run.sh argc=1 args=()" "$LOG"
}

@test "unimatrix plan <question> routes to swarm-run.sh --plan-only <question>" {
  run "$FAKE/unimatrix" plan "q"
  [ "$status" -eq 0 ]
  grep -qF "swarm-run.sh argc=2 args=(--plan-only q)" "$LOG"
}

@test "unimatrix status / unpark --all route to src/swarm-ctl with argv preserved" {
  run "$FAKE/unimatrix" status
  [ "$status" -eq 0 ]
  grep -qF "swarm-ctl argc=1 args=(status)" "$LOG"

  run "$FAKE/unimatrix" unpark --all
  [ "$status" -eq 0 ]
  grep -qF "swarm-ctl argc=2 args=(unpark --all)" "$LOG"
}

@test "unimatrix loop iterate <id> routes to swarm-loop.sh with the loop prefix stripped" {
  run "$FAKE/unimatrix" loop iterate r1
  [ "$status" -eq 0 ]
  grep -qF "swarm-loop.sh argc=2 args=(iterate r1)" "$LOG"
}

@test "unimatrix mon --render-board routes to swarm-mon.sh with the mon prefix stripped" {
  run "$FAKE/unimatrix" mon --render-board
  [ "$status" -eq 0 ]
  grep -qF "swarm-mon.sh argc=1 args=(--render-board)" "$LOG"
}

@test "unknown verb and no-args fail loudly (rc 2, nothing dispatched); help exits 0" {
  run "$FAKE/unimatrix" bogus-verb
  [ "$status" -eq 2 ]
  [ ! -f "$LOG" ]

  run "$FAKE/unimatrix"
  [ "$status" -eq 2 ]
  [ ! -f "$LOG" ]

  run "$FAKE/unimatrix" help
  [ "$status" -eq 0 ]
}

@test "env passthrough (BUSDIR) and cwd independence: absolute-path invocation from an unrelated dir still routes" {
  OTHERDIR="$BATS_TEST_TMPDIR/elsewhere/sub"
  mkdir -p "$OTHERDIR"
  cd "$OTHERDIR"

  BUSDIR=/tmp/x run "$FAKE/unimatrix" status
  [ "$status" -eq 0 ]
  grep -qF "swarm-ctl argc=1 args=(status) BUSDIR=/tmp/x" "$LOG"
}

# --- P0-FR3: _unimatrix_home — one path-resolution order (plan-004 PRD phase 0) -------------------
# _unimatrix_home is defined at source time and dispatches nothing (the guard at the bottom of
# ./unimatrix only fires when BASH_SOURCE[0] == $0, i.e. when the file is executed, not sourced) —
# each test below sources a STANDALONE copy of ./unimatrix (no sibling swarm-run.sh alongside it,
# unless a test deliberately wants the self-dir branch to win) so only the resolver runs, never
# the CLI dispatch.

@test "_unimatrix_home: \$UNIMATRIX_HOME wins even when a git checkout is also available" {
  local standalone="$BATS_TEST_TMPDIR/standalone"
  mkdir -p "$standalone"
  cp "$REPO_ROOT/unimatrix" "$standalone/unimatrix"

  local home="$BATS_TEST_TMPDIR/uni-home"
  mkdir -p "$home"
  touch "$home/swarm-run.sh"

  run env UNIMATRIX_HOME="$home" bash -c "source '$standalone/unimatrix'; _unimatrix_home"
  [ "$status" -eq 0 ]
  [ "$output" = "$home" ]
}

@test "_unimatrix_home: unset, standalone copy outside any engine dir, but cwd IS a git checkout containing the engine -> git rev-parse wins" {
  local standalone="$BATS_TEST_TMPDIR/standalone2"
  mkdir -p "$standalone"
  cp "$REPO_ROOT/unimatrix" "$standalone/unimatrix"

  local gitrepo="$BATS_TEST_TMPDIR/gitrepo"
  mkdir -p "$gitrepo"
  git init -q "$gitrepo"
  touch "$gitrepo/swarm-run.sh"

  run bash -c "cd '$gitrepo' && unset UNIMATRIX_HOME && source '$standalone/unimatrix' && _unimatrix_home"
  [ "$status" -eq 0 ]
  [ "$output" = "$gitrepo" ]
}

@test "_unimatrix_home: both \$UNIMATRIX_HOME and the git fallback absent -> nonzero, every tried path named in stderr" {
  local standalone="$BATS_TEST_TMPDIR/standalone3"
  mkdir -p "$standalone"
  cp "$REPO_ROOT/unimatrix" "$standalone/unimatrix"

  local outside="$BATS_TEST_TMPDIR/no-repo-here"
  mkdir -p "$outside"

  run bash -c "cd '$outside' && unset UNIMATRIX_HOME && source '$standalone/unimatrix' && _unimatrix_home"
  [ "$status" -ne 0 ]
  [[ "$output" == *'$UNIMATRIX_HOME'* ]]
  [[ "$output" == *"$standalone"* ]]
  [[ "$output" == *"git rev-parse"* ]]
  [[ "$output" == *"not inside a git checkout"* ]]
}

@test "_unimatrix_home: cwd is a FOREIGN git repo (toplevel exists, engine absent) -> nonzero, toplevel named with 'no swarm-run.sh there'" {
  # spec 17 FR-6 test-plan row: dispatch from a real foreign git repo. The git leg must not accept
  # a toplevel just because rev-parse succeeded — the engine check is what rejects it, and the
  # tried-list must say so (this stderr branch had zero coverage before this test).
  local standalone="$BATS_TEST_TMPDIR/standalone-foreign"
  mkdir -p "$standalone"
  cp "$REPO_ROOT/unimatrix" "$standalone/unimatrix"

  local foreign="$BATS_TEST_TMPDIR/foreign-repo"
  mkdir -p "$foreign"
  git init -q "$foreign"

  run bash -c "cd '$foreign' && unset UNIMATRIX_HOME && source '$standalone/unimatrix' && _unimatrix_home"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git rev-parse --show-toplevel"* ]]
  [[ "$output" == *"$(cd "$foreign" && pwd -P)"* ]]
  [[ "$output" == *"no swarm-run.sh there"* ]]
}

@test "#13 _unimatrix_home: a PATH symlink resolves to the real checkout even without readlink -f" {
  # spec 17 FR-3's `unimatrix install` drops a symlink in ~/.local/bin. BSD/macOS readlink has no
  # -f, and falling back to the UNRESOLVED path resolved "self" to the bin dir, not the checkout.
  local engine="$BATS_TEST_TMPDIR/engine13" bindir="$BATS_TEST_TMPDIR/bin13"
  mkdir -p "$engine" "$bindir"
  cp "$REPO_ROOT/unimatrix" "$engine/unimatrix"
  touch "$engine/swarm-run.sh"
  ln -s "$engine/unimatrix" "$bindir/unimatrix"

  # a readlink that rejects -f, exactly like BSD's — the GNU one further down PATH must not save us
  local stub="$BATS_TEST_TMPDIR/stub13"
  mkdir -p "$stub"
  cat > "$stub/readlink" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-f" ] && { echo "readlink: illegal option -- f" >&2; exit 1; }
exec /bin/readlink "$@"
STUB
  chmod +x "$stub/readlink"

  run env PATH="$stub:$PATH" UNIMATRIX_HOME= bash -c \
    "cd / && unset UNIMATRIX_HOME && source '$bindir/unimatrix' && _unimatrix_home"
  [ "$status" -eq 0 ]
  [ "$output" = "$engine" ]
}

@test "#14 sourcing ./unimatrix does not impose set -euo pipefail on the caller's shell" {
  local standalone="$BATS_TEST_TMPDIR/standalone14"
  mkdir -p "$standalone"
  cp "$REPO_ROOT/unimatrix" "$standalone/unimatrix"
  touch "$standalone/swarm-run.sh"

  run bash -c "source '$standalone/unimatrix'
    case \$- in *e*) echo ERREXIT_LEAKED;; esac
    case \$- in *u*) echo NOUNSET_LEAKED;; esac
    shopt -o -q pipefail && echo PIPEFAIL_LEAKED
    shopt -q inherit_errexit && echo INHERIT_ERREXIT_LEAKED
    echo CLEAN"
  [ "$status" -eq 0 ]
  [ "$output" = "CLEAN" ]
}

@test "#14 executing ./unimatrix still runs under set -euo pipefail (the guard moved, not the safety)" {
  run "$FAKE/unimatrix" status
  [ "$status" -eq 0 ]
  grep -qF "swarm-ctl argc=1 args=(status)" "$LOG"
  run grep -c 'set -euo pipefail' "$REPO_ROOT/unimatrix"
  [ "$output" -ge 1 ]
}

@test "_unimatrix_home: sourcing ./unimatrix never runs the dispatcher (no argv, no exit, no side effect)" {
  local standalone="$BATS_TEST_TMPDIR/standalone4"
  mkdir -p "$standalone"
  cp "$REPO_ROOT/unimatrix" "$standalone/unimatrix"
  touch "$standalone/swarm-run.sh"

  run bash -c "source '$standalone/unimatrix'; echo SOURCED_OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED_OK"* ]]
  [[ "$output" != *"usage: unimatrix"* ]]
}

# --- spec 17 FR-3: `unimatrix install` (plan-004 P1-FR3) -------------------------------------------
# cmd_install is defined at source time (same guard as _unimatrix_home) — every test below sources a
# STANDALONE engine copy (a copy of ./unimatrix plus a sibling swarm-run.sh stub, same pattern as
# the _unimatrix_home tests above) and calls cmd_install directly against a FAKE $HOME tree passed
# via `env HOME=...` — never the real HOME. `--dry-run`/settings-refuse assertions never touch
# anything outside $BATS_TEST_TMPDIR.

_fake_engine() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$REPO_ROOT/unimatrix" "$dir/unimatrix"
  touch "$dir/swarm-run.sh"
  cp "$REPO_ROOT/swarm.conf.example" "$dir/swarm.conf.example" 2>/dev/null || true
}

@test "#15 install: fresh fake HOME — symlink, config, and settings.json (incl. an account dir) all get added" {
  local engine="$BATS_TEST_TMPDIR/engine15"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home15"
  mkdir -p "$fakehome/.claude" "$fakehome/.claude-acct/acct1"
  echo '{"someOtherKey": true}' > "$fakehome/.claude/settings.json"
  echo '{"enabledPlugins": {"other@x": true}}' > "$fakehome/.claude-acct/acct1/settings.json"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "source '$engine/unimatrix'; cmd_install"
  [ "$status" -eq 0 ]
  [[ "$output" == *"symlink"*"added"* ]]
  [[ "$output" == *"config"*"added"* ]]
  [[ "$output" == *"settings"*"added"* ]]

  [ -L "$fakehome/.local/bin/unimatrix" ]
  [ "$(readlink "$fakehome/.local/bin/unimatrix")" = "$engine/unimatrix" ]

  grep -qxF "UNIMATRIX_HOME=$engine" "$fakehome/.config/unimatrix/config"
  grep -qE '^ENV_MASTER_FILE=' "$fakehome/.config/unimatrix/config"

  run jq -e --arg p "$engine" '.extraKnownMarketplaces.unimatrix.source.path == $p' "$fakehome/.claude/settings.json"
  [ "$status" -eq 0 ]
  run jq -e '.enabledPlugins["u@unimatrix"] == true' "$fakehome/.claude/settings.json"
  [ "$status" -eq 0 ]
  run jq -e '.someOtherKey == true' "$fakehome/.claude/settings.json"
  [ "$status" -eq 0 ]

  run jq -e '.enabledPlugins["other@x"] == true' "$fakehome/.claude-acct/acct1/settings.json"
  [ "$status" -eq 0 ]
  run jq -e '.enabledPlugins["u@unimatrix"] == true' "$fakehome/.claude-acct/acct1/settings.json"
  [ "$status" -eq 0 ]

  [ -f "$fakehome/.claude/settings.json.bak.unimatrix-install" ]
  [ -f "$fakehome/.claude-acct/acct1/settings.json.bak.unimatrix-install" ]
}

@test "#15 install: second run is idempotent — reports unchanged, settings/config files are byte-identical, backup is not clobbered" {
  local engine="$BATS_TEST_TMPDIR/engine15b"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home15b"
  mkdir -p "$fakehome/.claude"
  echo '{"someOtherKey": true}' > "$fakehome/.claude/settings.json"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "source '$engine/unimatrix'; cmd_install"
  [ "$status" -eq 0 ]

  cp "$fakehome/.claude/settings.json" "$BATS_TEST_TMPDIR/after-run1-settings.json"
  cp "$fakehome/.config/unimatrix/config" "$BATS_TEST_TMPDIR/after-run1-config"
  cp "$fakehome/.claude/settings.json.bak.unimatrix-install" "$BATS_TEST_TMPDIR/orig-backup.json"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "source '$engine/unimatrix'; cmd_install"
  [ "$status" -eq 0 ]
  [[ "$output" == *"symlink"*"unchanged"* ]]
  [[ "$output" == *"config"*"unchanged"* ]]
  [[ "$output" == *"settings"*"unchanged"* ]]

  diff "$fakehome/.claude/settings.json" "$BATS_TEST_TMPDIR/after-run1-settings.json"
  diff "$fakehome/.config/unimatrix/config" "$BATS_TEST_TMPDIR/after-run1-config"
  diff "$fakehome/.claude/settings.json.bak.unimatrix-install" "$BATS_TEST_TMPDIR/orig-backup.json"
}

@test "#15 install: config merge never clobbers a user-set key — only the missing key is added" {
  local engine="$BATS_TEST_TMPDIR/engine15c"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home15c"
  mkdir -p "$fakehome/.config/unimatrix"
  echo 'ENV_MASTER_FILE=/custom/secrets/path' > "$fakehome/.config/unimatrix/config"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "source '$engine/unimatrix'; cmd_install"
  [ "$status" -eq 0 ]

  grep -qxF 'ENV_MASTER_FILE=/custom/secrets/path' "$fakehome/.config/unimatrix/config"
  grep -qxF "UNIMATRIX_HOME=$engine" "$fakehome/.config/unimatrix/config"
}

@test "#15 install: settings mutation is flock-guarded and cleans up its lock file (cross-review finding)" {
  local engine="$BATS_TEST_TMPDIR/engine15g"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home15g"
  mkdir -p "$fakehome/.claude"
  echo '{}' > "$fakehome/.claude/settings.json"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "source '$engine/unimatrix'; cmd_install"
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings"*"added"* ]]
  [ ! -e "$fakehome/.claude/settings.json.lock" ]
}

@test "#15 install --dry-run: writes nothing anywhere but still prints the planned actions" {
  local engine="$BATS_TEST_TMPDIR/engine15d"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home15d"
  mkdir -p "$fakehome/.claude"
  echo '{}' > "$fakehome/.claude/settings.json"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "source '$engine/unimatrix'; cmd_install --dry-run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would add"* ]]

  [ ! -e "$fakehome/.local/bin/unimatrix" ]
  [ ! -e "$fakehome/.config/unimatrix/config" ]
  run jq -e '.enabledPlugins["u@unimatrix"]' "$fakehome/.claude/settings.json"
  [ "$status" -ne 0 ]
}

@test "#15 install: an existing REGULAR FILE at the symlink target is a hard refuse, not overwritten" {
  local engine="$BATS_TEST_TMPDIR/engine15e"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home15e"
  mkdir -p "$fakehome/.local/bin"
  echo 'echo not-unimatrix' > "$fakehome/.local/bin/unimatrix"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "source '$engine/unimatrix'; cmd_install"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [ ! -L "$fakehome/.local/bin/unimatrix" ]
  grep -q 'not-unimatrix' "$fakehome/.local/bin/unimatrix"
}

@test "#15 install --prefix <dir>: symlinks into the given directory instead of ~/.local/bin" {
  local engine="$BATS_TEST_TMPDIR/engine15f"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home15f"
  local prefix="$BATS_TEST_TMPDIR/custom-bin15f"
  mkdir -p "$fakehome"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "source '$engine/unimatrix'; cmd_install --prefix '$prefix'"
  [ "$status" -eq 0 ]
  [ -L "$prefix/unimatrix" ]
  [ ! -e "$fakehome/.local/bin/unimatrix" ]
}

# --- spec 17 FR-4: `unimatrix here` (plan-004 P1-FR4) ----------------------------------------------

@test "#16 here: fresh repo on a local fs — creates .bus, seeds swarm.conf, gitignore, and a fleet.json entry; prints the cockpit URL" {
  local engine="$BATS_TEST_TMPDIR/engine16"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home16"
  mkdir -p "$fakehome"
  local repo="$BATS_TEST_TMPDIR/repo16"
  mkdir -p "$repo"
  local repo_real; repo_real="$(cd "$repo" && pwd -P)"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "cd '$repo' && source '$engine/unimatrix' && cmd_here"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cockpit URL"* ]]
  [[ "$output" == *"4747"* ]]

  [ -d "$repo/.bus/queue" ]
  [ -d "$repo/.bus/claimed" ]
  [ -d "$repo/.bus/done" ]
  [ -d "$repo/.bus/limits" ]
  [ -d "$repo/.bus/loop" ]
  [ -d "$repo/.bus/specs" ]
  [ -f "$repo/swarm.conf" ]
  grep -qxF '.bus*' "$repo/.gitignore"

  local bus_real; bus_real="$(cd "$repo/.bus" && pwd -P)"
  run jq -e --arg r "$repo_real" '.[$r].repo == $r' "$fakehome/.config/unimatrix/fleet.json"
  [ "$status" -eq 0 ]
  run jq -e --arg r "$repo_real" --arg b "$bus_real" '.[$r].bus == $b' "$fakehome/.config/unimatrix/fleet.json"
  [ "$status" -eq 0 ]
  run jq -e --arg r "$repo_real" '.[$r].added | length > 0' "$fakehome/.config/unimatrix/fleet.json"
  [ "$status" -eq 0 ]
}

@test "#16 here: existing swarm.conf/.gitignore are left untouched, and a rerun updates the fleet.json entry in place (no duplicate)" {
  local engine="$BATS_TEST_TMPDIR/engine16b"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home16b"
  mkdir -p "$fakehome"
  local repo="$BATS_TEST_TMPDIR/repo16b"
  mkdir -p "$repo"
  echo 'FANOUT=99' > "$repo/swarm.conf"
  printf 'node_modules/\n.bus*\n' > "$repo/.gitignore"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "cd '$repo' && source '$engine/unimatrix' && cmd_here"
  [ "$status" -eq 0 ]
  grep -qxF 'FANOUT=99' "$repo/swarm.conf"
  grep -qxF 'node_modules/' "$repo/.gitignore"
  [ "$(grep -cxF '.bus*' "$repo/.gitignore")" -eq 1 ]

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "cd '$repo' && source '$engine/unimatrix' && cmd_here"
  [ "$status" -eq 0 ]
  run jq -e 'keys | length == 1' "$fakehome/.config/unimatrix/fleet.json"
  [ "$status" -eq 0 ]
}

@test "#16 here: the engine repo's own pre-existing .bus/ + .bus-*/ gitignore lines already count as covered" {
  local engine="$BATS_TEST_TMPDIR/engine16d"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home16d"
  mkdir -p "$fakehome"
  local repo="$BATS_TEST_TMPDIR/repo16d"
  mkdir -p "$repo"
  printf '.bus/\n.bus-*/\n' > "$repo/.gitignore"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" bash -c "cd '$repo' && source '$engine/unimatrix' && cmd_here"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitignore"*"exists"*"already covered"* ]]
  [ "$(wc -l < "$repo/.gitignore")" -eq 2 ]
}

@test "#16 here: refuses on a non-local filesystem, naming the fstype, and creates nothing" {
  local engine="$BATS_TEST_TMPDIR/engine16c"
  _fake_engine "$engine"
  local fakehome="$BATS_TEST_TMPDIR/home16c"
  mkdir -p "$fakehome"
  local repo="$BATS_TEST_TMPDIR/repo16c"
  mkdir -p "$repo"

  local stub="$BATS_TEST_TMPDIR/stub16c"
  mkdir -p "$stub"
  cat > "$stub/stat" <<'STUB'
#!/usr/bin/env bash
echo "9p"
STUB
  chmod +x "$stub/stat"

  run env -u XDG_CONFIG_HOME HOME="$fakehome" PATH="$stub:$PATH" bash -c "cd '$repo' && source '$engine/unimatrix' && cmd_here"
  [ "$status" -ne 0 ]
  [[ "$output" == *"9p"* ]]

  [ ! -d "$repo/.bus" ]
  [ ! -f "$repo/swarm.conf" ]
  [ ! -f "$repo/.gitignore" ]
  [ ! -f "$fakehome/.config/unimatrix/fleet.json" ]
}

# --- plan 004 P2: `unimatrix report [--html]` -----------------------------------------------------

# _report_engine — the FAKE repo plus the REAL src/speedwars-report.sh and a two-lane fixture
# ledger, so --html renders through the genuine canonical fold but writes into the scratch tree
# (never the real docs/ops/).
_report_engine() {
  cp "$REPO_ROOT/src/speedwars-report.sh" "$FAKE/src/speedwars-report.sh"
  chmod +x "$FAKE/src/speedwars-report.sh"
  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"
  cat > "$LEDGER" <<'LEDGEREOF'
{"ts":"2026-07-25T10:00:00Z","run":"rp","id":"a1","served_lane":"glm","outcome":"done","wall_secs":10,"cost_usd":0.10}
{"ts":"2026-07-25T10:01:00Z","run":"rp","id":"a2","served_lane":"grok","outcome":"done","wall_secs":20,"cost_usd":0.20}
{"type":"verdict","run":"rp","id":"a1","verified":true}
LEDGEREOF
}

@test "unimatrix report <ledger> matches src/speedwars-report.sh run directly" {
  _report_engine
  run "$FAKE/unimatrix" report "$LEDGER"
  [ "$status" -eq 0 ]
  local direct
  direct="$(bash "$REPO_ROOT/src/speedwars-report.sh" "$LEDGER")"
  [ "$output" = "$direct" ]
  # it no longer detours through swarm-ctl
  [ ! -s "$LOG" ]
}

@test "unimatrix report --html writes a self-contained page and prints its path" {
  _report_engine
  run "$FAKE/unimatrix" report --html "$LEDGER"
  [ "$status" -eq 0 ]
  local out="$output"
  [[ "$out" == "$FAKE/docs/ops/report-"*.html ]]
  [ -f "$out" ]
  # lane names from the fold + the embedded --json contract
  grep -q "glm" "$out"
  grep -q "grok" "$out"
  grep -q 'id="fold-json"' "$out"
  grep -q '"cost_per_verified_done"' "$out"
  grep -q '"verified_done": 1' "$out"
  # self-contained: no network references, no external assets
  ! grep -qE 'https?://|src=|<link' "$out"
  grep -q '<style>' "$out"
}

@test "unimatrix report --html is redeployable and passes --run through to the fold" {
  _report_engine
  run "$FAKE/unimatrix" report --html --run rp "$LEDGER"
  [ "$status" -eq 0 ]
  grep -q "glm" "$output"
  run "$FAKE/unimatrix" report --html --run=nosuch "$LEDGER"
  [ "$status" -eq 0 ]
  # an empty fold still renders a page — with no lanes in it
  grep -q 'id="fold-json"' "$output"
  ! grep -q '"glm"' "$output"
}

@test "unimatrix report: a missing report script is a loud rc-2 refusal, not a silent exec" {
  run "$FAKE/unimatrix" report
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing"* ]]
  [[ "$output" == *"speedwars-report.sh"* ]]
}
