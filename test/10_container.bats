#!/usr/bin/env bats
# Container lifecycle + isolation. Requires the claude-pod:local image (test/run.sh builds it).
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  skip_if_no_image
}
teardown() { cpod_cleanup; }

@test "up создаёт работающий контейнер; проект по идентичному пути; non-root uid хоста" {
  make_project git
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  [ "$("$RT" container inspect -f '{{.State.Running}}' "$CPOD_CNAME")" = "true" ]
  # project mounted at same absolute path
  in_pod "test -f '$PROJECT/README.md'"
  # workdir / path match
  [ "$(in_pod 'pwd')" = "$PROJECT" ]
  # non-root, uid == host uid
  [ "$(in_pod 'id -u')" = "$(id -u)" ]
  [ "$(in_pod 'id -u')" != "0" ]
}

@test "главный процесс — sleep; claude НЕ запущен автоматически" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  # claude binary exists but is not running
  in_pod "command -v claude"
  run in_pod "pgrep -x claude"
  [ "$status" -ne 0 ]
}

@test ".claude гибрид: .credentials.json read-only" {
  # нужен реальный ~/.claude/.credentials.json на хосте
  [ -f "$HOME/.claude/.credentials.json" ] || skip "нет ~/.claude/.credentials.json"
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  run in_pod "echo x >> ~/.claude/.credentials.json"
  [ "$status" -ne 0 ]
}

@test "start после stop переиспользует тот же контейнер" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  cpod stop
  [ "$("$RT" container inspect -f '{{.State.Running}}' "$CPOD_CNAME")" = "false" ]
  CPOD_NO_ATTACH=1 cpod start
  [ "$("$RT" container inspect -f '{{.State.Running}}' "$CPOD_CNAME")" = "true" ]
}

@test "attach = вторая сессия в работающем контейнере" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  # эмулируем attach неинтерактивно
  run "$RT" exec "$CPOD_CNAME" bash -lc 'echo second-session'
  [ "$status" -eq 0 ]
  [[ "$output" == *"second-session"* ]]
}

@test "ls показывает managed-контейнер этого проекта" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  run cpod ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CPOD_CNAME"* ]]
}

@test "down удаляет контейнер и чистит состояние" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  cpod down
  run "$RT" container inspect "$CPOD_CNAME"
  [ "$status" -ne 0 ]
  [ ! -d "$CLAUDE_POD_STATE/containers/$CPOD_CNAME" ]
}

@test "не-репозиторий: up работает без deploy key" {
  make_project           # без git
  CPOD_NO_ATTACH=1 run cpod up
  [ "$status" -eq 0 ]
  [[ "$output" == *"не репозиторий"* ]] || [[ "$output" == *"без deploy key"* ]]
}

@test "toolchain в образе: node, uv, git, rg" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  in_pod "command -v node && command -v uv && command -v git && command -v rg"
}
