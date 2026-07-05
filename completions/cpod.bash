# bash completion for cpod / claude-pod
# Install: copy to ${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/cpod
_cpod() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local cmds="up start attach shell restart exec logs inspect stop down prune ls list status build help"
  local flags="--profile --key --key-file --claude --run --claude-hardened --inherit-env --env \
               -p --port -v --volume --cache-volume --rm --volumes -f --follow \
               --root --no-root --proxy --net-host --gpu --no-gpu --docker --no-docker --runtime \
               --rebuild --all --help -h"

  case "$prev" in
    --profile) COMPREPLY=( $(compgen -W "default guarded locked" -- "$cur") ); return ;;
    --key)     COMPREPLY=( $(compgen -W "rw ro none" -- "$cur") ); return ;;
    --runtime) COMPREPLY=( $(compgen -W "podman docker" -- "$cur") ); return ;;
    --run|--env|-p|--port|-v|--volume) return ;;   # free-form value
  esac

  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
    return
  fi

  # first non-flag word -> a command
  local seen_cmd=""
  local i
  for (( i=1; i < COMP_CWORD; i++ )); do
    case "${COMP_WORDS[i]}" in
      up|start|attach|shell|restart|exec|logs|inspect|stop|down|prune|ls|list|status|build|help) seen_cmd=1; break ;;
    esac
  done
  if [ -z "$seen_cmd" ]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
  else
    COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
  fi
}
complete -F _cpod cpod claude-pod
