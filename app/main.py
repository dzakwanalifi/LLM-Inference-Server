# app/main.py

import os
import time
import asyncio
import re
import uuid
import structlog
from structlog.contextvars import bind_contextvars, clear_contextvars
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware
from pathlib import Path
from contextlib import asynccontextmanager
from typing import List, Dict, Any, Optional
from concurrent.futures import ThreadPoolExecutor

# FastAPI
from fastapi import FastAPI, Depends, HTTPException, Header, Request
from pydantic import BaseModel, Field, validator

# Llama CPP
from llama_cpp import Llama

# --- Konfigurasi dan State Global ---

# State untuk menyimpan model yang sudah di-load
model_state = {}

# Path ke model di dalam kontainer Docker
MODEL_NAME = "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
MODEL_PATH = Path(f"/app/models/{MODEL_NAME}")

# Baca API Key dari environment variable
SERVER_API_KEY = os.getenv("API_KEY", "default-secret-key")

# ==============================================================================
# PERUBAHAN 1: Buat ThreadPoolExecutor untuk tugas CPU-bound
# max_workers=2 adalah awal yang aman agar tidak membebani CPU dengan context switching.
# Anda bisa menaikkan ini jika CPU Anda memiliki banyak core.
inference_executor = ThreadPoolExecutor(max_workers=2)
# ==============================================================================

# --- Konfigurasi Structured Logging ---
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(20), # Level INFO
    cache_logger_on_first_use=True,
)
logger = structlog.get_logger()

# --- Konfigurasi Rate Limiting ---
# get_remote_address adalah fungsi yang mengambil IP client sebagai identifier
limiter = Limiter(key_func=get_remote_address)

