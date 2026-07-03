#!/usr/bin/env bats
# Deploy-key / git isolation. Tests that mutate GitHub run only when
# CLAUDE_POD_TEST_REPO=owner/repo is set (a throwaway repo you control).
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  skip_if_no_image
  TEST_REPO="${CLAUDE_POD_TEST_REPO:-}"
}
teardown() { cpod_cleanup; }

clone_test_repo() {
  [ -n "$TEST_REPO" ] || skip "нужен CLAUDE_POD_TEST_REPO=owner/repo (мутирующий GitHub-тест ПРОПУЩЕН, не тихо)"
  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || skip "gh не авторизован"
  cd "$BATS_TEST_TMPDIR"
  gh repo clone "$TEST_REPO" proj -- -q || skip "не удалось клонировать $TEST_REPO"
  cd proj; PROJECT="$PWD"
}

@test "ssh-agent: приватного ключа НЕТ на диске контейнера, но push работает (rw)" {
  clone_test_repo
  CPOD_NO_ATTACH=1 run cpod up --key rw
  [ "$status" -eq 0 ]
  resolve_cname
  # ключа-файла быть не должно (доставка через agent)
  run in_pod "test -f ~/.ssh/id_ed25519"
  [ "$status" -ne 0 ]
  # SSH_AUTH_SOCK проброшен
  [ -n "$(in_pod 'echo $SSH_AUTH_SOCK')" ]
  # push временной ветки проходит и затем удаляется
  in_pod "git checkout -q -b cpod-test-$$ && git commit -q --allow-empty -m cpod-test && git push -q origin cpod-test-$$"
  in_pod "git push -q origin --delete cpod-test-$$"
}

@test "deploy key ro: push отклонён" {
  clone_test_repo
  CPOD_NO_ATTACH=1 run cpod up --key ro
  [ "$status" -eq 0 ]
  resolve_cname
  run in_pod "git commit -q --allow-empty -m x && git push origin HEAD:cpod-ro-$$"
  [ "$status" -ne 0 ]
}

@test "--key-file: ключ доставлен файлом (ro)" {
  clone_test_repo
  CPOD_NO_ATTACH=1 run cpod up --key rw --key-file
  [ "$status" -eq 0 ]
  resolve_cname
  in_pod "test -f ~/.ssh/id_ed25519"
}

@test "изоляция: deploy key не даёт доступа к другому репозиторию" {
  clone_test_repo
  CPOD_NO_ATTACH=1 run cpod up --key ro
  [ "$status" -eq 0 ]
  resolve_cname
  # чужой приватный/произвольный репозиторий недоступен этим ключом
  run in_pod "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' git ls-remote git@github.com:github/no-such-cpod-repo.git"
  [ "$status" -ne 0 ]
}
