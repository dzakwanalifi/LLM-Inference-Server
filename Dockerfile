# syntax=docker/dockerfile:1.9
# --- Base Stage ---
# Stage ini berisi setup yang sama untuk builder dan production
FROM python:3.11-slim-bookworm AS base

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Install paket sistem yang dibutuhkan di KEDUA stage (production & build)
# Menginstall di base stage akan di-cache
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

################################################################################
# --- Builder Stage ---
# Stage ini hanya untuk menginstall dependensi Python
################################################################################
FROM base AS builder

# Install build-essential HANYA di builder stage
RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*

# Copy uv dari image resmi Astral. Ini lebih aman dan cepat.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Set WORKDIR
WORKDIR /app

# Copy file dependensi
COPY pyproject.toml uv.lock ./

# Install dependensi menggunakan uv dengan caching mount superior
# Layer ini hanya akan di-rebuild jika uv.lock atau pyproject.toml berubah.
# Build selanjutnya akan SANGAT CEPAT.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --system --no-cache-dir -r uv.lock

################################################################################
# --- Production Stage ---
# Stage final ini adalah image yang akan kita jalankan.
################################################################################
FROM base AS production

# Buat user non-root
RUN groupadd -r appuser && useradd --no-log-init -r -g appuser appuser

# Copy Python packages yang sudah terinstall dari builder stage
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Set WORKDIR dan kepemilikan
WORKDIR /app
RUN chown appuser:appuser /app

# Ganti ke user non-root
USER appuser

# Copy kode aplikasi dan entrypoint
COPY ./app ./app
COPY ./entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

# Entrypoint akan dijalankan sebagai 'appuser'
ENTRYPOINT ["./entrypoint.sh"]
CMD ["gunicorn", "app.main:app", "--workers", "4", "--worker-class", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000"]