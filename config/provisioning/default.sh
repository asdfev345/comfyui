#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# USER CONFIG
# ============================================================

APT_PACKAGES=(
  "aria2"
)

PIP_PACKAGES=(
)

NODES=(
  "https://github.com/ltdrdata/ComfyUI-Manager"
  "https://github.com/cubiq/ComfyUI_essentials"
  "https://github.com/AlekPet/ComfyUI_Custom_Nodes_AlekPet"
  "https://github.com/kijai/ComfyUI-KJNodes"
)

CHECKPOINT_MODELS=(
  # Example Civitai:
  "https://civitai.com/api/download/models/2514310?type=Model&format=SafeTensor&size=pruned&fp=fp16"
  "https://civitai.com/api/download/models/2167369?type=Model&format=SafeTensor&size=pruned&fp=fp16"
)

UNET_MODELS=( )
LORA_MODELS=( )

VAE_MODELS=(
  "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors?download=true"
)

UPSCALE_MODELS=( )
CONTROLNET_MODELS=( )

DIFFUSION_MODELS=(
  "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/diffusion_models/anima-preview.safetensors?download=true"
)

TEXT_ENCODER_MODELS=(
  "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors?download=true"
)

# Optional: force re-download even if file exists
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-false}"

# ============================================================
# DO NOT EDIT BELOW
# ============================================================

log(){ echo "[provision] $*"; }

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_WORKSPACE="/workspace/ComfyUI"
INTERNAL_COMFY="/opt/workspace-internal/ComfyUI"

PYTHON_BIN="${PYTHON_BIN:-/venv/main/bin/python}"
PIP_BIN="${PIP_BIN:-/venv/main/bin/pip}"

normalize_comfy_paths() {
  if [[ -d "$INTERNAL_COMFY" && -f "$INTERNAL_COMFY/main.py" ]]; then
    if [[ -e "$COMFY_WORKSPACE" && ! -L "$COMFY_WORKSPACE" ]]; then
      log "Backing up existing $COMFY_WORKSPACE -> ${COMFY_WORKSPACE}.bak"
      mv "$COMFY_WORKSPACE" "${COMFY_WORKSPACE}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    ln -sfn "$INTERNAL_COMFY" "$COMFY_WORKSPACE"
    log "Linked $COMFY_WORKSPACE -> $INTERNAL_COMFY"
  fi

  if [[ ! -f "$COMFY_WORKSPACE/main.py" ]]; then
    log "ERROR: ComfyUI not found at $COMFY_WORKSPACE (main.py missing)"
    log "Check whether image path changed. INTERNAL_COMFY=$INTERNAL_COMFY"
    exit 1
  fi
}

APT_INSTALL="${APT_INSTALL:-apt-get install -y --no-install-recommends}"

pip_install() {
  if [[ -n "${COMFYUI_VENV_PIP:-}" ]] && command -v "${COMFYUI_VENV_PIP}" >/dev/null 2>&1; then
    "${COMFYUI_VENV_PIP}" install --no-cache-dir "$@"
    return 0
  fi
  if [[ -x "$PIP_BIN" ]]; then
    "$PIP_BIN" install --no-cache-dir "$@"
    return 0
  fi
  if [[ -x "$PYTHON_BIN" ]]; then
    "$PYTHON_BIN" -m pip install --no-cache-dir "$@"
    return 0
  fi
  pip install --no-cache-dir "$@"
}

provisioning_get_apt_packages() {
  if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    log "Installing apt packages: ${APT_PACKAGES[*]}"
    sudo apt-get update
    sudo $APT_INSTALL "${APT_PACKAGES[@]}"
  fi
}

provisioning_get_pip_packages() {
  if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    log "Installing pip packages: ${PIP_PACKAGES[*]}"
    pip_install "${PIP_PACKAGES[@]}"
  fi
}

