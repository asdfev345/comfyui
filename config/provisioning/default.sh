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

# Example Civitai URL (will save as real filename via Content-Disposition)
CHECKPOINT_MODELS=(
  "https://civitai.com/api/download/models/2514310?type=Model&format=SafeTensor&size=pruned&fp=fp16"
  "https://civitai.com/api/download/models/2167369?type=Model&format=SafeTensor&size=pruned&fp=fp16"
)

UNET_MODELS=( )
LORA_MODELS=( )

# HF URLs (will save as URL basename, e.g. qwen_image_vae.safetensors)
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

# ============================================================
# DO NOT EDIT BELOW
# ============================================================

log(){ echo "[provision] $*"; }

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_WORKSPACE="/workspace/ComfyUI"
INTERNAL_COMFY="/opt/workspace-internal/ComfyUI"

PYTHON_BIN="${PYTHON_BIN:-/venv/main/bin/python}"
PIP_BIN="${PIP_BIN:-/venv/main/bin/pip}"

# Force canonical /workspace/ComfyUI path (NO BACKUP)
normalize_comfy_paths() {
  if [[ -d "$INTERNAL_COMFY" && -f "$INTERNAL_COMFY/main.py" ]]; then
    ln -sfn "$INTERNAL_COMFY" "$COMFY_WORKSPACE"
    log "Linked $COMFY_WORKSPACE -> $INTERNAL_COMFY"
  fi

  if [[ ! -f "$COMFY_WORKSPACE/main.py" ]]; then
    log "ERROR: ComfyUI not found at $COMFY_WORKSPACE"
    exit 1
  fi
}

APT_INSTALL="${APT_INSTALL:-apt-get install -y --no-install-recommends}"

