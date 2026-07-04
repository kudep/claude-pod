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
  [ -n "$TEST_REPO" ] || skip "need CLAUDE_POD_TEST_REPO=owner/repo (mutating GitHub test SKIPPED, not silently)"
  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || skip "gh not authenticated"
  cd "$BATS_TEST_TMPDIR"
  gh repo clone "$TEST_REPO" proj -- -q || skip "could not clone $TEST_REPO"
  cd proj; PROJECT="$PWD"
}

@test "ssh-agent: no private key on the container disk, but push works (rw)" {
  clone_test_repo
  CPOD_NO_ATTACH=1 run cpod up --key rw
  [ "$status" -eq 0 ]
  resolve_cname
  # no key file — delivery is via the agent
  run in_pod "test -f ~/.ssh/id_ed25519"
  [ "$status" -ne 0 ]
  # SSH_AUTH_SOCK is forwarded
  [ -n "$(in_pod 'echo $SSH_AUTH_SOCK')" ]
  # pushing a temp branch works and is then deleted
  in_pod "git checkout -q -b cpod-test-$$ && git commit -q --allow-empty -m cpod-test && git push -q origin cpod-test-$$"
  in_pod "git push -q origin --delete cpod-test-$$"
}

@test "deploy key ro: push is rejected" {
  clone_test_repo
  CPOD_NO_ATTACH=1 run cpod up --key ro
  [ "$status" -eq 0 ]
  resolve_cname
  run in_pod "git commit -q --allow-empty -m x && git push origin HEAD:cpod-ro-$$"
  [ "$status" -ne 0 ]
}

@test "--key-file: key delivered as a file (ro)" {
  clone_test_repo
  CPOD_NO_ATTACH=1 run cpod up --key rw --key-file
  [ "$status" -eq 0 ]
  resolve_cname
  in_pod "test -f ~/.ssh/id_ed25519"
}

@test "isolation: the deploy key grants no access to another repository" {
  clone_test_repo
  CPOD_NO_ATTACH=1 run cpod up --key ro
  [ "$status" -eq 0 ]
  resolve_cname
  # an arbitrary/other repository is inaccessible with this key
  run in_pod "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' git ls-remote git@github.com:github/no-such-cpod-repo.git"
  [ "$status" -ne 0 ]
}
