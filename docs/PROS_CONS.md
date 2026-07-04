# PROS & CONS — pros, cons, comparison with alternatives

## Pros of the `claude-pod` approach

- **Narrow GitHub blast radius.** The main account's token never enters the container; instead
  there is a deploy key limited to **one** repository, revoked on `down`. A compromised
  container cannot reach other repositories.
- **The key is not on the container disk.** ssh-agent forwarding: the private key lives in the
  host agent's memory, only the socket goes into the container.
- **Seamless Claude sessions.** The project is mounted at an identical path → `~/.claude/
  projects/<slug>` matches, history/sessions continue on both host and container.
- **A real environment.** Ubuntu/CUDA + Node + uv + compilers, GPU passthrough, DinD when
  needed — what an OS sandbox does not provide.
- **Dual runtime.** podman (rootless, default) and docker; the user chooses.
- **Non-root user** with correct file ownership (host uid/gid).
- **Three explicit scenarios** (up/start/attach) + per-project listing; one-line install; shell
  completions for bash/zsh/fish.
- **Claude does not auto-start** — a shell by default, full control.

## Cons and limitations

- **Image overhead.** The CUDA base is heavy (~GB), the first build is slow (Node/uv/claude are
  pulled from the network). A light base is available: `CPOD_BASE_IMAGE=ubuntu:24.04`.
- **Weaker than an OS sandbox on egress.** We do not enable a default-deny firewall (by choice).
  The `~/.claude` token is **readable** inside (ro only blocks writes), so without a network
  filter exfiltration is theoretically possible. See `SECURITY.md`.
- **DinD and `--net-host` weaken isolation** — enable deliberately.
- **Requires `gh` with write access** to the repo to register the deploy key (otherwise it
  silently works locally).
- **The image is built for a specific host uid/gid** — it does not port to a host with a
  different uid without a rebuild.
- **Podman specifics**: `--userns=keep-id`, socket and GPU (CDI) passthrough may differ from
  docker.

## Comparison with alternatives

| Solution | FS isolation | GitHub access | GPU/environment | `~/.claude` sessions | Note |
|---|---|---|---|---|---|
| **claude-pod** | container, per-project | **per-repo deploy key, auto + revoke** | CUDA/uv, GPU | **seamless (path-match)** | dual podman/docker |
| Official native sandbox (`sandbox-runtime`, bubblewrap/seatbelt) | OS-level, cwd | via a host proxy with scoped creds | no separate environment | n/a | no container, very light |
| Official devcontainer (+`init-firewall.sh`) | container | **recommends** repo-scoped tokens (no automation) | your Dockerfile | volume/`${devcontainerId}` | has an egress firewall |
| Community wrappers (`claudebox`, `Z7Lab`, …) | container | usually host creds/skip-perms | profiles | volume | no per-repo keys |
| Dagger `container-use` | container + git worktree | ordinary git | your image | n/a | for parallel agents |

### When to choose what
- Need a **light** barrier for Bash without a container and with an egress allowlist → the
  official **native sandbox**.
- Need **team reproducibility** in an IDE and an egress firewall → the official **devcontainer**.
- Need **parallel agents** on one repo with worktree branches → **container-use**.
- Need a **full environment (GPU/uv), a narrow per-repo GitHub access out of the box, and
  seamless Claude sessions across several paths** → **claude-pod**.

## Possible improvements (roadmap)
- Optional default-deny egress allowlist (`--firewall`) — closes the residual token-exfiltration
  risk.
- MCP-gateway pattern (token in a separate container) instead of / together with the deploy key.
- Layer cache / a prebuilt image to remove the slow first build.
