# SECURITY — threat model and residual risks

`claude-pod` reduces the damage from a compromised or runaway agent, but it is **not an
absolute sandbox**. Below is what is and isn't protected. Read this before using it on
sensitive machines.

## What is protected (and how)

| Threat | Mechanism |
|---|---|
| Leaking the **main GitHub account's token/keys** | not forwarded: no `~/.ssh`, `~/.config/gh`, `GH_TOKEN`/`*_API_KEY` in the container |
| Agent reaching **other repositories** | the GitHub **deploy key** is bound to one repo; revoked on `down` |
| **Copying** the private key out of the container | ssh-agent forwarding: no key on the container disk (socket only) |
| Corrupting the **Claude token** (`~/.claude/.credentials.json`) | mounted **read-only** |
| Acting as **root on the host** | non-root login user (host uid/gid), podman rootless |
| In-container privilege escalation via **SUID/SGID** | `guarded`/`locked` (or `--no-root`) run with `no-new-privileges` — setuid bits and file caps are ignored. The `default` profile keeps sudo instead (see profiles) |
| Trashing/damaging the **host system** | container FS isolation; only the project dir, `~/.claude` and `~/.claude.json` are visible |

## What is NOT shared (to preempt confusion)

`claude-pod` does **not** bind-mount the host `/tmp`, `~/.ssh`, `~/.gitconfig`, `~/.config/gh`,
or the host home. The container's `/tmp` is its own; git identity is passed as **values only**
(`user.name`/`user.email`), never the host config or credential helpers. The only host paths
visible inside are: the **project directory** (same absolute path), **`~/.claude`**, and
**`~/.claude.json`**. If an audit reports host `/tmp` artifacts or a shared desktop session,
it is not describing a `claude-pod` container.

## Trust profiles

`--profile` presets the flags below to a trust level (any explicit flag still overrides):

| Profile | key | ~/.claude | docker | root (sudo) | intended for |
|---|---|---|---|---|---|
| `default` | rw | rw | auto | **sudo on**, no-new-privileges off | your own code |
| `guarded` | ro | `--claude-hardened` (exec config ro) | off | no sudo, no-new-privileges on | semi-trusted code |
| `locked` | none | `--claude-hardened` | off | no sudo, no-new-privileges on (also `--rm`) | untrusted code |

The **default** profile grants passwordless `sudo` in the pod (for `apt`/setup) — convenient but it
means container-root is reachable (confined to the pod; under rootless podman it maps back to your
host user). `guarded`/`locked` drop sudo and add `no-new-privileges` instead; `--root`/`--no-root`
toggle it directly. A network **egress allowlist is intentionally
not part of any profile** — see residual risk #1.

## Residual risks (important)

1. **The `~/.claude` token is READABLE + egress is open → exfiltration.** `read-only` protects
   against *writing/corruption* but not *reading*, and the pod has working network (it must, to
   reach `api.anthropic.com`). So malicious code / prompt injection could **read and exfiltrate**
   the Claude OAuth token or data. **Why there is no built-in egress allowlist:** a hard block in
   a rootless, capability-dropped, `no-new-privileges` container cannot be done by `claude-pod`
   alone — in-container `iptables` needs `CAP_NET_ADMIN` (dropped), and a docker `--internal`
   network blocks the pod's own proxy path too. A real allowlist needs **host-level firewalling**
   (e.g. `nftables`/`ufw` rules, or a filtering proxy the host enforces). Mitigations: don't run
   untrusted repos unattended; enforce an egress allowlist at the host/network layer; rotate the
   token; prefer a scoped Console API key over the Max OAuth token for untrusted runs.
2. **`~/.claude.json` is mounted rw and READABLE.** It holds Claude Code's main config —
   crucially the **`projects` list**, which reveals your working map (repo paths, client/topic
   names). It also carries `oauthAccount` identity. It is mounted so the pod isn't seen as a
   fresh install (login/onboarding); the tradeoff is this metadata exposure. No real API keys
   live here, but treat the project map as disclosed to anything running in the pod.
3. **`~/.claude` is mounted rw → a host-escalation vector (important).** The hybrid mount shares
   rw not only sessions/history but also **executable configuration**: `settings.json`/
   `settings.local.json` (which define **hooks** and permissions), `plugins/`, `agents/`,
   `skills/`, `commands/`, `hooks/`. A compromised / prompt-injected agent inside the container
   can **legitimately write a malicious hook** that runs **on the host** the next time you launch
   Claude Code outside the container. No escape is required — the access is legitimate.
   Mitigation: the **`--claude-hardened`** flag (implied by `--profile guarded`/`locked`) mounts
   this executable config **read-only** (sessions/projects stay rw). Default is rw (the "all my
   settings" convenience); for untrusted code use a profile or `--claude-hardened`.
4. **The bind-mounted project is written to the host.** Everything the agent changes in the
   project directory lands on the host immediately (by design, for seamless work). Edits outside
   the project are blocked. Note: a `.claude/settings.json` **inside the repo itself** is also a
   hook vector (Claude Code's general project trust model), unrelated to the container.
5. **A write deploy key (`--key rw`, default)** allows **push, including force-push** to *this*
   repository. For auditing untrusted code use `--key ro` or `--key none`.
6. **DinD (`--docker`/auto) = effectively root on the host.** Access to the docker socket lets
   one start a privileged container and reach the host. Enable only for trusted code; auto mode
   prints a warning. The `guarded`/`locked` profiles force it off.
7. **`--net-host`** removes the container's network isolation (shared network with the host, incl.
   its `localhost` services). It is **not** the default: normally the pod is on a bridge network
   and a host-local proxy is reached via the rewritten host-gateway address. Use `--net-host` only
   when the proxy binds to `127.0.0.1` only, or on rootless podman where slirp4netns blocks the
   host-gateway path. Prefer `-p/--port` to expose only specific ports.
8. **`--inherit-env`** widens the surface: all variables are forwarded except the denylist
   (`GH_TOKEN`/`GITHUB_TOKEN`/`*_API_KEY`/`*_SECRET`/`*_TOKEN`/`*_PASSWORD`/`AWS_*` etc.). If your
   secret is named unusually it may leak. Prefer targeted `--env`.
9. **`--key-file`** (fallback) places the private key as a file in the container (ro) — it can be
   copied from inside before revocation. Weaker than ssh-agent; use only when the agent is
   unavailable.
10. **Host / `gh` compromise** is out of scope: `claude-pod` trusts the host `gh` and ssh-agent.

## Recommendations

- Untrusted code → `--profile locked` (or `guarded`); bundles `--key none/ro`, `--claude-hardened`,
  no `--docker`. Add a host-level egress allowlist for unattended untrusted runs.
- Don't leave containers lingering: `cpod down` revokes the key and cleans up state.
- Verify key revocation: `gh api /repos/<owner>/<repo>/keys`.
- For unattended jobs, consider an external egress allowlist at the network/host level.
