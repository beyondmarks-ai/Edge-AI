import json
import math
import os
import re
import threading
from collections import Counter
from io import BytesIO
from pathlib import Path
from typing import Any, Counter as CounterType, Dict, List, Optional, Tuple

import httpx
from fastapi import FastAPI, File, HTTPException, Query, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from pypdf import PdfReader

try:
    import fitz
except ImportError:
    fitz = None

try:
    import pytesseract
    from PIL import Image, ImageOps
except ImportError:
    pytesseract = None
    Image = None
    ImageOps = None

try:
    import cv2
except ImportError:
    cv2 = None


PRIVATE_GPT_URL = os.getenv("PRIVATE_GPT_URL", "http://localhost:8001").rstrip("/")
RAG_MODE = os.getenv("RAG_MODE", "local").lower()
BASE_DIR = Path(__file__).resolve().parent
PM_SAMPLE_PATH = BASE_DIR / "samples" / "pm_india_200_lines.txt"
DATA_DIR = BASE_DIR / "data"
LOCAL_STORE_PATH = DATA_DIR / "local_rag_store.json"
ATTENDANCE_IMAGE_DIR = Path(os.getenv("ATTENDANCE_IMAGE_DIR", BASE_DIR.parent / "Img"))
ATTENDANCE_STORE_PATH = DATA_DIR / "attendance_embeddings.json"
ATTENDANCE_RECORDS_PATH = DATA_DIR / "attendance_records.json"
ATTENDANCE_MATCH_THRESHOLD = float(os.getenv("ATTENDANCE_MATCH_THRESHOLD", "0.86"))
ATTENDANCE_RTSP_URL = os.getenv(
    "ATTENDANCE_RTSP_URL",
    "rtsp://admin:admin@192.168.1.3:1935",
)
ATTENDANCE_BIOMETRIC_CONSENT = (
    os.getenv("ATTENDANCE_BIOMETRIC_CONSENT", "true").lower()
    in {"1", "true", "yes", "on"}
)
CHUNK_WORDS = int(os.getenv("RAG_CHUNK_WORDS", "220"))
CHUNK_OVERLAP = int(os.getenv("RAG_CHUNK_OVERLAP", "45"))
OCR_DPI = int(os.getenv("RAG_OCR_DPI", "220"))
OCR_MAX_PAGES = int(os.getenv("RAG_OCR_MAX_PAGES", "30"))
OCR_LANG = os.getenv("RAG_OCR_LANG", "eng")
STORE_LOCK = threading.Lock()

