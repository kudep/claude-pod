#!/usr/bin/env bats
# Live end-to-end: Claude Code actually answers a prompt inside the pod, with all
# traffic going through the configured proxy. These hit the real Anthropic API
# (paid), so they run only when you opt in — otherwise they SKIP explicitly:
#
#   CLAUDE_POD_TEST_LIVE=1                     # required — enables the live calls
#   CLAUDE_POD_TEST_PROXY=http://localhost:PORT # optional — force traffic via this proxy
#                                              #   (else the ambient http(s)_proxy is used)
#
# Auth is whatever the host already uses: cpod mounts ~/.claude (credentials ro);
# if there is no credentials file, ANTHROPIC_API_KEY is forwarded instead.
#
#   CLAUDE_POD_TEST_NET_HOST=1                 # optional — run the pod on the host
#                                              #   network so it can reach a host-local
#                                              #   proxy (needed on rootless podman)
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  skip_if_no_image
  require_live
}
teardown() { cpod_cleanup; }

# Distinctive marker so the assertion can't false-positive on incidental text.
MARKER="CPOD_LIVE_7Q9Z"

# Run Claude headlessly in the pod, bounded by a timeout so a hung/blocked network
# call fails the test instead of hanging the whole suite. stderr folded into stdout.
pod_claude() {
  local timeout_s="${2:-120}"
  in_pod "timeout ${timeout_s} claude -p $(printf '%q' "$1") --output-format text 2>&1"
}

@test "live: claude answers a prompt end-to-end (through the configured proxy)" {
  make_project
  setup_test_proxy
  claude_auth_up_args
  nethost_up_args
  CPOD_NO_ATTACH=1 run cpod up --key none "${CPOD_AUTH_ARGS[@]}" "${CPOD_NETHOST_ARGS[@]}"
  [ "$status" -eq 0 ]
  resolve_cname
  # A one-token reply needs no tools, so no permission prompt — deterministic to assert.
  run pod_claude "Reply with exactly this token and nothing else: ${MARKER}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${MARKER}"* ]]
}

@test "live: Claude traffic is routed via the proxy (localhost rewritten to host-gateway)" {
  # Under --net-host the pod reaches the proxy over the shared host loopback, so
  # cpod intentionally does NOT rewrite localhost — this assertion doesn't apply.
  is_net_host && skip "--net-host: proxy reached via shared host loopback (no localhost rewrite)"
  make_project
  setup_test_proxy
  [ -n "${https_proxy:-${http_proxy:-}}" ] \
    || skip "no proxy configured — set CLAUDE_POD_TEST_PROXY or export http(s)_proxy"
  claude_auth_up_args
  CPOD_NO_ATTACH=1 run cpod up --key none "${CPOD_AUTH_ARGS[@]}"
  [ "$status" -eq 0 ]
  resolve_cname
  # The proxy var reached the pod, and a host-local proxy was rewritten to the gateway.
  run in_pod 'echo "${https_proxy:-$http_proxy}"'
  [ -n "$output" ]
  [[ "$output" != *"localhost"* ]]
  [[ "$output" != *"127.0.0.1"* ]]
  # …and Claude still reaches the API over that proxy.
  run pod_claude "Reply with exactly this token and nothing else: ${MARKER}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${MARKER}"* ]]
}

@test "live: with a dead proxy Claude cannot reach the API (no direct bypass)" {
  # Point every proxy var at a refused port. If Claude honored the proxy it fails;
  # if it silently went DIRECT to the API it would still answer — which must NOT
  # happen. (Conclusive only when the host has direct egress; in a proxy-only
  # network the call fails either way, which still satisfies the assertion.)
  make_project
  export http_proxy="http://127.0.0.1:1"  https_proxy="http://127.0.0.1:1"
  export HTTP_PROXY="http://127.0.0.1:1"  HTTPS_PROXY="http://127.0.0.1:1"
  claude_auth_up_args
  nethost_up_args
  CPOD_NO_ATTACH=1 run cpod up --key none "${CPOD_AUTH_ARGS[@]}" "${CPOD_NETHOST_ARGS[@]}"
  [ "$status" -eq 0 ]
  resolve_cname
  run pod_claude "Reply with exactly this token and nothing else: ${MARKER}" 60
  # A blocked request cannot produce the marker; a bypass would. Assert no marker.
  [[ "$output" != *"${MARKER}"* ]]
}