# NEW: download into directory using Content-Disposition filename
provisioning_download_to_dir() {
  local dir="$1"
  local url="$2"

  mkdir -p "$dir"

  local auth_header=""
  local final_url="$url"

  # HuggingFace auth header (optional)
  if [[ -n "${HF_TOKEN:-}" ]] && [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_header="Authorization: Bearer ${HF_TOKEN}"
  fi

  # Civitai token (append as query param)
  if [[ -n "${CIVITAI_TOKEN:-}" ]] && [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
    if [[ "$url" == *"?"* ]]; then
      final_url="${url}&token=${CIVITAI_TOKEN}"
    else
      final_url="${url}?token=${CIVITAI_TOKEN}"
    fi
  fi

  log "Downloading into dir: $dir"
  log "  from: $final_url"

  # Prefer aria2c if available
  if command -v aria2c >/dev/null 2>&1; then
    # --content-disposition uses server-provided filename (fixes civitai numeric names)
    if [[ -n "$auth_header" ]]; then
      aria2c -x 16 -s 16 -k 1M --content-disposition --header="$auth_header" -d "$dir" "$final_url"
    else
      aria2c -x 16 -s 16 -k 1M --content-disposition -d "$dir" "$final_url"
    fi
    return 0
  fi

  # wget fallback
  if command -v wget >/dev/null 2>&1; then
    if [[ -n "$auth_header" ]]; then
      wget --header="$auth_header" --content-disposition --show-progress -qnc -P "$dir" "$final_url"
    else
      wget --content-disposition --show-progress -qnc -P "$dir" "$final_url"
    fi
    return 0
  fi

  # curl fallback: -OJ respects content-disposition (saves filename)
  if [[ -n "$auth_header" ]]; then
    (cd "$dir" && curl -fL -H "$auth_header" -OJ "$final_url")
  else
    (cd "$dir" && curl -fL -OJ "$final_url")
  fi
}

# UPDATED: now uses content-disposition downloader (no more URL basename naming)
provisioning_get_models_dir_urlonly() {
  local dir="$1"; shift || true
  local arr=("$@")

  if [[ ${#arr[@]} -eq 0 ]]; then
    return 0
  fi

  mkdir -p "$dir"
  log "Downloading ${#arr[@]} file(s) to $dir"

  for url in "${arr[@]}"; do
    provisioning_download_to_dir "$dir" "$url" || log "WARNING: download failed (continuing): $url"
  done
}

provisioning_get_nodes() {
  local nodes_dir="${COMFY_WORKSPACE}/custom_nodes"
  mkdir -p "$nodes_dir"

  for repo in "${NODES[@]}"; do
    local dir path requirements
    dir="${repo##*/}"
    path="${nodes_dir}/${dir}"
    requirements="${path}/requirements.txt"

    if [[ -d "$path/.git" ]]; then
      if [[ "${AUTO_UPDATE:-true}" != "false" ]]; then
        log "Updating node: $repo"
        git -C "$path" pull --ff-only || true
      else
        log "AUTO_UPDATE=false; skipping update: $dir"
      fi
    elif [[ -d "$path" ]]; then
      log "Node dir exists but not a git repo, skipping clone: $path"
    else
      log "Cloning node: $repo"
      git clone --depth=1 --recursive "$repo" "$path"
    fi

    if [[ -f "$requirements" ]]; then
      log "Installing node requirements: $requirements"
      pip_install -r "$requirements" || log "WARNING: pip install failed for $dir (continuing)"
    fi
  done
}

provisioning_print_header() {
  printf "\n##############################################\n"
  printf "#          Provisioning container             #\n"
  printf "##############################################\n\n"
}

provisioning_print_end() {
  printf "\nProvisioning complete.\n\n"
}

provisioning_start() {
  normalize_comfy_paths

  log "CANONICAL COMFY PATH: $COMFY_WORKSPACE"
  provisioning_print_header

  provisioning_get_apt_packages
  provisioning_get_nodes
  provisioning_get_pip_packages

  # Standard model dirs (under /workspace/ComfyUI)
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/checkpoints"    "${CHECKPOINT_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/unet"           "${UNET_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/loras"          "${LORA_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/controlnet"     "${CONTROLNET_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/vae"            "${VAE_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/upscale_models" "${UPSCALE_MODELS[@]}"

  # Non-standard dirs (still under /workspace/ComfyUI)
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/text_encoders"   "${TEXT_ENCODER_MODELS[@]}"

  provisioning_print_end
}

provisioning_start
