# shellcheck shell=bash
# lib/gpu.sh — optional NVIDIA GPU passthrough with autodetect.
# CPOD_GPU: auto | on | off. Appends to RUN_ARGS.

gpu_available() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

gpu_add() {
  case "${CPOD_GPU}" in
    off) return 0 ;;
    on)
      if ! gpu_available; then
        log_warn "--gpu задан, но nvidia-smi недоступен — контейнер стартует без GPU"
        return 0
      fi
      ;;
    auto)
      if ! gpu_available; then
        log_warn "NVIDIA GPU не обнаружен — запуск в CPU-режиме (отключить предупреждение: --no-gpu)"
        return 0
      fi
      ;;
  esac
  # GPU is available and wanted.
  if rt_is_podman; then
    if ls /etc/cdi/*nvidia*.yaml >/dev/null 2>&1 || ls /etc/cdi/*nvidia*.json >/dev/null 2>&1; then
      RUN_ARGS+=( --device nvidia.com/gpu=all )
    else
      RUN_ARGS+=( --gpus all )   # newer podman understands --gpus
    fi
  else
    RUN_ARGS+=( --gpus all )
  fi
  log_step "GPU: проброшен (nvidia)"
}
