# syntax=docker/dockerfile:1.9
# --- Base Stage ---
    FROM python:3.11-slim-bookworm AS base
    ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
    
    # Install paket sistem yang dibutuhkan di KEDUA stage
    RUN apt-get update && apt-get install -y --no-install-recommends \
        wget \
        libgomp1 \
        && rm -rf /var/lib/apt/lists/*
    
    ################################################################################
    # --- Builder Stage ---
    ################################################################################
    FROM base AS builder
    RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
    COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
    WORKDIR /app
    COPY pyproject.toml uv.lock ./
    RUN --mount=type=cache,target=/root/.cache/uv \
        uv pip install --system --no-cache-dir -r uv.lock
    
    ################################################################################
    # --- Production Stage ---
    ################################################################################
    FROM base AS production
    
    # ==============================================================================
    # PERUBAHAN 1: Install 'gosu' untuk privilege dropping yang aman
    RUN apt-get update && apt-get install -y --no-install-recommends gosu && rm -rf /var/lib/apt/lists/*
    # ==============================================================================
    
    # Buat user non-root
    RUN groupadd -r appuser && useradd --no-log-init -r -g appuser appuser
    
    # Copy Python packages dari builder
    COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
    COPY --from=builder /usr/local/bin /usr/local/bin
    
    WORKDIR /app
    
    # Copy kode aplikasi dan entrypoint
    COPY --chown=appuser:appuser ./app ./app
    COPY ./entrypoint.sh ./entrypoint.sh 
    RUN chmod +x ./entrypoint.sh
    
    # ==============================================================================
    # PERUBAHAN 2: HAPUS `USER appuser` dari sini.
    # Entrypoint harus berjalan sebagai root terlebih dahulu untuk memperbaiki izin.
    # ==============================================================================
    
    ENTRYPOINT ["./entrypoint.sh"]
    CMD ["gunicorn", "app.main:app", "--workers", "4", "--worker-class", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000"]