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
cpod up --profile default   # (default) key rw, ~/.claude rw, docker auto — your own code
cpod up --profile guarded   # key ro, --claude-hardened, no docker — semi-trusted code
cpod up --profile locked    # key none, --claude-hardened, no docker, --rm — untrusted code
cpod up --profile locked --key ro    # profiles are just defaults — override any flag
```

Every pod (all profiles) runs with `no-new-privileges`. Profiles do **not** include a network
egress allowlist — see [weak sides](#weak-sides--what-it-does-not-protect).

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
cpod up --net-host             # host network (handy for proxies; weakens isolation; ignores -p)
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

Host `http(s)_proxy`/`no_proxy` are forwarded automatically, with `localhost`/`127.0.0.1`
rewritten to the container's host-gateway so a host-local proxy stays reachable (verbatim
under `--net-host`, which shares the host loopback). Since Claude's API is **HTTPS**, if the
host defines only `http_proxy` (no `https_proxy`), cpod mirrors it onto `https_proxy` inside
the pod — so a single HTTP proxy that also does `CONNECT` just works, no manual
`https_proxy=…` needed.

One caveat cpod can't paper over: the proxy must be *reachable from the container*. A proxy
bound to `127.0.0.1` only is reachable under `--net-host`; from the default (bridge) network
it must listen on a routable address (e.g. `0.0.0.0`). Changing proxy settings requires
recreating the pod (`cpod down && cpod up`) — env is applied at creation.

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
- **Kernel-level hardening.** Non-root + empty added capabilities + the runtime's default seccomp
  profile + **`no-new-privileges`** (SUID/SGID can't escalate). The docker socket is **not** mounted
  unless the project needs it or you pass `--docker`. The container has its **own** `/tmp` and root
  filesystem — the host `/tmp`, `/etc`, `/var`, and home are not visible.
- **Isolated network by default.** A bridge network; a host-local proxy is reached via the rewritten
  host-gateway address (no host netns). `--net-host` is opt-in.
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
