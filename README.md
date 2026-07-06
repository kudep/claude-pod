# claude-pod

Run **Claude Code in an isolated container** on top of the current repository — with your
settings and proxy, but **without your main GitHub account's keys or credentials inside the
container**. Instead it creates a dedicated **deploy key** bound to *this one repository*
(registered via `gh`, delivered into the container through ssh-agent — the private key never
lands on the container disk) and **revokes** it when the container is torn down.

Works with both **podman** (default, rootless) and **docker**. The container runs as a
non-root user; the environment is Ubuntu/CUDA + Node (for Claude Code) + `uv` + a build
toolchain. GPU is passed through automatically when available.

Main command — **`cpod`** (alias `claude-pod`).

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/kudep/claude-pod/main/install.sh | bash
```

Installs the scripts into `~/.local/share/claude-pod`, puts `cpod`/`claude-pod` into
`~/.local/bin`, and installs shell completions for bash/zsh/fish. Locally the same:
`git clone … && ./install.sh`.

Re-running the installer upgrades an existing install in place: it detects the old
version, reports it (`updating 0.1.0 -> 0.2.0`), and reinstalls — wiping the previous
managed files first so components dropped in the new version don't linger as leftovers.

## Quick start

From any project directory:

```bash
cpod up        # scenario 1: build the image (once), create a container and enter a shell
# ...inside: a normal shell at the same path as on the host; type `claude`
```

Three lifecycle scenarios:

| Command       | What it does                                                    |
|---------------|-----------------------------------------------------------------|
| `cpod up`     | create a **new** container and enter it (scenario 1)            |
| `cpod start`  | start a **previously created**, stopped container (scenario 2) |
| `cpod attach` | connect to an **already running** container, new session (3)    |
| `cpod restart`| restart this project's container, then enter it                 |
| `cpod exec …` | run a one-off command in the running container (no new one)      |
| `cpod logs`   | show the container's logs (`-f`/`--follow` to stream)           |
| `cpod inspect`| low-level container details (runtime `inspect`)                 |
| `cpod ls`     | list containers for this project (`--all` for every one)        |
| `cpod stop`   | stop the container (without removing it)                        |
| `cpod down`   | stop, remove the container and **revoke the deploy key** (`--volumes` also drops the cache volume) |
| `cpod prune`  | remove **stopped** cpod containers (this project, or `--all`), revoking their keys |

With no argument, `cpod` picks the mode itself: no container → `up`, stopped → `start`,
running → `attach`.

## Git access modes (deploy key)

```bash
cpod up --key rw     # default: push ALLOWED, but only to this one repository
cpod up --key ro     # read-only: push is rejected
cpod up --key none   # no key: work on the local copy only
cpod up --key-file   # deliver the key as a file (ro) instead of ssh-agent
```

If the directory is not a git repo or `origin` is not on GitHub, the key block is simply
skipped and the container still starts (git works locally).

## Trust profiles

`--profile` presets the security-relevant flags to a trust level; any explicit flag still
overrides the preset.

```bash
cpod up --profile default   # (default) key rw, ~/.claude rw, docker auto, sudo ON — your own code
cpod up --profile guarded   # key ro, --claude-hardened, no docker, sudo OFF — semi-trusted code
cpod up --profile locked    # key none, --claude-hardened, no docker, --rm, sudo OFF — untrusted code
cpod up --profile locked --key ro    # profiles are just defaults — override any flag
```

The **default** profile gives you passwordless `sudo` inside the pod (handy for `apt`/setup).
`guarded`/`locked` drop it and add `no-new-privileges` (SUID can't escalate) instead; toggle
directly with `--root`/`--no-root`. Profiles do **not** include a network egress allowlist —
see [weak sides](#weak-sides--what-it-does-not-protect).

## Handy flags

```bash
cpod up --claude               # run claude right away (default is just a shell)
cpod up --run "pytest -q"      # run a command on entry
cpod up --claude-hardened      # ~/.claude: settings/plugins/hooks ro (protect host from a planted hook)
cpod up --inherit-env          # forward all host variables (except secrets)
cpod up --env FOO=bar          # forward a single variable
cpod up -p 8080:80             # publish a port (docker-style); repeatable
cpod up -p 127.0.0.1:5432:5432/tcp
cpod up -v ~/datasets:/data:ro # extra bind mount or named volume (docker-style); repeatable
cpod up -v models:/models      # a named volume (auto-created)
cpod up --cache-volume         # persistent per-project ~/.cache (survives recreation)
cpod up --rm                   # remove the container when the session ends (ephemeral)
cpod up --root / --no-root     # passwordless sudo in the pod (default) / harden with no-new-privileges
cpod up --proxy                # forward the host http(s)_proxy into the pod (OFF by default)
cpod up --net-host             # host network (needed for a localhost proxy on rootless podman; weakens isolation)
cpod up --gpu / --no-gpu       # force GPU on/off (default: autodetect)
cpod up --docker / --no-docker # docker socket passthrough (default: auto per project)
cpod up --runtime docker       # pick the runtime manually
```

### Publishing ports vs host network

Prefer `-p/--port` when you only want specific ports reachable — it keeps the container on
its own network and publishes just those ports (exactly like `docker run -p`). Use
`--net-host` only when you want the container to share the host's whole network stack (e.g.
to reach a `localhost` proxy directly); `-p` is ignored in that mode.

### Volumes

`-v/--volume` takes docker-style specs — a host path (`~/data:/data:ro`) or a **named
volume** (`models:/models`, auto-created). Any `-v` weakens isolation, so mounting sensitive
host paths (`/`, `/etc`, `~/.ssh`, a docker socket) prints a warning; use `--docker` for the
daemon rather than bind-mounting its socket.

`--cache-volume` mounts a persistent per-project named volume at `~/.cache`, so package
caches (uv/pip/npm) survive `down` + recreate — a big speed-up when you rebuild pods often.
Named volumes are kept by `down`; add `--volumes` to drop the cache volume too, or use
`cpod prune` to bulk-remove stopped containers.

### Proxies

Proxy forwarding is **opt-in**: by default the pod uses its own direct network (best for
`apt`/`git`/setup). Pass **`--proxy`** to forward the host `http(s)_proxy`/`no_proxy`, with
`localhost`/`127.0.0.1` rewritten to the container's host-gateway so a host-local proxy stays
reachable. Since Claude's API is **HTTPS**, if the host defines only `http_proxy`, cpod mirrors
it onto `https_proxy` inside the pod — so a single HTTP proxy that also does `CONNECT` just works.

Why opt-in: an unreachable forwarded proxy silently breaks the pod's network. On **rootless
podman** a host-`localhost` proxy is unreachable from a bridge pod (slirp) — cpod warns, and you
need `--net-host`; on docker the proxy must listen on a routable address (e.g. `0.0.0.0`) to be
reachable from the bridge. Proxy settings apply at creation — change them via `cpod down && cpod up`.

## How it works — principles & isolation

- **One container per project.** The name is derived from the project's absolute path, and the
  project is bind-mounted at the **same absolute path** inside — so `~/.claude/projects/<slug>`
  keeps matching and Claude sessions continue seamlessly across runs.
- **Non-root, as you.** The in-image user has your host uid/gid (podman rootless keeps the
  mapping; docker matches it). No root on the host; bind-mount ownership stays correct.
- **Per-repo deploy key, not your account.** GitHub access is a dedicated key scoped to *this one
  repo*, delivered through **ssh-agent** (the private key never lands on the container disk) and
  **revoked on `down`**. Your `~/.ssh`, `~/.config/gh`, `GH_TOKEN`/`*_API_KEY` are never forwarded;
  git identity is passed as **values only** (name/email), not your `~/.gitconfig`.
- **Claude, shared but pinned.** `~/.claude` is mounted so settings/history/sessions carry over;
  `.credentials.json` is **read-only**; `~/.claude.json` is mounted so the pod isn't a fresh
  install. The pod's Claude **never self-updates** (`DISABLE_AUTOUPDATER=1`).
- **Kernel-level hardening.** Non-root login user + empty added capabilities + the runtime's default
  seccomp profile. The **default** profile also gives passwordless `sudo` for setup; `guarded`/`locked`
  drop it and add **`no-new-privileges`** so SUID/SGID can't escalate. The docker socket is **not**
  mounted unless the project needs it or you pass `--docker`. The container has its **own** `/tmp` and
  root filesystem — the host `/tmp`, `/etc`, `/var`, and home are not visible.
- **Isolated, direct network by default.** A bridge network; the pod uses its own direct egress. Proxy
  forwarding is opt-in (`--proxy`, host-local proxy rewritten to the host-gateway); `--net-host` shares
  the host network stack (needed for a `localhost` proxy on rootless podman).
- **Trust profiles.** `--profile guarded`/`locked` bundle the read-only/no-docker/hardened settings
  for semi- and un-trusted code (see above).

## Weak sides — what it does NOT protect

`claude-pod` **reduces the blast radius** of a compromised or prompt-injected agent — it is **not
an absolute sandbox** against hostile code. Know these before running untrusted repos:

- **`~/.claude` is rw → host-escalation via hooks.** Code in the pod can write a malicious
  `settings.json`/hook that later runs **on the host** when you launch Claude there. No escape
  needed — the access is legitimate. Mitigate with `--profile guarded`/`locked` (`--claude-hardened`).
- **Token + project map are readable, egress is open → exfiltration.** The Claude OAuth token
  (`~/.claude/.credentials.json`) and your project map (`~/.claude.json`) are readable, and the pod
  has working network (it must reach the API). There is **no built-in egress allowlist** — a hard
  block can't be done in a rootless, cap-dropped container; it needs **host-level firewalling**.
  Rotate the token after untrusted runs; enforce egress at the host if you need it.
- **Project writes land on the host** immediately (by design). A `--key rw` deploy key (default)
  can **push/force-push** to that one repo.
- **Footguns that weaken isolation:** `--docker` (≈ root on host), `--net-host` (shares the host
  network incl. its `localhost` services), `--inherit-env` (an oddly-named secret may slip past the
  denylist). Avoid these for untrusted code.

Full threat model and residual risks: [`docs/SECURITY.md`](docs/SECURITY.md).

## Comparison with alternatives

There are several good ways to run Claude Code in a sandbox — they optimize for different things.
The table scrolls sideways; the recommendations below it are the short version.

| Tool | Isolation | GitHub credentials | Environment | Built-in egress control | Claude session continuity | Runtime |
|---|---|---|---|---|---|---|
| **`claude-pod`** (this) | container, **per-project**; non-root login; trust profiles (`no-new-privileges` in guarded/locked, sudo in default) | **per-repo deploy key**, auto-registered and **revoked on `down`** | full Ubuntu/CUDA + Node + `uv` + build tools, **GPU passthrough**, optional DinD | none by default (needs a host firewall) | **seamless** — project mounted at the same absolute path | podman **and** docker |
| [Claude Code devcontainer][dc] (official) | container | your host token; docs *recommend* a scoped PAT (manual) | your own `Dockerfile`/features | **yes** — `init-firewall.sh` egress allowlist | volume / `${devcontainerId}` | docker (VS Code / CLI) |
| [`sandbox-runtime`][sr] (Anthropic, native) | **OS-level** sandbox (bubblewrap/seatbelt), **no container** | host creds, typically via a scoped proxy | none — reuses host tools | **yes** — network allowlist | n/a (same host FS, cwd-scoped) | Linux/macOS, no daemon |
| [`container-use`][cu] (Dagger) | container **+ a git worktree per agent** | ordinary git creds | your image (Dagger) | via Dagger | n/a — designed for fan-out | docker/Dagger |
| [`claudebox`][cb] & similar wrappers | container | usually **host creds** / `--dangerously-skip-permissions` | preset profiles | none | volume | docker |
| Plain `docker run` (DIY) | container | whatever you mount in | whatever you build | manual | manual path/volume setup | docker/podman |

[dc]: https://docs.claude.com/en/docs/claude-code/devcontainer
[sr]: https://github.com/anthropics/sandbox-runtime
[cu]: https://github.com/dagger/container-use
[cb]: https://github.com/RchGrav/claudebox

### When to use which

- **Use `claude-pod`** when you want a **full dev environment** (GPU / `uv` / compilers) with
  **narrow per-repo GitHub access out of the box** and Claude history that **continues seamlessly**
  between host and container. Best for day-to-day work — including build/train — on **your own**
  repositories, on either podman or docker.
- **Use the [official devcontainer][dc]** when you want **team-reproducible** setups in VS Code and a
  **built-in egress firewall**. Prefer it when a network allowlist matters more than automatic
  per-repo keys, or your team already lives in devcontainers.
- **Use [`sandbox-runtime`][sr]** when you want the **lightest** barrier around Bash/tools **without a
  container**, with an egress allowlist. Prefer it for low-overhead, on-host confinement where you
  don't need a separate environment or GPU.
- **Use [`container-use`][cu]** when you run **several agents in parallel** on one repo, each on its
  own git worktree/branch — multi-agent orchestration rather than one rich environment.
- **Use [`claudebox`][cb] / wrappers** when you want a quick containerized Claude with preset
  profiles and **don't need** per-repo key isolation.
- **Roll your own `docker run`** when you want total manual control and are happy to wire up mounts,
  credentials, path-matching and cleanup yourself.

A deeper pros/cons breakdown lives in [`docs/PROS_CONS.md`](docs/PROS_CONS.md).

## Host requirements

- `podman` **or** `docker`
- `git`, `gh` (authenticated: `gh auth login`) — needed to register the deploy key
- `ssh-agent`/`ssh-keygen` (usually present) — to deliver the key without writing it to disk
- For GPU: NVIDIA driver + container toolkit (otherwise CPU mode)

## Documentation

- [`docs/TECHNOLOGY.md`](docs/TECHNOLOGY.md) — how it works: isolation, the deploy key,
  `~/.claude` path matching, dual-runtime.
- [`docs/PROS_CONS.md`](docs/PROS_CONS.md) — pros and cons, comparison with alternatives.
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model and **residual risks** (please read).

## Uninstall

```bash
# first, in each project: cpod down   (to revoke the deploy key)
curl -fsSL https://raw.githubusercontent.com/kudep/claude-pod/main/uninstall.sh | bash
```
