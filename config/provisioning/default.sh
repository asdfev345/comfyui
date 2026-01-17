#!/bin/bash

# 패키지 및 노드 설정
APT_PACKAGES=()
PIP_PACKAGES=()
NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/cubiq/ComfyUI_essentials"
)

# 모델 링크 (Civitai 등)
CHECKPOINT_MODELS=(
    "https://civitai.com/api/download/models/2537327?type=Model&format=SafeTensor&size=full&fp=bf16"
)

UNET_MODELS=()
LORA_MODELS=()
VAE_MODELS=()
UPSCALE_MODELS=()
CONTROLNET_MODELS=()

### 수정한 핵심 로직 ###

function provisioning_start() {
    # 1. 환경 변수 강제 지정 (Vast.ai 환경 대응)
    WORKSPACE="/workspace"
    # ai-dock 경로가 없을 경우를 대비한 방어 코드
    if [[ -f /opt/ai-dock/etc/environment.sh ]]; then
        source /opt/ai-dock/etc/environment.sh
    fi
    
    # ComfyUI 실제 설치 경로 확인 (보통 /opt/ComfyUI 또는 /workspace/ComfyUI)
    COMFYUI_ROOT="/opt/ComfyUI"
    if [[ ! -d $COMFYUI_ROOT ]]; then
        COMFYUI_ROOT="/workspace/ComfyUI"
    fi

    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages
    
    # 2. 모델 저장 경로를 ComfyUI 표준 경로로 변경
    provisioning_get_models \
        "${COMFYUI_ROOT}/models/checkpoints" \
        "${CHECKPOINT_MODELS[@]}"
    provisioning_get_models \
        "${COMFYUI_ROOT}/models/unet" \
        "${UNET_MODELS[@]}"
    provisioning_get_models \
        "${COMFYUI_ROOT}/models/loras" \
        "${LORA_MODELS[@]}"
    provisioning_get_models \
        "${COMFYUI_ROOT}/models/controlnet" \
        "${CONTROLNET_MODELS[@]}"
    provisioning_get_models \
        "${COMFYUI_ROOT}/models/vae" \
        "${VAE_MODELS[@]}"
    provisioning_get_models \
        "${COMFYUI_ROOT}/models/upscale_models" \
        "${UPSCALE_MODELS[@]}"
        
    provisioning_print_end
}

# PIP 설치 함수 (에러 방지용 수정)
function pip_install() {
    pip install --no-cache-dir "$@"
}

function provisioning_get_apt_packages() {
    if [[ -n $APT_PACKAGES ]]; then
        sudo apt-get update && sudo apt-get install -y ${APT_PACKAGES[@]}
    fi
}

function provisioning_get_pip_packages() {
    if [[ -n $PIP_PACKAGES ]]; then
        pip_install ${PIP_PACKAGES[@]}
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="/opt/ComfyUI/custom_nodes/${dir}"
        # 경로가 없으면 /workspace 쪽 확인
        if [[ ! -d /opt/ComfyUI ]]; then path="/workspace/ComfyUI/custom_nodes/${dir}"; fi
        
        if [[ -d $path ]]; then
            printf "Updating node: %s...\n" "${repo}"
            ( cd "$path" && git pull )
        else
            printf "Downloading node: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
        fi
        if [[ -f "${path}/requirements.txt" ]]; then
            pip_install -r "${path}/requirements.txt"
        fi
    done
}

function provisioning_get_models() {
    if [[ -z $2 ]]; then return 1; fi
    dir="$1"
    mkdir -p "$dir"
    shift
    arr=("$@")
    for url in "${arr[@]}"; do
        printf "Downloading: %s to %s\n" "${url}" "$dir"
        provisioning_download "${url}" "${dir}"
    done
}

function provisioning_download() {
    # Civitai나 HuggingFace 토큰이 환경변수로 있을 경우 처리
    local auth_header=""
    if [[ $1 =~ "huggingface.co" && -n $HF_TOKEN ]]; then
        auth_header="Authorization: Bearer $HF_TOKEN"
    elif [[ $1 =~ "civitai.com" && -n $CIVITAI_TOKEN ]]; then
        auth_header="Authorization: Bearer $CIVITAI_TOKEN"
    fi

    if [[ -n $auth_header ]]; then
        wget --header="$auth_header" -qnc --content-disposition --show-progress -P "$2" "$1"
    else
        wget -qnc --content-disposition --show-progress -P "$2" "$1"
    fi
}

function provisioning_print_header() {
    printf "\n# Starting Provisioning #\n"
}

function provisioning_print_end() {
    printf "\n# Provisioning Complete #\n"
}

provisioning_start
