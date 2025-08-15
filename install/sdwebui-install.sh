#!/usr/bin/env bash
# Inside-container installer for AUTOMATIC1111 Stable Diffusion Web UI on Debian 12 LXC.
# Adds interactive toggles for: xformers + sample checkpoint download (via HF token).

# Inherited helper functions from the Proxmox launcher:
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ---- Small prompt helper ----
prompt_bool() {
  local prompt="$1" default="${2:-n}" reply
  local hint="y/N"; [[ "$default" =~ ^[Yy]$ ]] && hint="Y/n"
  read -r -p "$prompt [$hint]: " reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---- Read flags from env or ask interactively ----
# INSTALL_XFORMERS: y/n/ask
# INSTALL_SAMPLE_CKPT: y/n/ask
# HF_TOKEN: Hugging Face token for gated models (optional but required for popular checkpoints)
INSTALL_XFORMERS="${INSTALL_XFORMERS:-ask}"
INSTALL_SAMPLE_CKPT="${INSTALL_SAMPLE_CKPT:-ask}"
HF_TOKEN="${HF_TOKEN:-}"

if [[ "$INSTALL_XFORMERS" == "ask" ]]; then
  if prompt_bool "Install xformers (GPU-only; requires NVIDIA/CUDA)?" "n"; then
    INSTALL_XFORMERS="y"
  else
    INSTALL_XFORMERS="n"
  fi
fi

if [[ "$INSTALL_SAMPLE_CKPT" == "ask" ]]; then
  if prompt_bool "Download a sample Stable Diffusion checkpoint (requires a Hugging Face token for most models)?" "n"; then
    INSTALL_SAMPLE_CKPT="y"
  else
    INSTALL_SAMPLE_CKPT="n"
  fi
fi

if [[ "$INSTALL_SAMPLE_CKPT" == "y" && -z "$HF_TOKEN" ]]; then
  echo -e "${YW}No HF token provided. You can paste one now (input hidden). Press Enter to skip.${CL}"
  read -r -s -p "HF_TOKEN: " HF_TOKEN
  echo
fi

# ---- Base dependencies ----
msg_info "Installing Dependencies"
$STD apt-get install -y \
  wget git git-lfs \
  python3 python3-venv \
  libgl1 libglib2.0-0
git lfs install
msg_ok "Installed Dependencies"


msg_info "Installing NVIDIA Drivers"
NVIDIA_DRIVER_VERSION="580.76.05"
# Install nvidia drivers.
if wget -O "NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run" "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"; then
  msg_ok "Nvidia driver downloaded"
  chmod +x "NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
  # Run the installer in silent mode, accepting the license.
  if bash -c "./NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run --silent --accept-license --no-kernel-modules --run-nvidia-xconfig --disable-nouveau"; then
      msg_ok "NVIDIA driver installed successfully"
      rm -f "NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
  else
      msg_error "Failed to install NVIDIA driver. Please check the logs."
      rm -f "NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
      exit 1
  fi
  # Check if the driver was installed correctly
  if nvidia-smi >/dev/null 2>&1; then
    msg_ok "NVIDIA driver is installed and working"
  else
    msg_error "NVIDIA driver installation failed. Please check the logs."
    exit 1
  fi
else
  msg_warn "Failed to download driver license. Skipping."
  rm -f "NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
fi


# ---- Clone repo ----
INSTALL_DIR="/opt/stable-diffusion-webui"
if [[ ! -d "$INSTALL_DIR" ]]; then
  msg_info "Cloning AUTOMATIC1111 repository"
  $STD git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui "$INSTALL_DIR"
  msg_ok "Repository Cloned"
else
  msg_ok "Repository already present at $INSTALL_DIR"
fi


# ---- Torch / bootstrap ----
# Default to CPU torch (safe for LXC). If GPU is passed through, user can remove this later.
export TORCH_COMMAND="pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu"
export PIP_ALLOW_EXTERNAL=true
export PIP_ALLOW_UNVERIFIED=true

msg_info "Bootstrapping webui (first run to create venv and install Torch)"
cd "$INSTALL_DIR" || exit
bash -lc 'cd '"$INSTALL_DIR"' && ./webui.sh --exit --skip-torch-cuda-test'
msg_ok "Bootstrap Complete"

# ---- Optional: xformers (GPU-only) ----
if [[ "$INSTALL_XFORMERS" == "y" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    msg_info "Installing xformers (GPU detected)"
    # Enter venv and install matching xformers. The webui venv is under ./venv by default.
    sudo -u sdwebui bash -lc 'source /opt/stable-diffusion-webui/venv/bin/activate && pip install --upgrade pip && pip install xformers'
    msg_ok "xformers installed"
  else
    msg_warn "No NVIDIA GPU detected inside the container. Skipping xformers."
  fi
fi

# ---- Optional: Sample checkpoint download ----
MODELS_DIR="$INSTALL_DIR/models/Stable-diffusion"
mkdir -p "$MODELS_DIR"
if [[ "$INSTALL_SAMPLE_CKPT" == "y" ]]; then
  # Best-effort: download SD 1.5 ema-only checkpoint if HF token is provided.
  # You must have accepted the model license on Hugging Face.
  FILE="$MODELS_DIR/v1-5-pruned-emaonly.safetensors"
  if [[ -f "$FILE" ]]; then
    msg_ok "Sample checkpoint already present: $(basename "$FILE")"
  else
    if [[ -n "$HF_TOKEN" ]]; then
      msg_info "Downloading sample checkpoint from Hugging Face (requires accepted license)"
      URL="https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"
      # Use Authorization header for gated model
      if wget --header="Authorization: Bearer ${HF_TOKEN}" -O "$FILE" "$URL"; then
        chown sdwebui:sdwebui "$FILE"
        msg_ok "Sample checkpoint downloaded"
      else
        msg_warn "Failed to download checkpoint (token invalid or license not accepted). Skipping."
        rm -f "$FILE"
      fi
    else
      msg_warn "HF token not provided; cannot auto-download gated checkpoints. Skipping sample model."
    fi
  fi
fi

# ---- systemd service ----
msg_info "Creating systemd service"
cat <<'EOF' >/etc/systemd/system/sd-webui.service
[Unit]
Description=Stable Diffusion Web UI (AUTOMATIC1111)
After=network.target

[Service]
Type=simple
User=sdwebui
Group=sdwebui
WorkingDirectory=/opt/stable-diffusion-webui
Environment=TORCH_COMMAND=pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
ExecStart=/bin/bash -lc '/opt/stable-diffusion-webui/webui.sh --listen 0.0.0.0 --port 7860 --skip-torch-cuda-test --api'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q --now sd-webui.service
msg_ok "Service Created"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