pip_install() {
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

# ============================================================
# HF_TRANSFER SUPPORT (added)
# ============================================================

# Try to install hf_transfer and enable it for huggingface_hub
provisioning_enable_hf_transfer() {
  # Only best-effort; if install fails, we still fall back to aria2/curl.
  log "Enabling hf_transfer (best-effort)..."
  pip_install -q hf_transfer huggingface_hub || true
  export HF_HUB_ENABLE_HF_TRANSFER=1
}

# Parse HF "resolve" URLs and download via huggingface_hub (hf_transfer if available)
# Returns 0 if download succeeded, 1 if not applicable or failed.
provisioning_hf_transfer_download() {
  local dir="$1"
  local url="$2"

  # Only handle huggingface.co/.../resolve/... style
  if [[ ! "$url" =~ ^https://huggingface\.co/ ]]; then
    return 1
  fi
  if [[ "$url" != *"/resolve/"* ]]; then
    return 1
  fi

  # Strip query
  local clean="${url%%\?*}"

  # Expected: https://huggingface.co/<repo_id>/resolve/<rev>/<path>
  # We will parse repo_id, rev, path
  # Remove prefix:
  local rest="${clean#https://huggingface.co/}"

  local repo_id="${rest%%/resolve/*}"
  local after="${rest#${repo_id}/resolve/}"
  local rev="${after%%/*}"
  local file_path="${after#${rev}/}"

  if [[ -z "$repo_id" || -z "$rev" || -z "$file_path" || "$file_path" == "$after" ]]; then
    return 1
  fi

  mkdir -p "$dir"

  log "HF (hf_transfer) attempt: repo=$repo_id rev=$rev file=$file_path -> $dir"

  # Use python huggingface_hub to download
  # We use cache_dir inside /workspace to persist within instance.
  # We copy the downloaded file into dir with its basename.
  "$PYTHON_BIN" - <<'PY' "$repo_id" "$rev" "$file_path" "$dir"
import os, sys
repo_id, rev, file_path, out_dir = sys.argv[1:5]
token = os.environ.get("HF_TOKEN") or None

try:
    from huggingface_hub import hf_hub_download
except Exception as e:
    print("[provision] huggingface_hub not available:", e)
    sys.exit(2)

try:
    # hf_transfer is automatically used when HF_HUB_ENABLE_HF_TRANSFER=1 and package is installed
    local_path = hf_hub_download(
        repo_id=repo_id,
        filename=file_path,
        revision=rev,
        token=token,
        # put cache in workspace to avoid filling root
        cache_dir="/workspace/.hf_cache",
    )
    os.makedirs(out_dir, exist_ok=True)
    dst = os.path.join(out_dir, os.path.basename(file_path))
    # Copy (not symlink) to ensure Comfy sees it directly in models dir
    import shutil
    shutil.copy2(local_path, dst)
    print(f"[provision] HF (hf_transfer) downloaded OK -> {dst}")
except Exception as e:
    print("[provision] HF (hf_transfer) failed:", repr(e))
    sys.exit(1)
PY

  # python exits 0 on success, nonzero on fail
  if [[ $? -eq 0 ]]; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------------
# Downloader: Civitai uses Content-Disposition; HF uses basename
# (HuggingFace now tries hf_transfer first)
# ------------------------------------------------------------
provisioning_download_to_dir() {
  local dir="$1"
  local url="$2"
  mkdir -p "$dir"

  local final_url="$url"
  local auth_header=""

  # HF auth header (optional)
  if [[ -n "${HF_TOKEN:-}" ]] && [[ "$url" =~ huggingface\.co ]]; then
    auth_header="Authorization: Bearer ${HF_TOKEN}"
  fi

  # Civitai token append (optional)
  if [[ -n "${CIVITAI_TOKEN:-}" ]] && [[ "$url" =~ civitai\.com ]]; then
    if [[ "$url" == *"?"* ]]; then
      final_url="${url}&token=${CIVITAI_TOKEN}"
    else
      final_url="${url}?token=${CIVITAI_TOKEN}"
    fi
  fi

  log "Downloading into $dir"
  log "  from: $final_url"

  # ---- HuggingFace: try hf_transfer path first (added) ----
  if [[ "$url" =~ huggingface\.co ]]; then
    if provisioning_hf_transfer_download "$dir" "$final_url"; then
      return 0
    else
      log "HF (hf_transfer) unavailable/failed -> fallback to aria2/wget/curl"
    fi
  fi

  # ---- Civitai: use content-disposition to get true filename ----
  if [[ "$url" =~ civitai\.com ]]; then
    if command -v aria2c >/dev/null 2>&1; then
      aria2c -x 16 -s 16 -k 1M --content-disposition -d "$dir" "$final_url"
      return 0
    fi
    if command -v wget >/dev/null 2>&1; then
      wget --content-disposition --show-progress -qnc -P "$dir" "$final_url"
      return 0
    fi
    (cd "$dir" && curl -fL -OJ "$final_url")
    return 0
  fi

  # ---- HuggingFace (and general URLs with a real filename): save as URL basename ----
  local name="${url%%\?*}"
  name="${name##*/}"

  # If basename is empty or looks like a pure numeric id, fall back to content-disposition
  if [[ -z "$name" || "$name" =~ ^[0-9]+$ ]]; then
    if command -v aria2c >/dev/null 2>&1; then
      if [[ -n "$auth_header" ]]; then
        aria2c -x 16 -s 16 -k 1M --content-disposition --header="$auth_header" -d "$dir" "$final_url"
      else
        aria2c -x 16 -s 16 -k 1M --content-disposition -d "$dir" "$final_url"
      fi
      return 0
    fi
    if [[ -n "$auth_header" ]]; then
      (cd "$dir" && curl -fL -H "$auth_header" -OJ "$final_url")
    else
      (cd "$dir" && curl -fL -OJ "$final_url")
    fi
    return 0
  fi

  if command -v aria2c >/dev/null 2>&1; then
    if [[ -n "$auth_header" ]]; then
      aria2c -x 16 -s 16 -k 1M --header="$auth_header" -o "$name" -d "$dir" "$final_url"
    else
      aria2c -x 16 -s 16 -k 1M -o "$name" -d "$dir" "$final_url"
    fi
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    if [[ -n "$auth_header" ]]; then
      wget --header="$auth_header" -O "$dir/$name" "$final_url"
    else
      wget -O "$dir/$name" "$final_url"
    fi
    return 0
  fi

  if [[ -n "$auth_header" ]]; then
    curl -fL -H "$auth_header" -o "$dir/$name" "$final_url"
  else
    curl -fL -o "$dir/$name" "$final_url"
  fi
}

provisioning_get_models_dir_urlonly() {
  local dir="$1"; shift || true
  local arr=("$@")
  if [[ ${#arr[@]} -eq 0 ]]; then
    return 0
  fi
  for url in "${arr[@]}"; do
    provisioning_download_to_dir "$dir" "$url"
  done
}

provisioning_get_nodes() {
  local nodes_dir="${COMFY_WORKSPACE}/custom_nodes"
  mkdir -p "$nodes_dir"

  for repo in "${NODES[@]}"; do
    local dir="${repo##*/}"
    local path="${nodes_dir}/${dir}"
    local requirements="${path}/requirements.txt"

    if [[ -d "$path/.git" ]]; then
      log "Updating node: $repo"
      git -C "$path" pull --ff-only || true
    else
      log "Cloning node: $repo"
      git clone --depth=1 --recursive "$repo" "$path"
    fi

    if [[ -f "$requirements" ]]; then
      log "Installing requirements: $requirements"
      pip_install -r "$requirements" || true
    fi
  done
}

provisioning_start() {
  normalize_comfy_paths

  provisioning_get_apt_packages
  provisioning_get_nodes
  provisioning_get_pip_packages

  # Enable hf_transfer once before downloads (added)
  provisioning_enable_hf_transfer

  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/checkpoints"    "${CHECKPOINT_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/unet"           "${UNET_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/loras"          "${LORA_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/controlnet"     "${CONTROLNET_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/vae"            "${VAE_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/upscale_models" "${UPSCALE_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
  provisioning_get_models_dir_urlonly "${COMFY_WORKSPACE}/models/text_encoders"   "${TEXT_ENCODER_MODELS[@]}"

  log "Provisioning complete."
}

provisioning_start
