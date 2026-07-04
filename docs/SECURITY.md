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
| Acting as **root on the host** | non-root user (host uid/gid), podman rootless |
| Trashing/damaging the **host system** | container FS isolation; only the project dir and `~/.claude` are visible |

## Residual risks (important)

1. **The `~/.claude` token is READABLE inside the container.** `read-only` protects against
   *writing/corruption* but not *reading*. We do **not** enable a network egress filter, so
   malicious code / prompt injection could theoretically **read and exfiltrate** the Claude
   OAuth token. Mitigations: don't run untrusted repositories unattended; add an external
   firewall/allowlist if needed; rotate the token. (An optional `--firewall` is on the roadmap.)
2. **`~/.claude` is mounted rw → a host-escalation vector (important).** The hybrid mount shares
   rw not only sessions/history but also **executable configuration**: `settings.json`/
   `settings.local.json` (which define **hooks** and permissions), `plugins/`, `agents/`,
   `skills/`, `commands/`, `hooks/`. A compromised / prompt-injected agent inside the container
   can **legitimately write a malicious hook** that runs **on the host** the next time you launch
   Claude Code outside the container. No escape is required — the access is legitimate.
   Mitigation: the **`--claude-hardened`** flag mounts this executable config **read-only**
   (sessions/projects stay rw). Default is rw (the "all my settings" convenience); for untrusted
   code use `--claude-hardened`.
3. **The bind-mounted project is written to the host.** Everything the agent changes in the
   project directory lands on the host immediately (by design, for seamless work). Edits outside
   the project are blocked. Note: a `.claude/settings.json` **inside the repo itself** is also a
   hook vector (Claude Code's general project trust model), unrelated to the container.
4. **A write deploy key (`--key rw`, default)** allows **push, including force-push** to *this*
   repository. For auditing untrusted code use `--key ro` or `--key none`.
5. **DinD (`--docker`/auto) = effectively root on the host.** Access to the docker socket lets
   one start a privileged container and reach the host. Enable only for trusted code; auto mode
   prints a warning.
6. **`--net-host`** removes the container's network isolation (shared network with the host).
   Handy for proxying, but the container sees the host's local services. Prefer `-p/--port` to
   expose only specific ports.
7. **`--inherit-env`** widens the surface: all variables are forwarded except the denylist
   (`GH_TOKEN`/`GITHUB_TOKEN`/`*_API_KEY`/`*_SECRET`/`*_TOKEN`/`*_PASSWORD`/`AWS_*` etc.). If your
   secret is named unusually it may leak. Prefer targeted `--env`.
8. **`--key-file`** (fallback) places the private key as a file in the container (ro) — it can be
   copied from inside before revocation. Weaker than ssh-agent; use only when the agent is
   unavailable.
9. **Host / `gh` compromise** is out of scope: `claude-pod` trusts the host `gh` and ssh-agent.

## Recommendations

- Untrusted code → `--key ro` or `--key none`, `--claude-hardened`, no `--docker`, no `--net-host`.
- Don't leave containers lingering: `cpod down` revokes the key and cleans up state.
- Verify key revocation: `gh api /repos/<owner>/<repo>/keys`.
- For unattended jobs, consider an external egress allowlist at the network/host level.
