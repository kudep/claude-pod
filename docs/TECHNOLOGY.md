# TECHNOLOGY — how `claude-pod` works

Encapsulation technology: **an OCI process-container with a bind-mounted project + a
host-side credential broker**. Below is what exactly is encapsulated, by which mechanisms,
and why.

## 1. A container instead of an OS sandbox

`claude-pod` runs Claude Code inside an OCI container (podman/docker) rather than an OS
sandbox (bubblewrap/seatbelt). That gives a full, reproducible environment (Ubuntu/CUDA +
Node + uv + compilers), GPU passthrough, and per-project isolation of the filesystem and
processes. The cost is the image and container overhead (see `PROS_CONS.md`).

- **Runtime abstraction** (`lib/runtime.sh`): picks `podman` (default, rootless) or `docker`.
  All calls go through `$RT`. Selection: `--runtime` / `CLAUDE_POD_RUNTIME` → podman → docker.
- **Non-root user**: the image is built **for the specific host** — it creates a user with
  the same `uid:gid` and `HOME` as the host (`--build-arg HOST_UID/GID/USER/HOME`). For podman
  rootless it also adds `--userns=keep-id` so bind-mount ownership lines up.

## 2. Path matching and a shared `~/.claude`

Claude Code stores sessions/history under `~/.claude/projects/<slug>`, where `<slug>` is the
project's absolute path with `/` replaced by `-`. So that **sessions continue seamlessly** on
both host and container:

- the project is mounted at the **identical absolute path** (`-v $PWD:$PWD`, `-w $PWD`);
- the container `HOME` equals the host one, and `~/.claude` is bind-mounted in;
- `~/.claude` is mounted **rw** (config/history/projects live together with the host), while
  the token file `~/.claude/.credentials.json` is mounted **read-only** on top (hybrid: config
  is writable, the token can't be corrupted). See `lib/mounts.sh`.

Host secrets are **not** forwarded: `~/.ssh`, `~/.config/gh`, `~/.git-credentials`, `~/.netrc`,
`GH_TOKEN`/`GITHUB_TOKEN`/`*_API_KEY` (denylist under `--inherit-env`).

## 3. Git isolation via a per-repo deploy key (host-side broker)

Core idea: **the main account's token stays on the host**, and the container gets narrow,
one-shot access to exactly one repository.

Flow (`lib/deploykey.sh`), executed on the host at `cpod up`:

1. The current repo's `origin` is detected and parsed into `owner/repo`. If it is not a GitHub
   repository, the whole block is skipped (git works locally, no remote).
2. An **ephemeral** `ed25519` pair is generated (in a temporary state dir, never in `~/.ssh`).
3. The public key is registered as a **deploy key** of that repo:
   `gh api -X POST /repos/{owner}/{repo}/keys` (`read_only` per `--key ro|rw`). By its nature a
   deploy key is limited to **one** repository — it grants no access to any other.
4. **Key delivery — ssh-agent forwarding (default):** the private key is loaded into an
   ephemeral `ssh-agent` on the host, and only its socket (`SSH_AUTH_SOCK`) is forwarded into
   the container. After loading, the key is **shredded from disk** — it lives only in agent
   memory. Inside the container `git` signs operations through the agent, but **the key itself
   is not there** — there is nothing to steal from the container. The `--key-file` fallback
   mounts the key file read-only (weaker).
5. Inside the container (`entrypoint.sh`) git is configured: `url."git@github.com:${repo}".
   insteadOf "https://github.com/${repo}"` — scoped to THIS repo so other github https
   dependencies are not forced over ssh — and `~/.ssh/config` with
   `StrictHostKeyChecking accept-new`.
6. On `cpod down` the key is **revoked** (`gh api -X DELETE …/keys/{id}`), the ssh-agent is
   stopped, and temporary files are removed.

### How ssh-agent works (short)
`ssh-agent` keeps the private key in its own memory and never hands it out. Clients (git/ssh)
talk to it over a unix socket (`SSH_AUTH_SOCK`) asking it to "sign this challenge" — the agent
signs internally and returns only the signature. By forwarding only the socket into the
container, we let it *use* the key without letting it *copy* the key.

## 4. Proxy, environment, networking (`lib/mounts.sh`)
- Proxy variables are forwarded automatically; `localhost/127.0.0.1` in them is rewritten to
  the host gateway (`host.docker.internal` / `host.containers.internal`).
- `--inherit-env` forwards all host variables except the secret denylist; `--env KEY[=VAL]`
  forwards one.
- **`-p/--port`** publishes specific ports docker-style (`8080:80`, `127.0.0.1:5432:5432/tcp`),
  repeatable — the container stays on its own network and only the listed ports are reachable.
- `--net-host` uses the host network: `localhost` inside == the host's (handy for proxying),
  no rewrite needed, but it weakens isolation and ignores `-p`.

## 5. GPU and Docker-in-Docker
- **GPU** (`lib/gpu.sh`): autodetects `nvidia-smi`; if present, adds `--gpus all` (docker) or a
  CDI device (podman). No GPU → a warning and CPU mode. `--gpu/--no-gpu` override.
- **DinD** (`lib/dind.sh`): off by default. If docker is found in the project (Dockerfile/
  compose), the socket is passed through automatically with a warning (this is ~ root on the
  host). `--docker/--no-docker` override.

## 6. Container lifecycle (`lib/container.sh`)
The container's main process is `sleep infinity` (after one-time setup in `entrypoint.sh`).
Therefore `up`/`start`/`attach` all enter uniformly via `exec`, and the container survives an
exited shell — which is exactly what gives the three independent scenarios:

- `up` → `run -d` (create+start) + `exec` (enter);
- `start` → `start` a stopped one + `exec`;
- `attach` → `exec` into a running one (any number of parallel sessions).

Identity: name `cpod-<basename>-<hash(abspath)>` and labels `cpod.managed/project/repo/keyid/
runtime`. `cpod ls` filters by label — by the current path or (`--all`) across all.
