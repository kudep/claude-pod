#compdef cpod claude-pod
# zsh completion for cpod / claude-pod
# Install: copy to a dir in $fpath, e.g. ${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions/_cpod

_cpod() {
  _arguments -s \
    '--profile[trust-level preset]:profile:(default guarded locked)' \
    '--key[git access mode]:mode:(rw ro none)' \
    '--key-file[deliver the deploy key as a file instead of ssh-agent]' \
    '--claude[run claude on entry instead of a shell]' \
    '--run[run a command on entry]:command:' \
    '--claude-hardened[mount executable ~/.claude config read-only]' \
    '--inherit-env[forward all host env except secrets]' \
    '*--env[forward one environment variable]:KEY=VAL:' \
    '*-p[publish a port (docker-style)]:port spec:' \
    '*--port[publish a port (docker-style)]:port spec:' \
    '*-v[extra bind mount or named volume]:volume spec:' \
    '*--volume[extra bind mount or named volume]:volume spec:' \
    '--cache-volume[persistent per-project ~/.cache volume]' \
    '--rm[remove the container when the session ends]' \
    '--volumes[(down) also remove the cache volume]' \
    '(-f --follow)'{-f,--follow}'[(logs) stream the logs]' \
    '--net-host[use the host network]' \
    '--gpu[force GPU on]' \
    '--no-gpu[force GPU off]' \
    '--docker[enable docker socket passthrough]' \
    '--no-docker[disable docker socket passthrough]' \
    '--runtime[container runtime]:runtime:(podman docker)' \
    '--rebuild[rebuild the image]' \
    '--all[list containers of all projects]' \
    '(-h --help)'{-h,--help}'[show help]' \
    '1:command:(up start attach shell restart exec logs inspect stop down prune ls list status build help)'
}

_cpod "$@"
