#!/usr/bin/env bats
# Container lifecycle + isolation. Requires the claude-pod:local image (test/run.sh builds it).
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  skip_if_no_image
}
teardown() { cpod_cleanup; }

@test "up creates a running container; project at the identical path; non-root host uid" {
  make_project git
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  [ "$("$RT" container inspect -f '{{.State.Running}}' "$CPOD_CNAME")" = "true" ]
  # project mounted at the same absolute path
  in_pod "test -f '$PROJECT/README.md'"
  # workdir / path match
  [ "$(in_pod 'pwd')" = "$PROJECT" ]
  # non-root, uid == host uid
  [ "$(in_pod 'id -u')" = "$(id -u)" ]
  [ "$(in_pod 'id -u')" != "0" ]
}

@test "main process is sleep; claude is NOT auto-started" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  # claude binary exists but is not running
  in_pod "command -v claude"
  run in_pod "pgrep -x claude"
  [ "$status" -ne 0 ]
}

@test ".claude hybrid: .credentials.json is read-only" {
  # needs a real ~/.claude/.credentials.json on the host
  [ -f "$HOME/.claude/.credentials.json" ] || skip "no ~/.claude/.credentials.json"
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  run in_pod "echo x >> ~/.claude/.credentials.json"
  [ "$status" -ne 0 ]
}

@test "start after stop reuses the same container" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  cpod stop
  [ "$("$RT" container inspect -f '{{.State.Running}}' "$CPOD_CNAME")" = "false" ]
  CPOD_NO_ATTACH=1 cpod start
  [ "$("$RT" container inspect -f '{{.State.Running}}' "$CPOD_CNAME")" = "true" ]
}

@test "attach = a second session in a running container" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  # emulate attach non-interactively
  run "$RT" exec "$CPOD_CNAME" bash -lc 'echo second-session'
  [ "$status" -eq 0 ]
  [[ "$output" == *"second-session"* ]]
}

@test "ls shows the managed container of this project" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  run cpod ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CPOD_CNAME"* ]]
}

@test "down removes the container and cleans up state" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  cpod down
  run "$RT" container inspect "$CPOD_CNAME"
  [ "$status" -ne 0 ]
  [ ! -d "$CLAUDE_POD_STATE/containers/$CPOD_CNAME" ]
}

@test "non-repository: up works without a deploy key" {
  make_project           # no git
  CPOD_NO_ATTACH=1 run cpod up
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a repository"* ]] || [[ "$output" == *"no deploy key"* ]]
}

@test "image toolchain: node, uv, git, rg" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  in_pod "command -v node && command -v uv && command -v git && command -v rg"
}

@test "default profile: sudo works (root) and no-new-privileges is NOT set" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  # default => --root => passwordless sudo, and no-new-privileges is off (it would block sudo)
  run bash -c "\"$RT\" inspect \"$CPOD_CNAME\" | grep -i no-new-privileges"
  [ "$status" -ne 0 ]
  in_pod 'sudo -n true'
}

@test "--no-root: no-new-privileges is set and sudo is blocked" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none --no-root
  resolve_cname
  run bash -c "\"$RT\" inspect \"$CPOD_CNAME\" | grep -i no-new-privileges"
  [ "$status" -eq 0 ]
  run in_pod 'sudo -n true'
  [ "$status" -ne 0 ]
}

@test "--profile locked hardens ~/.claude executable config (settings.json ro)" {
  [ -f "$HOME/.claude/settings.json" ] || skip "no ~/.claude/settings.json to check"
  make_project
  CPOD_NO_ATTACH=1 run cpod up --profile locked
  [ "$status" -eq 0 ]
  resolve_cname
  # locked => --claude-hardened => settings.json is mounted read-only
  run in_pod 'echo x >> ~/.claude/settings.json'
  [ "$status" -ne 0 ]
}

@test "claude auto-update is disabled and its recorded install path resolves" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  # image ships a pinned claude — it must never self-update inside a pod (avoids the
  # 'broken install' auto-repair that raced the first request into a 403)
  [ "$(in_pod 'echo $DISABLE_AUTOUPDATER')" = "1" ]
  # the native install path (~/.local/bin/claude) points at the real binary
  in_pod 'test -x ~/.local/bin/claude'
}