app = FastAPI(title="Edge RAG Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


class IngestTextRequest(BaseModel):
    file_name: str = Field(min_length=1)
    text: str = Field(min_length=1)


class ChatRequest(BaseModel):
    message: str = Field(min_length=1)


class AttendanceMarkRequest(BaseModel):
    student_id: str = Field(min_length=1)
    method: str = "manual"
    confidence: Optional[float] = None


class AttendanceStreamConfigRequest(BaseModel):
    rtsp_url: str = Field(min_length=1)


@app.get("/health")
async def health() -> Dict[str, str]:
    return {
        "status": "ok",
        "rag_mode": RAG_MODE,
        "private_gpt_url": PRIVATE_GPT_URL,
        "local_store": str(LOCAL_STORE_PATH),
    }


@app.get("/rag/private-gpt-status")
async def private_gpt_status() -> Dict[str, Any]:
    return await _private_gpt_status()


@app.get("/rag/ocr-status")
async def ocr_status() -> Dict[str, Any]:
    tesseract_ready = False
    tesseract_error = None

    if pytesseract is not None:
        try:
            pytesseract.get_tesseract_version()
            tesseract_ready = True
        except Exception as exc:
            tesseract_error = str(exc)

    return {
        "pdf_text_extraction": True,
        "ocr_enabled": fitz is not None and pytesseract is not None and Image is not None,
        "pymupdf_available": fitz is not None,
        "pytesseract_available": pytesseract is not None,
        "tesseract_binary_ready": tesseract_ready,
        "tesseract_error": tesseract_error,
        "ocr_dpi": OCR_DPI,
        "ocr_max_pages": OCR_MAX_PAGES,
        "ocr_lang": OCR_LANG,
    }


@app.get("/split/config")
async def split_config() -> Dict[str, Any]:
    return {
        "delete_temp_file": True,
        "nltk_data": "",
        "max_file_size_in_mb": 30.0,
        "supported_file_types": ["pdf", "txt", "md", "csv"],
        "chunk_size": CHUNK_WORDS,
        "chunk_overlap": CHUNK_OVERLAP,
    }


@app.post("/split")
async def split_file(
    file: UploadFile = File(...),
    q_chunk_size: int = Query(CHUNK_WORDS, ge=80, le=2000),
    q_chunk_overlap: int = Query(CHUNK_OVERLAP, ge=0, le=500),
) -> Dict[str, Any]:
    content = await file.read()
    file_name = file.filename or "uploaded-file"
    text = _decode_local_file(file_name, content)
    chunks = _chunk_text(text, chunk_words=q_chunk_size, chunk_overlap=q_chunk_overlap)

    return {
        "content": text,
        "mime_type": file.content_type or _mime_type_for_file(file_name),
        "items": [
            {
                "content": chunk["text"],
                "metadata": {
                    "source": file_name,
                    "page": chunk.get("page"),
                    "chunk": index,
                },
            }
            for index, chunk in enumerate(chunks, start=1)
        ],
    }


@app.get("/rag/documents")
async def list_documents() -> Dict[str, Any]:
    if await _should_use_private_gpt():
        return await _private_gpt_request("GET", "/v1/ingest/list")

    store = _load_local_store()
    return {
        "mode": "local",
        "documents": [
            {"doc_id": item["doc_id"], "file_name": item["file_name"]}
            for item in store["documents"]
        ],
    }


@app.post("/rag/ingest-text")
async def ingest_text(request: IngestTextRequest) -> Dict[str, Any]:
    if not await _should_use_private_gpt():
        return _local_ingest_text(request.file_name, request.text)

    payload = {"file_name": request.file_name, "text": request.text}
    response = await _private_gpt_request("POST", "/v1/ingest/text", json=payload)
    document_ids = _document_ids(response)

    return {"mode": "private_gpt", "document_ids": document_ids, "raw": response}


@app.post("/rag/ingest-file")
async def ingest_file(file: UploadFile = File(...)) -> Dict[str, Any]:
    content = await file.read()

    if not await _should_use_private_gpt():
        text = _decode_local_file(file.filename or "uploaded-file", content)
        return _local_ingest_text(file.filename or "uploaded-file", text)

    files = {
        "file": (
            file.filename or "uploaded-file",
            content,
            file.content_type or "application/octet-stream",
        )
    }
    response = await _private_gpt_request(
        "POST",
        "/v1/ingest/file",
        files=files,
    )

    return {
        "mode": "private_gpt",
        "document_ids": _document_ids(response),
        "raw": response,
    }


@app.post("/rag/ingest-sample-pm")
async def ingest_pm_sample() -> Dict[str, Any]:
    if not PM_SAMPLE_PATH.exists():
        raise HTTPException(status_code=500, detail="PM sample file is missing.")

    sample_text = PM_SAMPLE_PATH.read_text(encoding="utf-8")

    if not await _should_use_private_gpt():
        return _local_ingest_text(PM_SAMPLE_PATH.name, sample_text)

    payload = {
        "file_name": PM_SAMPLE_PATH.name,
        "text": sample_text,
    }
    response = await _private_gpt_request("POST", "/v1/ingest/text", json=payload)

    return {
        "mode": "private_gpt",
        "document_ids": _document_ids(response),
        "raw": response,
    }


@app.post("/rag/chat")
async def chat(request: ChatRequest) -> Dict[str, Any]:
    if not await _should_use_private_gpt():
        return _local_chat(request.message)

    payload = {
        "messages": [{"role": "user", "content": request.message}],
        "stream": False,
        "use_context": True,
        "include_sources": True,
    }
    response = await _private_gpt_request(
        "POST",
        "/v1/chat/completions",
        json=payload,
    )

    choice = _first_choice(response)
    answer = _choice_text(choice)
    sources = _source_ids(choice)

    return {"mode": "private_gpt", "answer": answer, "sources": sources, "raw": response}


@app.get("/attendance/status")
async def attendance_status() -> Dict[str, Any]:
    store = _load_attendance_store()
    return {
        "image_dir": str(ATTENDANCE_IMAGE_DIR),
        "image_dir_exists": ATTENDANCE_IMAGE_DIR.exists(),
        "embedding_store": str(ATTENDANCE_STORE_PATH),
        "embedding_store_exists": ATTENDANCE_STORE_PATH.exists(),
        "biometric_consent_enabled": ATTENDANCE_BIOMETRIC_CONSENT,
        "match_threshold": ATTENDANCE_MATCH_THRESHOLD,
        "students": store.get("students", []),
        "student_count": len(store.get("students", [])),
        "image_count": len(_attendance_image_files()),
        "model": "local_image_embedding_v1",
        "rtsp_url": _attendance_rtsp_url(),
        "opencv_available": cv2 is not None,
    }


@app.post("/attendance/build-embeddings")
async def build_attendance_embeddings() -> Dict[str, Any]:
    if Image is None:
        raise HTTPException(
            status_code=500,
            detail="Pillow is required for attendance embeddings. Install backend requirements.",
        )

    files = _attendance_image_files()
    if not files:
        raise HTTPException(
            status_code=404,
            detail=f"No student images found in {ATTENDANCE_IMAGE_DIR}.",
        )

    grouped: Dict[str, Dict[str, Any]] = {}
    skipped: List[Dict[str, str]] = []

    for image_path in files:
        student_name = _student_name_from_file(image_path)
        student_id = _safe_id(student_name)

        try:
            embedding = _image_embedding(image_path.read_bytes())
        except Exception as exc:
            skipped.append({"file": image_path.name, "error": str(exc)})
            continue

        group = grouped.setdefault(
            student_id,
            {
                "student_id": student_id,
                "name": student_name,
                "images": [],
                "embeddings": [],
            },
        )
        group["images"].append(image_path.name)
        group["embeddings"].append(embedding)

    students: List[Dict[str, Any]] = []
    for group in grouped.values():
        representative = _mean_embedding(group["embeddings"])
        students.append(
            {
                "student_id": group["student_id"],
                "name": group["name"],
                "image_count": len(group["images"]),
                "images": group["images"],
                "embedding": representative,
            }
        )

    students.sort(key=lambda item: str(item["name"]).lower())
    store = {
        "model": "local_image_embedding_v1",
        "image_dir": str(ATTENDANCE_IMAGE_DIR),
        "match_threshold": ATTENDANCE_MATCH_THRESHOLD,
        "students": students,
        "skipped": skipped,
    }
    _save_attendance_store(store)

    return {
        "student_count": len(students),
        "image_count": sum(student["image_count"] for student in students),
        "students": [
            {
                "student_id": student["student_id"],
                "name": student["name"],
                "image_count": student["image_count"],
            }
            for student in students
        ],
        "skipped": skipped,
        "message": "Attendance embeddings built locally.",
    }


@app.post("/attendance/match-file")
async def match_attendance_file(file: UploadFile = File(...)) -> Dict[str, Any]:
    if not ATTENDANCE_BIOMETRIC_CONSENT:
        raise HTTPException(
            status_code=403,
            detail=(
                "Biometric attendance matching is disabled. Set "
                "ATTENDANCE_BIOMETRIC_CONSENT=true only for a consented, "
                "local prototype."
            ),
        )

    store = _load_attendance_store()
    students = store.get("students", [])
    if not students:
        raise HTTPException(
            status_code=400,
            detail="Build attendance embeddings before matching.",
        )

    content = await file.read()
    query_embedding = _image_embedding(content)
    matches = _attendance_matches(query_embedding, students)
    best = matches[0] if matches else None

    if best is None or best["score"] < ATTENDANCE_MATCH_THRESHOLD:
        return {
            "matched": False,
            "threshold": ATTENDANCE_MATCH_THRESHOLD,
            "best_match": best,
            "message": "No confident student match.",
        }

    record = _mark_attendance(
        student_id=best["student_id"],
        name=best["name"],
        method="image_match",
        confidence=best["score"],
    )

    return {
        "matched": True,
        "threshold": ATTENDANCE_MATCH_THRESHOLD,
        "best_match": best,
        "top_matches": matches[:3],
        "attendance": record,
    }


@app.post("/attendance/mark")
async def mark_attendance(request: AttendanceMarkRequest) -> Dict[str, Any]:
    store = _load_attendance_store()
    students = store.get("students", [])
    student = next(
        (
            item
            for item in students
            if item.get("student_id") == request.student_id
        ),
        None,
    )
    if student is None:
        raise HTTPException(status_code=404, detail="Student not found.")

    record = _mark_attendance(
        student_id=str(student["student_id"]),
        name=str(student["name"]),
        method=request.method,
        confidence=request.confidence,
    )
    return {"attendance": record}


@app.get("/attendance/records")
async def attendance_records() -> Dict[str, Any]:
    return _load_attendance_records()


@app.get("/attendance/stream/status")
async def attendance_stream_status() -> Dict[str, Any]:
    return {
        "rtsp_url": _attendance_rtsp_url(),
        "opencv_available": cv2 is not None,
        "ready": cv2 is not None and bool(_attendance_rtsp_url()),
    }


@app.post("/attendance/stream/config")
async def attendance_stream_config(
    request: AttendanceStreamConfigRequest,
) -> Dict[str, Any]:
    _save_attendance_stream_config(request.rtsp_url.strip())
    return await attendance_stream_status()


@app.get("/attendance/stream/frame")
async def attendance_stream_frame() -> Response:
    frame = _read_rtsp_frame()
    jpeg = _encode_frame_jpeg(frame)
    return Response(
        content=jpeg,
        media_type="image/jpeg",
        headers={"Cache-Control": "no-store"},
    )


@app.post("/attendance/stream/check")
async def attendance_stream_check() -> Dict[str, Any]:
    if not ATTENDANCE_BIOMETRIC_CONSENT:
        raise HTTPException(
            status_code=403,
            detail=(
                "Biometric attendance matching is disabled. Set "
                "ATTENDANCE_BIOMETRIC_CONSENT=true only for a consented, "
                "local prototype."
            ),
        )

    store = _load_attendance_store()
    students = store.get("students", [])
    if not students:
        raise HTTPException(
            status_code=400,
            detail="Build attendance embeddings before checking the RTSP feed.",
        )

    frame = _read_rtsp_frame()
    jpeg = _encode_frame_jpeg(frame)
    query_embedding = _image_embedding(jpeg)
    matches = _attendance_matches(query_embedding, students)
    best = matches[0] if matches else None

    if best is None or best["score"] < ATTENDANCE_MATCH_THRESHOLD:
        return {
            "matched": False,
            "threshold": ATTENDANCE_MATCH_THRESHOLD,
            "best_match": best,
            "top_matches": matches[:3],
            "message": "No confident student match in current camera frame.",
        }

    record = _mark_attendance(
        student_id=best["student_id"],
        name=best["name"],
        method="rtsp_stream",
        confidence=best["score"],
    )
    return {
        "matched": True,
        "threshold": ATTENDANCE_MATCH_THRESHOLD,
        "best_match": best,
        "top_matches": matches[:3],
        "attendance": record,
    }


async def _private_gpt_request(
    method: str,
    path: str,
    **kwargs: Any,
) -> Dict[str, Any]:
    try:
        async with httpx.AsyncClient(timeout=120) as client:
            response = await client.request(
                method,
                f"{PRIVATE_GPT_URL}{path}",
                **kwargs,
            )
            response.raise_for_status()
            return response.json()
    except httpx.HTTPStatusError as exc:
        detail = _response_detail(exc.response)
        raise HTTPException(status_code=exc.response.status_code, detail=detail)
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"PrivateGPT is not reachable: {exc}",
        )


