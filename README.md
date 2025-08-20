# LLM Inference Server

[![Python Version](https://img.shields.io/badge/Python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![FastAPI](https://img.shields.io/badge/FastAPI-005571?style=for-the-badge&logo=fastapi)](https://fastapi.tiangolo.com/)

A production-ready, high-performance, and secure FastAPI server for local LLM inference. This project is optimized for CPU-only environments and leverages `llama.cpp` for efficient model execution. It is designed to be deployed easily and reliably using Docker.

## 🌟 Core Features

- **🚀 High-Performance Inference**: Utilizes `llama.cpp` for fast, CPU-optimized model execution
- **⚡ Asynchronous & Concurrent**: Non-blocking API endpoints with a `ThreadPoolExecutor` to handle multiple requests simultaneously without freezing the server
- **🏭 Production-Grade Serving**: Managed by Gunicorn with multiple Uvicorn workers for scalability and resilience
- **🔒 Robust Security**:
  - API Key authentication (Bearer Token)
  - Rate limiting to prevent abuse (via `slowapi`)
  - Strict input validation and basic prompt injection detection
  - Secure Docker container running as a non-root user
- **📊 Comprehensive Observability**:
  - Structured JSON logging with `structlog` for easy parsing and analysis
  - Automatic request tracing with unique IDs
  - Detailed performance metrics per request (inference time, token counts)
- **🤖 Automated & Reliable Deployment**:
  - Containerized with Docker for consistency across environments
  - Robust startup script (`entrypoint.sh`) that automatically downloads the model with retry logic and checksum verification
  - Persistent model storage using Docker Volumes
- **🩺 Advanced Health Monitoring**: An intelligent `/health` endpoint that performs a dummy inference to ensure the model is not just loaded, but fully functional
- **🔧 Modern Python Tooling**: Uses `pyproject.toml` for dependency management and `uv.lock` for deterministic, reproducible builds with `uv` for lightning-fast package installation during the Docker build process

## 📋 Requirements

- Python 3.11+
- Docker & Docker Compose
- At least 4GB RAM (8GB recommended)
- Multi-core CPU (4+ cores recommended)

## 🏗️ Project Structure

The project is organized to separate concerns, making it clean and maintainable.

```
llm-server/
├── app/
│   └── main.py              # The core FastAPI application logic.
├── models/                  # (Created on first run) Stores the downloaded GGUF model files.
├── .env                     # Local environment variables (API Key, Checksum).
├── .env.example             # Template for creating the .env file.
├── Dockerfile               # Advanced multi-stage recipe for the secure, optimized Docker image.
├── docker-compose.yml       # Defines and orchestrates the Docker service.
├── entrypoint.sh            # Robust startup script for the container.
├── pyproject.toml           # Defines project metadata and dependencies.
└── uv.lock                  # Lockfile for deterministic, reproducible builds.
```

## 🚀 Getting Started (Docker Required)

This project is optimized for a Docker-centric workflow.

### Prerequisites

- [Docker](https://www.docker.com/products/docker-desktop/) installed and running
- [Git](https://git-scm.com/) for cloning the repository
- A terminal or command prompt (like PowerShell or Bash)

### 1. Clone the Repository

```bash
git clone https://github.com/dzakwanalifi/llm-inference-server.git
cd llm-inference-server
```

### 2. Configure Your Environment

Create your local environment file from the example template.

```bash
cp .env.example .env
```

Now, **open the `.env` file** with a text editor and set a strong, unique `API_KEY`. The `MODEL_CHECKSUM` is already provided for the default model.

```env
# .env
API_KEY="sk-this-is-my-very-secret-and-strong-api-key"
MODEL_CHECKSUM="07e4917a026e6f9b69992a5433d9f37c376174a2ff4389658f696e57285227ec"
```

### 3. Generate the Lockfile (Crucial First Step)
This project uses `uv.lock` for fast, deterministic builds. You need to generate it locally once.

First, install `uv` on your local machine:
```bash
pip install uv
```

Then, generate the lockfile from `pyproject.toml`:
```bash
uv pip compile pyproject.toml -o uv.lock
```
*Note: You only need to re-run this command if you change the dependencies in `pyproject.toml`.*

### 4. Build and Run the Container

Now you are ready to build the image and start the service.

```bash
docker-compose up --build
```

**What to Expect on First Run:**
- **Docker Build:** The image will be built using `uv`, which is 10-100x faster than traditional pip
- **Model Download:** The `entrypoint.sh` script will detect that the model is missing and begin downloading it (~1.1 GB). This may take several minutes depending on your internet connection. You will see progress logs
- **Model Loading:** Once downloaded, the model will be loaded into RAM
- **Server Ready:** You'll see logs from Gunicorn/Uvicorn indicating the server is running on `http://0.0.0.0:8000`

The server is now accessible on `http://localhost:8080` on your host machine.

To run the server in the background (detached mode):

```bash
docker-compose up --build -d
```

To stop the server:

```bash
docker-compose down
```



## 🔧 Configuration & Tuning

### Environment Variables

The server is configured via environment variables defined in the `.env` file.

| Variable | Description | Default (in code) |
| :--- | :--- | :--- |
| `API_KEY` | **Required.** Secret key for API authentication. | `default-secret-key` |
| `MODEL_CHECKSUM`| **Recommended.** The SHA256 checksum of the GGUF model for integrity verification. | `""` (empty) |

### Performance Tuning (`app/main.py`)

You can fine-tune the `llama.cpp` parameters within the `lifespan` function in `app/main.py` for optimal performance on your hardware.

```python
llm = Llama(
    model_path=str(MODEL_PATH),
    n_ctx=4096,           # Context window size
    n_threads=4,          # Crucial: Set to the number of PHYSICAL CPU cores
    n_batch=1024,         # Can increase if you have more RAM, speeds up long prompt processing
    n_ubatch=512,         # Physical batch size, affects memory
    mlock=True,           # Highly recommended to lock the model in RAM
    n_gpu_layers=0,       # GPU layers (0 = CPU only)
    verbose=False
)
```

### Gunicorn Workers (`Dockerfile`)

The number of worker processes is set in the `CMD` instruction of the `Dockerfile`. A good starting point is `(2 * number of CPU cores) + 1`.

```dockerfile
# In Dockerfile
CMD ["gunicorn", "app.main:app", "--workers", "4", ...]
```

## 📡 API Usage

### Health Check Endpoint

A vital endpoint for monitoring and orchestration systems. It verifies that the model is loaded and functional.

**Request:**
```bash
curl http://localhost:8080/health
```

**Healthy Response (HTTP 200):**
```json
{
  "status": "healthy",
  "checks": {
    "model_loaded": true,
    "inference_functional": true
  }
}
```

**Unhealthy Response (HTTP 503):**
If the model fails the dummy inference test, the server will return a 503 Service Unavailable error.

### Chat Completions Endpoint

The main endpoint for interacting with the LLM. It's compatible with the OpenAI chat completions format.

**Request:**
```bash
curl -X POST "http://localhost:8080/v1/chat/completions" \
  -H "Authorization: Bearer sk-this-is-my-very-secret-and-strong-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "Explain the importance of structured logging in a production application."}
    ],
    "max_tokens": 150,
    "temperature": 0.7
  }'
```

**Example Response (HTTP 200):**
```json
{
  "id": "chatcmpl-1718895514",
  "object": "chat.completion",
  "created": 1718895514,
  "model": "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Structured logging is crucial in production because it transforms log entries from plain text into a machine-readable format like JSON. This allows for efficient searching, filtering, and analysis using log management tools. It enables automated alerting, dashboard creation, and makes debugging complex, distributed systems significantly faster and more reliable by providing consistent context for every event."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 23,
    "completion_tokens": 89,
    "total_tokens": 112
  }
}
```

## 🔒 Security Features

- **API Key Authentication** - Bearer token required for all requests
- **Rate Limiting** - 15 requests per minute per IP address
- **Prompt Injection Protection** - Detects and blocks malicious prompts
- **Input Validation** - Strict validation of request parameters
- **Memory Protection** - Limits prompt length and token usage
- **Secure Container** - Runs as non-root user with minimal privileges

## 📊 Monitoring & Logging

- **Structured JSON Logs** with request tracking
- **Request ID Tracking** for debugging
- **Performance Metrics** including inference time
- **Health Monitoring** with automatic checks
- **Error Tracking** with detailed stack traces
- **Real-time Health Checks** with dummy inference testing

## 🐳 Docker Architecture Deep Dive

The `Dockerfile` is highly optimized for both speed and security using modern best practices.

### Container Features
-   **Advanced Multi-Stage Build**: Separates the build environment from the lean production environment, resulting in a smaller and more secure final image.
-   **Blazing Fast Dependency Installation**: Uses `uv` instead of `pip` for 10-100x faster package installation during the build process.
-   **Superior Layer Caching**: Leverages Docker BuildKit's `--mount=type=cache` to cache dependencies effectively. Rebuilding after a code change is nearly instantaneous.
-   **Clean Virtual Environment**: All dependencies are installed into an isolated virtual environment inside the container, not into the global site-packages.
-   **Security Hardened**: The final image runs the application as a **non-root user** with minimal system dependencies.
-   **Robust Startup**: The `entrypoint.sh` script handles model downloading, verification, and retries before starting the main application.

### Build Arguments

```dockerfile
# Customize these in Dockerfile if needed
ARG PYTHON_VERSION=3.11-slim-bookworm
ARG USER_ID=1000
ARG GROUP_ID=1000
```

### Multi-stage Build

The Dockerfile uses a multi-stage approach:
1. **Builder stage**: Installs build dependencies and Python packages
2. **Runtime stage**: Creates minimal production image with only necessary files

## 🧪 Testing

### Health Check

```bash
curl http://localhost:8080/health
```

### API Test

```bash
curl -X POST "http://localhost:8080/v1/chat/completions" \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'
```

### Load Testing

For production deployments, consider using tools like:
- **Apache Bench (ab)**: `ab -n 100 -c 10 http://localhost:8080/health`
- **wrk**: `wrk -t12 -c400 -d30s http://localhost:8080/health`
- **Artillery**: For more complex API testing scenarios

## 🔧 Troubleshooting

### Common Issues

1. **Model not found:**
   - Check if models directory is mounted correctly
   - Verify internet connection for model download
   - Check disk space

2. **Memory issues:**
   - Reduce `n_threads` in model configuration
   - Lower `n_batch` and `n_ubatch` values
   - Ensure sufficient RAM available

3. **Slow inference:**
   - Increase `n_threads` to match CPU cores
   - Adjust `n_batch` for better throughput
   - Consider GPU acceleration if available

4. **Permission denied on `entrypoint.sh`:**
   - If you encounter this, especially on Windows, ensure line endings are LF
   - Run `git config --global core.autocrlf false` before cloning or convert the file

5. **Checksum mismatch:**
   - If the `entrypoint.sh` log shows a checksum error, the downloaded model may be corrupt
   - Verify the checksum of the downloaded file

6. **High memory usage:**
   - This is expected as the model is loaded into RAM
   - Ensure your server has enough memory (at least 4GB free)

### Logs

Check container logs for detailed information:

```bash
docker-compose logs -f llm-api
```

To view real-time logs from the running container:
```bash
docker-compose logs -f llm-api
```

## 📈 Performance Tuning

### CPU Optimization

- Set `n_threads` to match physical CPU cores
- Adjust `n_batch` based on available memory
- Monitor CPU usage during inference
- Use `n_ubatch` to balance memory and throughput

### Memory Optimization

- Use `mlock=True` to prevent swapping
- Monitor memory usage with health checks
- Adjust context window size as needed
- Consider reducing `n_batch` if memory is constrained

### Docker Optimization

- Use multi-stage builds to reduce image size
- Mount volumes for persistent model storage
- Set appropriate resource limits in docker-compose

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Add tests if applicable
5. Commit your changes (`git commit -m 'Add some amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

### Development Setup

For contributors who want to work on the codebase:

```bash
# Clone and setup
git clone https://github.com/dzakwanalifi/llm-inference-server.git
cd llm-inference-server

# Install development dependencies using uv
uv sync --dev

# Run tests (when implemented)
pytest

# Format code
black app/
flake8 app/
```

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp) - Efficient LLM inference
- [FastAPI](https://fastapi.tiangolo.com/) - Modern web framework
- [DeepSeek](https://github.com/deepseek-ai) - Open source models
- [Uvicorn](https://www.uvicorn.org/) - Lightning-fast ASGI server
- [Gunicorn](https://gunicorn.org/) - Production WSGI server
- [Structlog](https://www.structlog.org/) - Structured logging for Python
- [SlowAPI](https://github.com/laurentS/slowapi) - Rate limiting for FastAPI

## 📞 Support

For issues and questions:
- Create an issue in the repository
- Check the troubleshooting section
- Review the logs for error details
- Check the [FAQ section](#frequently-asked-questions) below

## ❓ Frequently Asked Questions

### Q: Why is the first startup so slow?
**A:** The server automatically downloads the DeepSeek model (~1.1 GB) on first run. This is a one-time process and subsequent startups will be much faster.

### Q: Can I use GPU acceleration?
**A:** Yes! Change `n_gpu_layers=0` to a positive number in `app/main.py`. However, this requires CUDA-enabled llama.cpp builds.

### Q: How do I change the model?
**A:** Update the `MODEL_URL` and `MODEL_CHECKSUM` in `entrypoint.sh`, then rebuild the container. Remember to regenerate the `uv.lock` file if you change dependencies in `pyproject.toml`.

### Q: Is this production-ready?
**A:** The code is production-ready, but consider additional monitoring, logging aggregation, and load balancing for high-traffic deployments.

### Q: How do I scale this?
**A:** Use multiple containers behind a load balancer, or implement horizontal scaling with shared model storage.

---

**Note:** This server is designed for local/private use. For production deployment, consider additional security measures and monitoring solutions.
