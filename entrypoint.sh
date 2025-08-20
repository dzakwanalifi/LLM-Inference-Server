#!/bin/bash
set -euo pipefail

# --- Konfigurasi ---
MODEL_DIR="/app/models"
APP_USER="appuser"
MODEL_NAME="DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
MODEL_URL="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
EXPECTED_CHECKSUM="${MODEL_CHECKSUM:-}"
DOWNLOAD_TIMEOUT=1800
MAX_RETRIES=3

# --- Fungsi ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - ENTRYPOINT - $1"
}
verify_checksum() {
    local file_path="$1"; if [ -z "$EXPECTED_CHECKSUM" ]; then log "WARNING: MODEL_CHECKSUM not set. Skipping verification."; return 0; fi
    log "Verifying checksum..."; actual_checksum=$(sha256sum "$file_path" | awk '{print $1}'); if [ "$actual_checksum" = "$EXPECTED_CHECKSUM" ]; then log "Checksum PASSED."; return 0;
    else log "ERROR: Checksum FAILED!"; log "Expected: $EXPECTED_CHECKSUM"; log "Got:      $actual_checksum"; return 1; fi
}
download_model() {
    local retry_count=0; while [ $retry_count -lt $MAX_RETRIES ]; do
        log "Download attempt #$((retry_count + 1))..."; if timeout "$DOWNLOAD_TIMEOUT" wget --continue -O "${MODEL_PATH}.tmp" "$MODEL_URL"; then
            if verify_checksum "${MODEL_PATH}.tmp"; then mv "${MODEL_PATH}.tmp" "$MODEL_PATH"; log "Model downloaded successfully."; return 0;
            else rm -f "${MODEL_PATH}.tmp"; fi
        else log "Download failed or timed out."; fi
        retry_count=$((retry_count + 1)); if [ $retry_count -lt $MAX_RETRIES ]; then log "Retrying in 15s..."; sleep 15; fi
    done; log "ERROR: Failed to download model."; return 1
}

# --- Eksekusi Utama ---
# Script ini dimulai sebagai ROOT
log "Initializing container (running as $(whoami))..."

# ==============================================================================
# LANGKAH 1: Perbaiki Izin Volume
# Pastikan direktori models ada dan dimiliki oleh APP_USER.
log "Fixing ownership for $MODEL_DIR..."
mkdir -p "$MODEL_DIR"
chown -R "$APP_USER":"$APP_USER" "$MODEL_DIR"
# ==============================================================================

# LANGKAH 2: Lakukan Logika Download (masih sebagai ROOT)
if [ -f "$MODEL_PATH" ]; then
    log "Model file found. Verifying..."
    if ! verify_checksum "$MODEL_PATH"; then
        log "Invalid model. Re-downloading..."; rm -f "$MODEL_PATH"; download_model
    else log "Existing model is valid."; fi
else
    log "Model file not found. Starting download..."; download_model
fi

if [ ! -f "$MODEL_PATH" ]; then
    log "FATAL: Model file is missing. Exiting."; exit 1
fi

# ==============================================================================
# LANGKAH 3: Drop Privileges & Jalankan Aplikasi Utama
# 'exec gosu' akan menggantikan proses shell ini dengan proses Gunicorn,
# tetapi menjalankannya sebagai APP_USER. "$@" adalah CMD dari Dockerfile.
log "Initialization complete. Dropping privileges and starting application as '$APP_USER'..."
exec gosu "$APP_USER" "$@"
# ==============================================================================