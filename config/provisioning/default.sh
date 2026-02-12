#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# USER CONFIG
#  - Edit only this section for your own workflow/model setup.
# ============================================================

# Optional apt packages (installed once at provisioning time)
APT_PACKAGES=(
  # "aria2"
)

# Optional pip packages (installed once at provisioning time)
PIP_PACKAGES=(
  # "numpy"
)

# Custom nodes to clone/update (requirements.txt auto-installed if present)
NODES=(
  "https://github.com/ltdrdata/ComfyUI-Manager"
  "https://github.com/cubiq/ComfyUI_essentials"
  "https://github.com/AlekPet/ComfyUI_Custom_Nodes_AlekPet"
  "https://github.com/kijai/ComfyUI-KJNodes"
)

# --- Standard ComfyUI-ish model categories (downloaded into COMFY_ROOT/models/...) ---
CHECKPOINT_MODELS=(
  # "https://civitai.com/api/download/models/123456"
)
UNET_MODELS=(
)
LORA_MODELS=(
)
VAE_MODELS=(
  "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors?download=true"
)
UPSCALE_MODELS=(
)
CONTROLNET_MODELS=(
)

# --- Non-standard folders (for workflows like Anima/Qwen, etc.) ---
# Downloaded into:
#   COMFY_ROOT/models/diffusion_models
#   COMFY_ROOT/models/text_encoders
DIFFUSION_MODELS=(
  "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/diffusion_models/anima-preview.safetensors?download=true"
)
TEXT_ENCODER_MODELS=(
  "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors?download=true"
)

# ============================================================
# DO NOT EDIT BELOW (unless you know what you're doing)
# ============================================================

log(){ echo "[provision] $*"; }

# Detect actual ComfyUI root on vastai/comfy images
detect_comfy_root() {
  local candidates=(
    "/opt/workspace-internal/ComfyUI"
    "/workspace/ComfyUI"
    "/opt/ComfyUI"
    "/opt/ComfyUI/ComfyUI"
  )

  for d in "${candidates[@]}"; do
    if [[ -d "$d" && -f "$d/main.py" && -d "$d/custom_nodes" ]]; then
      echo "$d"; return 0
    fi
  done

  # fallback: find by main.py
  local p
  p="$(find /opt -maxdepth 5 -type f -name main.py 2>/dev/null | grep -E '/ComfyUI/main\.py$' | head -n 1 || true)"
  if [[ -n "$p" ]]; then
    echo "$(dirname "$p")"; return 0
  fi

  echo "/opt/workspace-internal/ComfyUI"
}

APT_INSTALL="${APT_INSTALL:-apt-get install -y --no-install-recommends}"
WORKSPACE="${WORKSPACE:-/workspace}"

maybe_source_ai_dock() {
  # Optional compatibility with ai-dock images; safe on vastai/comfy
  if [[ -f /opt/ai-dock/etc/environment.sh ]]; then
    # shellcheck disable=SC1091
    source /opt/ai-dock/etc/environment.sh
    log "Sourced ai-dock environment"
  fi
  if [[ -f /opt/ai-dock/bin/venv-set.sh ]]; then
    # shellcheck disable=SC1091
    source /opt/ai-dock/bin/venv-set.sh comfyui
    log "Sourced ai-dock venv-set"
  fi
}

pip_install() {
  # Prefer ai-dock pip if provided; else use current python
  if [[ -n "${COMFYUI_VENV_PIP:-}" ]] && command -v "${COMFYUI_VENV_PIP}" >/dev/null 2>&1; then
    "${COMFYUI_VENV_PIP}" install --no-cache-dir "$@"
    return 0
  fi
  python -m pip install --no-cache-dir "$@"
}

url_basename() {
  # strip querystring and return basename
  local u="${1%%\?*}"
  echo "${u##*/}"
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

provisioning_download_to_file() {
  local out_file="$1"
  local url="$2"

  mkdir -p "$(dirname "$out_file")"

  if [[ -f "$out_file" ]]; then
    log "Skip (exists): $out_file"
    return 0
  fi

  local auth_header=""
  local final_url="$url"

  # HuggingFace: auth header if provided
  if [[ -n "${HF_TOKEN:-}" ]] && [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_header="Authorization: Bearer ${HF_TOKEN}"
  fi

  # Civitai: append token as query param (handles redirects reliably)
  if [[ -n "${CIVITAI_TOKEN:-}" ]] && [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
    if [[ "$url" == *"?"* ]]; then
      final_url="${url}&token=${CIVITAI_TOKEN}"
    else
      final_url="${url}?token=${CIVITAI_TOKEN}"
    fi
  fi

  log "Downloading -> $out_file"
  log "  from: $final_url"

  # Prefer aria2c if available (faster, resumable)
  if command -v aria2c >/dev/null 2>&1; then
    if [[ -n "$auth_header" ]]; then
      aria2c -x 16 -s 16 -k 1M --header="$auth_header" -o "$(basename "$out_file")" -d "$(dirname "$out_file")" "$final_url"
    else
      aria2c -x 16 -s 16 -k 1M -o "$(basename "$out_file")" -d "$(dirname "$out_file")" "$final_url"
    fi
    return 0
  fi

  # wget fallback
  if command -v wget >/dev/null 2>&1; then
    if [[ -n "$auth_header" ]]; then
      wget --header="$auth_header" -O "$out_file" "$final_url"
    else
      wget -O "$out_file" "$final_url"
    fi
    return 0
  fi

  # curl fallback
  if [[ -n "$auth_header" ]]; then
    curl -fL -H "$auth_header" -o "$out_file" "$final_url"
  else
    curl -fL -o "$out_file" "$final_url"
  fi
}

provisioning_get_models_dir_urlonly() {
  local dir="$1"; shift || true
  local arr=("$@")

  if [[ ${#arr[@]} -eq 0 ]]; then
    return 0
  fi

  mkdir -p "$dir"
  log "Downloading ${#arr[@]} file(s) to $dir"

  for url in "${arr[@]}"; do
    local name
    name="$(url_basename "$url")"
    if [[ -z "$name" ]]; then
      log "WARNING: could not derive filename from URL, skipping: $url"
      continue
    fi
    provisioning_download_to_file "$dir/$name" "$url" || log "WARNING: download failed (continuing): $url"
  done
}

provisioning_get_nodes() {
  local comfy_root="$1"
  local nodes_dir="${comfy_root}/custom_nodes"
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

    # Install requirements if present (your preferred behavior)
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
  maybe_source_ai_dock

  local comfy_root
  comfy_root="$(detect_comfy_root)"

  log "WORKSPACE=$WORKSPACE"
  log "COMFY_ROOT=$comfy_root"

  provisioning_print_header

  provisioning_get_apt_packages
  provisioning_get_nodes "$comfy_root"
  provisioning_get_pip_packages

  # Standard model directories
  provisioning_get_models_dir_urlonly "${comfy_root}/models/checkpoints"    "${CHECKPOINT_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${comfy_root}/models/unet"           "${UNET_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${comfy_root}/models/loras"          "${LORA_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${comfy_root}/models/controlnet"     "${CONTROLNET_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${comfy_root}/models/vae"            "${VAE_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${comfy_root}/models/upscale_models" "${UPSCALE_MODELS[@]}"

  # Non-standard model directories (your requested style)
  provisioning_get_models_dir_urlonly "${comfy_root}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${comfy_root}/models/text_encoders"   "${TEXT_ENCODER_MODELS[@]}"

  provisioning_print_end
}

provisioning_start