# --- Fungsi Pemuatan Model (Lifespan Event) ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Fungsi yang dijalankan saat aplikasi FastAPI startup dan shutdown.
    Model LLM akan dimuat di sini.
    """
    print("--- Server Startup ---")
    if not MODEL_PATH.exists():
        raise FileNotFoundError(
            f"Model file not found at {MODEL_PATH}. "
            "Ensure the model is downloaded and the volume is correctly mounted."
        )
    
    print(f"Loading model from: {MODEL_PATH}...")
    llm = Llama(
        model_path=str(MODEL_PATH),
        n_ctx=4096,
        n_threads=4,
        n_batch=1024,
        n_ubatch=512,
        mlock=True,
        n_gpu_layers=0,
        verbose=False
    )
    model_state["llm"] = llm
    
    # Buat instance HealthChecker setelah model dimuat
    model_state["health_checker"] = HealthChecker(llm_instance=llm)

    logger.info("Model loaded successfully.")
    
    yield

    logger.info("--- Server Shutdown ---")
    model_state.clear()
    inference_executor.shutdown(wait=True)


# --- Implementasi Keamanan (API Key) ---

async def verify_api_key(authorization: Optional[str] = Header(None)):
    if not authorization:
        raise HTTPException(
            status_code=403, detail="Authorization header is required."
        )
    
    try:
        scheme, token = authorization.split()
        if scheme.lower() != "bearer":
            raise HTTPException(
                status_code=403, detail="Invalid authentication scheme."
            )
        if token != SERVER_API_KEY:
            raise HTTPException(
                status_code=403, detail="Invalid API Key."
            )
    except ValueError:
        raise HTTPException(
            status_code=403, detail="Invalid authorization header format."
        )

# --- Definisi Model Data (Pydantic) untuk API ---

class ChatMessage(BaseModel):
    role: str = Field(..., pattern=r"^(user|assistant|system)$")
    # Batasi panjang konten untuk mencegah abuse memori
    content: str = Field(..., min_length=1, max_length=16000)

class ChatCompletionRequest(BaseModel):
    # Batasi jumlah pesan dalam satu request
    messages: List[ChatMessage] = Field(..., min_items=1, max_items=20)
    model: str = MODEL_NAME
    # Batasi max_tokens agar tidak terlalu besar
    max_tokens: int = Field(512, ge=1, le=2048)
    temperature: float = Field(0.7, ge=0.0, le=2.0)

    @validator('messages')
    def validate_content_for_injection(cls, messages):
        """Validator untuk mendeteksi pola prompt injection sederhana."""
        injection_patterns = [
            r'ignore\s+previous\s+instructions',
            r'disregard\s+.*?instructions',
            r'you\s+are\s+now',
        ]
        
        full_prompt = " ".join([msg.content for msg in messages])

        for pattern in injection_patterns:
            if re.search(pattern, full_prompt, re.IGNORECASE):
                # Di sini kita bisa log warning atau langsung tolak request
                # Untuk sekarang, kita akan tolak request-nya
                raise ValueError(f"Potential prompt injection detected with pattern: {pattern}")
                
        return messages

class Choice(BaseModel):
    index: int
    message: ChatMessage
    finish_reason: str = "stop"

class Usage(BaseModel):
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int

class ChatCompletionResponse(BaseModel):
    id: str = Field(default_factory=lambda: f"chatcmpl-{int(time.time())}")
    object: str = "chat.completion"
    created: int = Field(default_factory=lambda: int(time.time()))
    model: str = MODEL_NAME
    choices: List[Choice]
    usage: Usage

# --- Inisialisasi Aplikasi FastAPI ---

app = FastAPI(lifespan=lifespan)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
app.add_middleware(SlowAPIMiddleware)

@app.middleware("http")
async def logging_middleware(request: Request, call_next):
    clear_contextvars()
    request_id = str(uuid.uuid4())
    bind_contextvars(
        request_id=request_id,
        client_ip=request.client.host if request.client else "unknown",
    )

    start_time = time.time()
    logger.info("Request started", method=request.method, path=request.url.path)

    response = await call_next(request)

    process_time = (time.time() - start_time) * 1000 # dalam milidetik
    logger.info(
        "Request finished",
        status_code=response.status_code,
        process_time_ms=f"{process_time:.2f}",
    )
    return response

# --- Kelas HealthChecker ---
class HealthChecker:
    def __init__(self, llm_instance: Llama):
        self.llm = llm_instance
        self._is_healthy = True
        self._last_check_time = 0

    async def run_check(self) -> Dict[str, Any]:
        # Caching sederhana untuk mencegah health check membebani server
        if time.time() - self._last_check_time < 30: # Cek setiap 30 detik
             return {"status": "healthy" if self._is_healthy else "unhealthy"}

        checks = {
            "model_loaded": False,
            "inference_functional": False,
        }
        
        try:
            if self.llm:
                checks["model_loaded"] = True
            
            # Jalankan dummy inference yang sangat sederhana dengan timeout 15 detik
            # Gunakan prompt yang sangat pendek untuk test cepat
            await asyncio.wait_for(
                asyncio.to_thread(self.llm, "Hi", max_tokens=1, temperature=0.0), 
                timeout=15.0
            )
            checks["inference_functional"] = True
            self._is_healthy = True

        except asyncio.TimeoutError:
            logger.warning("Health check timed out during dummy inference.")
            self._is_healthy = False
        except Exception as e:
            logger.error("Health check failed with an exception.", error=str(e))
            self._is_healthy = False
        
        self._last_check_time = time.time()
        status = "healthy" if self._is_healthy else "unhealthy"
        return {"status": status, "checks": checks}

def run_inference(request: ChatCompletionRequest) -> Dict[str, Any]:
    """
    Fungsi ini berisi tugas CPU-bound (blocking) dan akan dijalankan
    di thread terpisah oleh ThreadPoolExecutor.
    """
    llm = model_state.get("llm")
    if not llm:
        # Ini seharusnya tidak terjadi jika lifespan bekerja, tapi sebagai pengaman
        raise RuntimeError("Model is not loaded.")

    prompt = ""
    for message in request.messages:
        prompt += f"<|im_start|>{message.role}\n{message.content}<|im_end|>\n"
    prompt += "<|im_start|>assistant\n"
    
    try:
        output = llm(
            prompt=prompt,
            max_tokens=request.max_tokens,
            temperature=request.temperature,
            stop=["<|im_end|>"]
        )
        return output
    except Exception as e:
        print(f"Error during inference: {e}")
        # Kita lempar ulang error agar bisa ditangkap di endpoint utama
        raise e

# --- Endpoint Utama ---

@app.post(
    "/v1/chat/completions",
    response_model=ChatCompletionResponse,
    dependencies=[Depends(verify_api_key)]
)
@limiter.limit("15/minute")
async def create_chat_completion(request: Request, chat_request: ChatCompletionRequest):
    """
    Endpoint utama yang sekarang non-blocking.
    Tugas berat inferensi didelegasikan ke thread lain.
    """
    loop = asyncio.get_event_loop()
    
    # Log sebelum inferensi dimulai
    prompt_length = sum(len(m.content) for m in chat_request.messages)
    logger.info("Inference started", prompt_length=prompt_length, max_tokens=chat_request.max_tokens)
    
    inference_start_time = time.time()
    
    try:
        # `loop.run_in_executor` akan menjalankan `run_inference` di salah satu
        # thread dari pool `inference_executor`. Keyword `await` akan menunggu
        # hasilnya tanpa memblokir event loop utama FastAPI.
        output = await loop.run_in_executor(
            inference_executor, run_inference, chat_request
        )

        inference_time_ms = (time.time() - inference_start_time) * 1000
        usage_data = output["usage"]
        
        # Log setelah inferensi berhasil
        logger.info(
            "Inference finished",
            inference_time_ms=f"{inference_time_ms:.2f}",
            prompt_tokens=usage_data["prompt_tokens"],
            completion_tokens=usage_data["completion_tokens"],
        )

        generated_text = output["choices"][0]["text"].strip()

        response = ChatCompletionResponse(
            choices=[
                Choice(
                    index=0,
                    message=ChatMessage(role="assistant", content=generated_text)
                )
            ],
            usage=Usage(
                prompt_tokens=usage_data["prompt_tokens"],
                completion_tokens=usage_data["completion_tokens"],
                total_tokens=usage_data["total_tokens"],
            )
        )
        return response

    except Exception as e:
        logger.error("Inference failed", error=str(e), exc_info=True)
        # Menangkap error yang mungkin dilempar dari thread inferensi
        raise HTTPException(status_code=500, detail=f"An error occurred during model inference: {e}")

@app.get("/health")
async def health_check():
    health_checker = model_state.get("health_checker")
    if not health_checker:
        raise HTTPException(status_code=503, detail="Health checker not available.")
    
    health_status = await health_checker.run_check()
    
    if health_status["status"] != "healthy":
        raise HTTPException(status_code=503, detail=health_status)
        
    return health_status