async def _ensure_private_gpt_ready() -> None:
    status = await _private_gpt_status()
    if status["ready"]:
        return

    raise HTTPException(status_code=502, detail=status["message"])


async def _should_use_private_gpt() -> bool:
    if RAG_MODE == "local":
        return False

    status = await _private_gpt_status()
    if status["ready"]:
        return True

    if RAG_MODE == "privategpt":
        raise HTTPException(status_code=502, detail=status["message"])

    return False


async def _private_gpt_status() -> Dict[str, Any]:
    required_paths = [
        "/v1/ingest/text",
        "/v1/ingest/file",
        "/v1/chat/completions",
    ]

    openapi = await _private_gpt_openapi()
    if openapi is not None:
        paths = sorted(openapi.get("paths", {}).keys())
        missing_paths = [path for path in required_paths if path not in paths]

        return {
            "ready": not missing_paths,
            "private_gpt_url": PRIVATE_GPT_URL,
            "missing_paths": missing_paths,
            "available_paths": paths,
            "message": "PrivateGPT RAG endpoints are available."
            if not missing_paths
            else (
                "Connected to a server, but it does not expose the expected "
                f"PrivateGPT RAG endpoints. Missing: {', '.join(missing_paths)}"
            ),
        }

    try:
        async with httpx.AsyncClient(timeout=5) as client:
            response = await client.get(f"{PRIVATE_GPT_URL}/health")
            if response.status_code < 500:
                return {
                    "ready": False,
                    "private_gpt_url": PRIVATE_GPT_URL,
                    "missing_paths": required_paths,
                    "available_paths": [],
                    "message": (
                        "A server responded on PRIVATE_GPT_URL, but it did not "
                        "publish /openapi.json, so endpoint compatibility could "
                        "not be verified."
                    ),
                }
    except httpx.HTTPError:
        pass

    try:
        async with httpx.AsyncClient(timeout=5) as client:
            response = await client.get(f"{PRIVATE_GPT_URL}/docs")
            if response.status_code < 500:
                return {
                    "ready": False,
                    "private_gpt_url": PRIVATE_GPT_URL,
                    "missing_paths": required_paths,
                    "available_paths": [],
                    "message": (
                        "A docs page responded on PRIVATE_GPT_URL, but "
                        "/openapi.json was unavailable. Check that this is the "
                        "PrivateGPT API server, not another app."
                    ),
                }
    except httpx.HTTPError as exc:
        return {
            "ready": False,
            "private_gpt_url": PRIVATE_GPT_URL,
            "missing_paths": required_paths,
            "available_paths": [],
            "message": (
                "PrivateGPT is not reachable. Start PrivateGPT first or set "
                f"PRIVATE_GPT_URL correctly. Current URL: {PRIVATE_GPT_URL}. "
                f"Original error: {exc}"
            ),
        }

    return {
        "ready": False,
        "private_gpt_url": PRIVATE_GPT_URL,
        "missing_paths": required_paths,
        "available_paths": [],
        "message": f"PrivateGPT is not ready at {PRIVATE_GPT_URL}.",
    }


