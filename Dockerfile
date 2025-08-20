# Fase 1: Base Image dan Instalasi Dependensi Sistem
FROM python:3.11-slim-bookworm AS builder

# Set working directory di dalam kontainer
WORKDIR /app

# Install build tools yang dibutuhkan oleh llama-cpp-python dan wget untuk entrypoint
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install uv, package installer yang sangat cepat
RUN pip install uv

# Salin file pyproject.toml dan install dependensi proyek menggunakan uv
COPY pyproject.toml .
RUN uv pip install --system --no-cache-dir .


# Fase 2: Final Image
FROM python:3.11-slim-bookworm

# Set environment variable untuk memastikan output Python tidak di-buffer
ENV PYTHONUNBUFFERED 1

# Buat grup dan user non-root bernama 'appuser'
RUN groupadd -r appuser && useradd --no-log-init -r -g appuser appuser

# Set working directory
WORKDIR /app

# Salin dependensi Python yang sudah ter-install dari stage builder
# Pastikan direktori tujuan dimiliki oleh user baru
RUN mkdir -p /home/appuser/.local && chown -R appuser:appuser /home/appuser
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Salin kode aplikasi dan script entrypoint, dan set kepemilikan
COPY --chown=appuser:appuser ./app ./app
COPY --chown=appuser:appuser ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Ganti kepemilikan seluruh working directory
RUN chown -R appuser:appuser /app

# Ganti ke user non-root
USER appuser

# Perintah default yang akan dieksekusi oleh entrypoint
# Menggunakan Gunicorn sebagai process manager dengan 4 worker Uvicorn
CMD ["gunicorn", "app.main:app", "--workers", "4", "--worker-class", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000"]

# Tentukan entrypoint yang akan dijalankan saat kontainer start
ENTRYPOINT ["/entrypoint.sh"]