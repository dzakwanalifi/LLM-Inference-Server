#!/bin/bash
set -euo pipefail

# Ensure we're running with bash
if [ -z "$BASH_VERSION" ]; then
    exec /bin/bash "$0" "$@"
fi

# --- Konfigurasi ---
MODEL_DIR="/app/models"
MODEL_NAME="DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
MODEL_URL="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"

# Checksum dari environment variable
EXPECTED_CHECKSUM="${MODEL_CHECKSUM:-}"

DOWNLOAD_TIMEOUT=1800
MAX_RETRIES=3

# --- Fungsi ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - ENTRYPOINT - $1"
}

verify_checksum() {
    local file_path="$1"
    
    if [ -z "$EXPECTED_CHECKSUM" ]; then
        log "WARNING: MODEL_CHECKSUM environment variable not set. Skipping verification."
        return 0
    fi
    
    log "Verifying checksum for $file_path..."
    actual_checksum=$(sha256sum "$file_path" | awk '{print $1}')
    
    if [ "$actual_checksum" = "$EXPECTED_CHECKSUM" ]; then
        log "Checksum verification PASSED."
        return 0
    else
        log "ERROR: Checksum verification FAILED!"
        log "Expected: $EXPECTED_CHECKSUM"
        log "Got:      $actual_checksum"
        return 1
    fi
}

download_model() {
    local retry_count=0
    while [ $retry_count -lt $MAX_RETRIES ]; do
        log "Download attempt #$((retry_count + 1)) of $MAX_RETRIES..."
        
        if timeout "$DOWNLOAD_TIMEOUT" wget --continue -O "${MODEL_PATH}.tmp" "$MODEL_URL"; then
            log "Download command finished. Verifying integrity..."
            if verify_checksum "${MODEL_PATH}.tmp"; then
                mv "${MODEL_PATH}.tmp" "$MODEL_PATH"
                log "Model downloaded and verified successfully."
                return 0
            else
                rm -f "${MODEL_PATH}.tmp"
            fi
        else
            log "Download command failed or timed out."
        fi

        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $MAX_RETRIES ]; then
            log "Retrying in 15 seconds..."
            sleep 15
        fi
    done

    log "ERROR: Failed to download model after $MAX_RETRIES attempts."
    return 1
}

# --- Eksekusi Utama ---
log "Initializing container..."
mkdir -p "$MODEL_DIR"

if [ -f "$MODEL_PATH" ]; then
    log "Model file found."
    if verify_checksum "$MODEL_PATH"; then
        log "Existing model is valid. Skipping download."
    else
        log "Existing model is invalid or corrupt. Re-downloading..."
        rm -f "$MODEL_PATH"
        download_model
    fi
else
    log "Model file not found. Starting download..."
    download_model
fi

if [ ! -f "$MODEL_PATH" ]; then
    log "FATAL: Model file is missing and could not be downloaded. Exiting."
    exit 1
fi

log "Initialization complete. Starting application..."
exec "$@"
