# --- Base Stage ---
FROM python:3.11-slim-bookworm AS base

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

################################################################################
# --- Builder Stage ---
################################################################################
FROM base AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install uv
RUN pip install uv

# Create app directory
WORKDIR /app

# Copy project files
COPY pyproject.toml uv.lock ./

# Install dependencies using uv
RUN uv pip install --system --no-cache-dir -r uv.lock

# Copy application code
COPY ./app ./app
COPY ./entrypoint.sh ./entrypoint.sh

# Ensure entrypoint.sh has execute permissions
RUN chmod +x ./entrypoint.sh

################################################################################
# --- Production Stage ---
################################################################################
FROM base AS production

# Install runtime dependencies including OpenMP library
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r appuser && useradd --no-log-init -r -g appuser appuser

# Copy Python packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy application code and entrypoint from builder
COPY --from=builder /app /app

# Set ownership dan permissions untuk SEMUA files dan directories
RUN chown -R appuser:appuser /app && \
    chmod -R 755 /app && \
    chmod +x /app/entrypoint.sh

# Switch to non-root user
USER appuser
WORKDIR /app

# Perintah default yang akan dieksekusi oleh entrypoint
CMD ["gunicorn", "app.main:app", "--workers", "4", "--worker-class", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000"]

# Tentukan entrypoint yang akan dijalankan saat kontainer start
ENTRYPOINT ["/bin/bash", "./entrypoint.sh"]