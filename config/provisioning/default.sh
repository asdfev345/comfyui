#!/usr/bin/env bash
set -euo pipefail

# Packages are installed after nodes so we can fix them...

APT_PACKAGES=(
)

PIP_PACKAGES=(
)

NODES=(
  "https://github.com/ltdrdata/ComfyUI-Manager"
  "https://github.com/cubiq/ComfyUI_essentials"
)

CHECKPOINT_MODELS=(
)
UNET_MODELS=(
)
LORA_MODELS=(
)
VAE_MODELS=(
)
UPSCALE_MODELS=(
)
CONTROLNET_MODELS=(
)

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

# ---- Vastai comfy layout (detected from your container) ----
COMFYUI_ROOT="/opt/workspace-internal/ComfyUI"
WORKSPACE="${WORKSPACE:-/workspace}"

# APT installer fallback
APT_INSTALL="${APT_INSTALL:-apt-get install -y --no-install-recommends}"

# Pick pip
PIP_CMD=""
if [[ -n "${COMFYUI_VENV_PIP:-}" ]] && command -v "${COMFYUI_VENV_PIP}" >/dev/null 2>&1; then
  PIP_CMD="${COMFYUI_VENV_PIP}"
elif command -v python >/dev/null 2>&1; then
  PIP_CMD="python -m pip"
else
  PIP_CMD="pip"
fi

function provisioning_start() {
  # ai-dock optional
  if [[ -f /opt/ai-dock/etc/environment.sh ]]; then
    # shellcheck disable=SC1091
    source /opt/ai-dock/etc/environment.sh
  fi
  if [[ -f /opt/ai-dock/bin/venv-set.sh ]]; then
    # shellcheck disable=SC1091
    source /opt/ai-dock/bin/venv-set.sh comfyui
  fi

  provisioning_print_header
  provisioning_get_apt_packages
  provisioning_get_nodes
  provisioning_get_pip_packages

  # ComfyUI-native model dirs
  provisioning_get_models "${COMFYUI_ROOT}/models/checkpoints" "${CHECKPOINT_MODELS[@]}"
  provisioning_get_models "${COMFYUI_ROOT}/models/unet"        "${UNET_MODELS[@]}"
  provisioning_get_models "${COMFYUI_ROOT}/models/loras"       "${LORA_MODELS[@]}"
  provisioning_get_models "${COMFYUI_ROOT}/models/controlnet"  "${CONTROLNET_MODELS[@]}"
  provisioning_get_models "${COMFYUI_ROOT}/models/vae"         "${VAE_MODELS[@]}"
  provisioning_get_models "${COMFYUI_ROOT}/models/upscale_models" "${UPSCALE_MODELS[@]}"

  provisioning_print_end
}

function pip_install() {
  # Prefer micromamba only if it exists AND you truly want it
  if command -v micromamba >/dev/null 2>&1; then
    micromamba run -n comfyui pip install --no-cache-dir "$@"
  else
    # shellcheck disable=SC2086
    $PIP_CMD install --no-cache-dir "$@"
  fi
}

function provisioning_get_apt_packages() {
  if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    sudo $APT_INSTALL "${APT_PACKAGES[@]}"
  fi
}

function provisioning_get_pip_packages() {
  if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    pip_install "${PIP_PACKAGES[@]}"
  fi
}

function provisioning_get_nodes() {
  for repo in "${NODES[@]}"; do
    dir="${repo##*/}"
    path="${COMFYUI_ROOT}/custom_nodes/${dir}"
    requirements="${path}/requirements.txt"

    if [[ -d "$path" ]]; then
      if [[ "${AUTO_UPDATE,,}" != "false" ]]; then
        printf "Updating node: %s...\n" "${repo}"
        ( cd "$path" && git pull --ff-only ) || true
      fi
    else
      printf "Downloading node: %s...\n" "${repo}"
      git clone --depth=1 --recursive "${repo}" "${path}"
    fi

    if [[ -f "$requirements" ]]; then
      pip_install -r "$requirements" || true
    fi
  done
}

function provisioning_get_models() {
  local dir="$1"; shift || true
  local arr=("$@")
  if [[ ${#arr[@]} -eq 0 ]]; then
    return 0
  fi

  mkdir -p "$dir"
  printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    printf "Downloading: %s\n" "${url}"
    provisioning_download "${url}" "${dir}"
    printf "\n"
  done
}

function provisioning_print_header() {
  printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n##############################################\n\n"
  printf "COMFYUI_ROOT: %s\n" "$COMFYUI_ROOT"
  printf "WORKSPACE:    %s\n\n" "$WORKSPACE"
}

function provisioning_print_end() {
  printf "\nProvisioning complete.\n\n"
}

# Download from $1 URL to $2 dir path
function provisioning_download() {
  local url="$1"
  local dir="$2"
  local auth_header=""
  local final_url="$url"

  # HuggingFace 처리 (헤더 방식)
  if [[ -n "${HF_TOKEN:-}" ]] && [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_header="Authorization: Bearer $HF_TOKEN"
  fi

  # Civitai 처리 (URL 파라미터 방식)
  if [[ -n "${CIVITAI_TOKEN:-}" ]] && [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
    if [[ "$url" == *"?"* ]]; then
      final_url="${url}&token=${CIVITAI_TOKEN}"
    else
      final_url="${url}?token=${CIVITAI_TOKEN}"
    fi
  fi

  mkdir -p "$dir"

  # aria2c 있으면 그걸로(빠름)
  if command -v aria2c >/dev/null 2>&1; then
    if [[ -n "$auth_header" ]]; then
      aria2c -x 16 -s 16 -k 1M --header="$auth_header" --content-disposition -d "$dir" "$final_url"
    else
      aria2c -x 16 -s 16 -k 1M --content-disposition -d "$dir" "$final_url"
    fi
    return 0
  fi

  # wget 기본
  if command -v wget >/dev/null 2>&1; then
    if [[ -n "$auth_header" ]]; then
      wget --header="$auth_header" -qnc --content-disposition --show-progress -P "$dir" "$final_url"
    else
      wget -qnc --content-disposition --show-progress -P "$dir" "$final_url"
    fi
    return 0
  fi

  # curl fallback
  if [[ -n "$auth_header" ]]; then
    curl -fL -H "$auth_header" -OJ --output-dir "$dir" "$final_url"
  else
    curl -fL -OJ --output-dir "$dir" "$final_url"
  fi
}

provisioning_start