async def _private_gpt_openapi() -> Optional[Dict[str, Any]]:
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            response = await client.get(f"{PRIVATE_GPT_URL}/openapi.json")
            if response.status_code == 200:
                return response.json()
    except httpx.HTTPError:
        return None

    return None


def _response_detail(response: httpx.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        return response.text


def _first_choice(response: Dict[str, Any]) -> Dict[str, Any]:
    choices = response.get("choices", [])
    if choices and isinstance(choices[0], dict):
        return choices[0]
    return {}


def _choice_text(choice: Dict[str, Any]) -> str:
    message = choice.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if content:
            return str(content)

    text = choice.get("text")
    if text:
        return str(text)

    return "PrivateGPT returned no answer text."


def _source_ids(choice: Dict[str, Any]) -> List[str]:
    source_ids: List[str] = []
    sources = choice.get("sources", [])

    if not isinstance(sources, list):
        return source_ids

    for source in sources:
        if not isinstance(source, dict):
            continue

        document = source.get("document", {})
        if isinstance(document, dict) and document.get("doc_id"):
            source_ids.append(str(document["doc_id"]))

    return source_ids


def _document_ids(response: Dict[str, Any]) -> List[str]:
    documents = response.get("data", [])
    document_ids: List[str] = []

    if not isinstance(documents, list):
        return document_ids

    for document in documents:
        if isinstance(document, dict) and document.get("doc_id"):
            document_ids.append(str(document["doc_id"]))

    return document_ids


def _load_local_store() -> Dict[str, Any]:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    if not LOCAL_STORE_PATH.exists():
        return {"documents": []}

    try:
        data = json.loads(LOCAL_STORE_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"documents": []}

    if isinstance(data, dict) and isinstance(data.get("documents"), list):
        return data

    return {"documents": []}


def _save_local_store(store: Dict[str, Any]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    LOCAL_STORE_PATH.write_text(json.dumps(store, indent=2), encoding="utf-8")


def _load_attendance_store() -> Dict[str, Any]:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    if not ATTENDANCE_STORE_PATH.exists():
        return {"students": []}

    try:
        data = json.loads(ATTENDANCE_STORE_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"students": []}

    if isinstance(data, dict) and isinstance(data.get("students"), list):
        return data

    return {"students": []}


def _save_attendance_store(store: Dict[str, Any]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ATTENDANCE_STORE_PATH.write_text(
        json.dumps(store, indent=2),
        encoding="utf-8",
    )


def _load_attendance_records() -> Dict[str, Any]:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    if not ATTENDANCE_RECORDS_PATH.exists():
        return {"records": []}

    try:
        data = json.loads(ATTENDANCE_RECORDS_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"records": []}

    if isinstance(data, dict) and isinstance(data.get("records"), list):
        return data

    return {"records": []}


def _save_attendance_records(records: Dict[str, Any]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ATTENDANCE_RECORDS_PATH.write_text(
        json.dumps(records, indent=2),
        encoding="utf-8",
    )


def _attendance_stream_config_path() -> Path:
    return DATA_DIR / "attendance_stream.json"


def _attendance_rtsp_url() -> str:
    path = _attendance_stream_config_path()
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            url = data.get("rtsp_url")
            if isinstance(url, str) and url.strip():
                return url.strip()
        except (json.JSONDecodeError, OSError):
            pass

    return ATTENDANCE_RTSP_URL


def _save_attendance_stream_config(rtsp_url: str) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    _attendance_stream_config_path().write_text(
        json.dumps({"rtsp_url": rtsp_url}, indent=2),
        encoding="utf-8",
    )


def _read_rtsp_frame() -> Any:
    if cv2 is None:
        raise HTTPException(
            status_code=500,
            detail="OpenCV is required for RTSP. Install opencv-python.",
        )

    url = _attendance_rtsp_url()
    if not url:
        raise HTTPException(status_code=400, detail="RTSP URL is not set.")

    capture = cv2.VideoCapture(url)
    try:
        if not capture.isOpened():
            raise HTTPException(
                status_code=502,
                detail=f"Could not open RTSP stream: {url}",
            )

        frame = None
        for _ in range(6):
            ok, candidate = capture.read()
            if ok and candidate is not None:
                frame = candidate

        if frame is None:
            raise HTTPException(
                status_code=502,
                detail="RTSP stream opened but no frame was received.",
            )

        return frame
    finally:
        capture.release()


def _encode_frame_jpeg(frame: Any) -> bytes:
    if cv2 is None:
        raise HTTPException(status_code=500, detail="OpenCV is not installed.")

    ok, buffer = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
    if not ok:
        raise HTTPException(status_code=500, detail="Could not encode frame.")

    return bytes(buffer)


def _attendance_image_files() -> List[Path]:
    if not ATTENDANCE_IMAGE_DIR.exists():
        return []

    supported = {".jpg", ".jpeg", ".png", ".webp"}
    return sorted(
        [
            path
            for path in ATTENDANCE_IMAGE_DIR.iterdir()
            if path.is_file() and path.suffix.lower() in supported
        ],
        key=lambda path: path.name.lower(),
    )


def _student_name_from_file(path: Path) -> str:
    name = path.stem.replace("_", " ").replace("-", " ").strip()
    name = re.sub(r"\s*\d+$", "", name).strip()
    return name or path.stem


def _image_embedding(content: bytes) -> List[float]:
    if Image is None:
        raise ValueError("Pillow is not installed.")

    with Image.open(BytesIO(content)) as image:
        if ImageOps is not None:
            image = ImageOps.exif_transpose(image)

        rgb = image.convert("RGB").resize((32, 32))
        gray = rgb.convert("L")
        features = [((pixel / 255.0) - 0.5) * 2.0 for pixel in gray.getdata()]

        for channel in rgb.split():
            histogram = channel.histogram()
            total = float(sum(histogram)) or 1.0
            for index in range(8):
                start = index * 32
                end = start + 32
                features.append(sum(histogram[start:end]) / total)

    return _normalize_embedding(features)


def _normalize_embedding(values: List[float]) -> List[float]:
    norm = math.sqrt(sum(value * value for value in values)) or 1.0
    return [round(value / norm, 8) for value in values]


def _mean_embedding(embeddings: List[List[float]]) -> List[float]:
    if not embeddings:
        return []

    length = len(embeddings[0])
    values = [
        sum(embedding[index] for embedding in embeddings) / len(embeddings)
        for index in range(length)
    ]
    return _normalize_embedding(values)


def _cosine_similarity(left: List[float], right: List[float]) -> float:
    if not left or not right or len(left) != len(right):
        return 0.0

    return sum(a * b for a, b in zip(left, right))


def _attendance_matches(
    query_embedding: List[float],
    students: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    matches: List[Dict[str, Any]] = []

    for student in students:
        embedding = student.get("embedding")
        if not isinstance(embedding, list):
            continue

        score = _cosine_similarity(
            query_embedding,
            [float(value) for value in embedding],
        )
        matches.append(
            {
                "student_id": student.get("student_id"),
                "name": student.get("name"),
                "score": round(score, 4),
                "confidence": round(max(0.0, min(score, 1.0)) * 100, 2),
            }
        )

    matches.sort(key=lambda item: float(item["score"]), reverse=True)
    return matches


def _mark_attendance(
    student_id: str,
    name: str,
    method: str,
    confidence: Optional[float],
) -> Dict[str, Any]:
    records = _load_attendance_records()
    record = {
        "student_id": student_id,
        "name": name,
        "method": method,
        "confidence": confidence,
        "timestamp": _utc_timestamp(),
    }
    records.setdefault("records", []).append(record)
    _save_attendance_records(records)
    return record


def _utc_timestamp() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).isoformat()


def _local_ingest_text(file_name: str, text: str) -> Dict[str, Any]:
    cleaned_text = text.strip()
    if not cleaned_text:
        raise HTTPException(status_code=400, detail="Document text is empty.")

    document_ids: List[str] = []
    base_id = _safe_id(Path(file_name).stem or "document")
    chunks = _chunk_text(cleaned_text)

    with STORE_LOCK:
        store = _load_local_store()
        store["documents"] = [
            document
            for document in store["documents"]
            if document.get("file_name") != file_name
        ]

        for index, chunk in enumerate(chunks, start=1):
            doc_id = f"{base_id}-{index}"
            document_ids.append(doc_id)
            store["documents"].append(
                {
                    "doc_id": doc_id,
                    "file_name": file_name,
                    "text": chunk["text"],
                    "page": chunk.get("page"),
                    "tokens": _tokens(chunk["text"]),
                }
            )

        _save_local_store(store)

    return {
        "mode": "local",
        "document_ids": document_ids,
        "chunks": len(document_ids),
        "message": "Stored in local RAG index.",
    }


def _local_chat(message: str) -> Dict[str, Any]:
    store = _load_local_store()
    documents = store["documents"]

    if not documents:
        return {
            "mode": "local",
            "answer": "No documents are added yet. Add the PM sample or upload a text file first.",
            "sources": [],
        }

    query_tokens = _tokens(message)
    scored = _rank_documents(query_tokens, documents)

    best = [document for score, document in scored if score > 0][:3]
    if not best:
        return {
            "mode": "local",
            "answer": "I could not find matching information in the added documents.",
            "sources": [],
        }

    answer_lines = _best_answer_lines(query_tokens, best)
    answer = " ".join(answer_lines)
    sources = [
        f"{document['doc_id']}"
        + (f" page {document['page']}" if document.get("page") else "")
        for document in best
    ]

    return {
        "mode": "local",
        "answer": answer,
        "sources": sources,
        "retrieved_chunks": [
            {
                "doc_id": document["doc_id"],
                "file_name": document["file_name"],
                "page": document.get("page"),
                "preview": document["text"][:500],
            }
            for document in best
        ],
    }


def _best_answer_lines(
    query_tokens: List[str],
    documents: List[Dict[str, Any]],
) -> List[str]:
    line_scores: List[Tuple[int, str]] = []

    for document in documents:
        for line in _candidate_answer_units(str(document["text"])):
            score = _score_text_bm25_like(query_tokens, line)
            if score > 0:
                line_scores.append((score, _clean_numbered_line(line)))

    line_scores.sort(key=lambda item: item[0], reverse=True)
    lines: List[str] = []

    for _, line in line_scores:
        if line not in lines:
            lines.append(line)
        if len(lines) == 4:
            break

    return lines or [_clean_numbered_line(str(documents[0]["text"]).splitlines()[0])]


def _rank_documents(
    query_tokens: List[str],
    documents: List[Dict[str, Any]],
) -> List[Tuple[float, Dict[str, Any]]]:
    if not query_tokens or not documents:
        return []

    tokenized_docs = []
    document_frequency: CounterType[str] = Counter()

    for document in documents:
        tokens = document.get("tokens", [])
        if not isinstance(tokens, list):
            tokens = _tokens(str(document.get("text", "")))
        tokenized_docs.append((document, tokens, Counter(tokens)))

        for token in set(tokens):
            document_frequency[token] += 1

    average_length = sum(len(tokens) for _, tokens, _ in tokenized_docs) / max(
        len(tokenized_docs),
        1,
    )
    total_documents = len(tokenized_docs)
    k1 = 1.5
    b = 0.75
    ranked: List[Tuple[float, Dict[str, Any]]] = []

    for document, tokens, frequencies in tokenized_docs:
        document_length = max(len(tokens), 1)
        score = 0.0

        for token in query_tokens:
            frequency = frequencies[token]
            if frequency == 0:
                continue

            df = document_frequency[token]
            idf = math.log(1 + (total_documents - df + 0.5) / (df + 0.5))
            denominator = frequency + k1 * (
                1 - b + b * document_length / max(average_length, 1)
            )
            score += idf * (frequency * (k1 + 1)) / denominator

        ranked.append((score, document))

    ranked.sort(key=lambda item: item[0], reverse=True)
    return ranked


def _score_text_bm25_like(query_tokens: List[str], text: str) -> int:
    tokens = _tokens(text)
    frequencies = Counter(tokens)
    return sum(frequencies[token] for token in query_tokens)


def _score_text(query_tokens: List[str], text: str) -> int:
    tokens = _tokens(text)
    return sum(tokens.count(token) for token in query_tokens)


def _chunk_text(
    text: str,
    chunk_words: int = CHUNK_WORDS,
    chunk_overlap: int = CHUNK_OVERLAP,
) -> List[Dict[str, Any]]:
    normalized = _normalize_text(text)
    page_sections = _split_pages(normalized)
    chunks: List[Dict[str, Any]] = []
    safe_chunk_words = max(chunk_words, 1)
    safe_overlap = min(max(chunk_overlap, 0), max(safe_chunk_words - 1, 0))

    for page, page_text in page_sections:
        words = page_text.split()
        if not words:
            continue

        start = 0
        while start < len(words):
            end = min(start + safe_chunk_words, len(words))
            chunk_text = " ".join(words[start:end]).strip()
            if chunk_text:
                chunks.append({"text": chunk_text, "page": page})

            if end == len(words):
                break

            start = max(end - safe_overlap, start + 1)

    if chunks:
        return chunks

    fallback = normalized.strip()
    return [{"text": fallback, "page": None}] if fallback else []


def _split_pages(text: str) -> List[Tuple[Optional[int], str]]:
    page_pattern = re.compile(r"(?:^|\n)Page\s+(\d+)\s*\n", re.IGNORECASE)
    matches = list(page_pattern.finditer(text))

    if not matches:
        return [(None, text)]

    pages: List[Tuple[Optional[int], str]] = []
    for index, match in enumerate(matches):
        page = int(match.group(1))
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        pages.append((page, text[start:end]))

    return pages


def _normalize_text(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _candidate_answer_units(text: str) -> List[str]:
    cleaned = _normalize_text(text)
    sentences = re.split(r"(?<=[.!?])\s+|\n+", cleaned)
    units = [sentence.strip() for sentence in sentences if sentence.strip()]

    if units:
        return units

    return [cleaned] if cleaned else []


def _tokens(text: str) -> List[str]:
    stop_words = {
        "a",
        "an",
        "and",
        "are",
        "as",
        "at",
        "by",
        "for",
        "from",
        "in",
        "is",
        "it",
        "of",
        "on",
        "or",
        "the",
        "to",
        "what",
        "when",
        "where",
        "which",
        "who",
    }
    words = re.findall(r"[a-zA-Z0-9]+", text.lower())
    return [word for word in words if word not in stop_words and len(word) > 1]


def _safe_id(value: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9]+", "-", value.lower()).strip("-")
    return normalized or "document"


def _clean_numbered_line(line: str) -> str:
    return re.sub(r"^\d+\.\s*", "", line).strip()


def _decode_local_file(file_name: str, content: bytes) -> str:
    suffix = Path(file_name).suffix.lower()
    if suffix == ".pdf":
        return _decode_pdf(content)

    if suffix not in {".txt", ".md", ".csv"}:
        raise HTTPException(
            status_code=400,
            detail=(
                "Local RAG supports PDF, TXT, MD, and CSV files. Start "
                "PrivateGPT to ingest DOCX files."
            ),
        )

    try:
        return content.decode("utf-8")
    except UnicodeDecodeError:
        return content.decode("latin-1")


def _decode_pdf(content: bytes) -> str:
    try:
        reader = PdfReader(BytesIO(content))
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not read PDF: {exc}")

    pages: List[str] = []
    pages_needing_ocr: List[int] = []
    for index, page in enumerate(reader.pages, start=1):
        text = page.extract_text() or ""
        clean_text = _normalize_text(text)
        if _has_enough_text(clean_text):
            pages.append(f"Page {index}\n{clean_text}")
        else:
            pages_needing_ocr.append(index - 1)

    if pages_needing_ocr:
        ocr_pages = _ocr_pdf_pages(content, pages_needing_ocr)
        pages.extend(ocr_pages)

    pages.sort(key=_page_sort_key)

    if not pages:
        raise HTTPException(
            status_code=400,
            detail=(
                "No text found in this PDF. If it is scanned, install OCR "
                "dependencies and the Tesseract binary, then try again."
            ),
        )

    return "\n".join(pages)


def _has_enough_text(text: str) -> bool:
    return len(_tokens(text)) >= 12


def _ocr_pdf_pages(content: bytes, page_indexes: List[int]) -> List[str]:
    if not page_indexes:
        return []

    if fitz is None or pytesseract is None or Image is None:
        if page_indexes:
            raise HTTPException(
                status_code=400,
                detail=(
                    "This PDF needs OCR, but OCR packages are not available. "
                    "Run pip install -r requirements.txt."
                ),
            )

    try:
        pytesseract.get_tesseract_version()
    except Exception as exc:
        raise HTTPException(
            status_code=400,
            detail=(
                "This PDF needs OCR, but the Tesseract engine is not installed "
                f"or not on PATH. Original error: {exc}"
            ),
        )

    if len(page_indexes) > OCR_MAX_PAGES:
        raise HTTPException(
            status_code=400,
            detail=(
                f"This scanned PDF has {len(page_indexes)} OCR pages. The "
                f"current prototype limit is {OCR_MAX_PAGES} pages."
            ),
        )

    scale = OCR_DPI / 72
    ocr_pages: List[str] = []

    try:
        document = fitz.open(stream=content, filetype="pdf")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not render PDF: {exc}")

    try:
        for page_index in page_indexes:
            page = document.load_page(page_index)
            pixmap = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
            image = Image.open(BytesIO(pixmap.tobytes("png")))
            text = pytesseract.image_to_string(image, lang=OCR_LANG)
            clean_text = _normalize_text(text)

            if clean_text:
                ocr_pages.append(f"Page {page_index + 1}\n{clean_text}")
    finally:
        document.close()

    return ocr_pages


def _page_sort_key(page_text: str) -> int:
    match = re.match(r"Page\s+(\d+)", page_text)
    return int(match.group(1)) if match else 0


def _mime_type_for_file(file_name: str) -> str:
    suffix = Path(file_name).suffix.lower()
    return {
        ".pdf": "application/pdf",
        ".txt": "text/plain",
        ".md": "text/markdown",
        ".csv": "text/csv",
    }.get(suffix, "application/octet-stream")
