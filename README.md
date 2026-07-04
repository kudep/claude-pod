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
| `cpod ls`     | list containers for this project (`--all` for every one)        |
| `cpod stop`   | stop the container (without removing it)                        |
| `cpod down`   | stop, remove the container and **revoke the deploy key**        |

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

## Handy flags

```bash
cpod up --claude               # run claude right away (default is just a shell)
cpod up --run "pytest -q"      # run a command on entry
cpod up --claude-hardened      # ~/.claude: settings/plugins/hooks ro (protect host from a planted hook)
cpod up --inherit-env          # forward all host variables (except secrets)
cpod up --env FOO=bar          # forward a single variable
cpod up -p 8080:80             # publish a port (docker-style); repeatable
cpod up -p 127.0.0.1:5432:5432/tcp
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
