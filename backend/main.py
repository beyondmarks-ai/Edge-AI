import base64
import json
import math
import os
import re
import shutil
import threading
import time
import uuid
from collections import Counter
from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path
from typing import Any, Counter as CounterType, Dict, List, Optional, Tuple

import httpx
from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    Query,
    Response,
    UploadFile,
)
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

try:
    from openai import AzureOpenAI
except ImportError:
    AzureOpenAI = None

try:
    import firebase_admin
    from firebase_admin import auth as firebase_auth
    from firebase_admin import credentials, firestore
except ImportError:
    firebase_admin = None
    firebase_auth = None
    credentials = None
    firestore = None


PRIVATE_GPT_URL = os.getenv("PRIVATE_GPT_URL", "http://localhost:8001").rstrip("/")
RAG_MODE = os.getenv("RAG_MODE", "local").lower()
BASE_DIR = Path(__file__).resolve().parent
PM_SAMPLE_PATH = BASE_DIR / "samples" / "pm_india_200_lines.txt"
DATA_DIR = BASE_DIR / "data"
LOCAL_STORE_PATH = DATA_DIR / "local_rag_store.json"
ATTENDANCE_IMAGE_DIR = Path(os.getenv("ATTENDANCE_IMAGE_DIR", BASE_DIR.parent / "Img"))
ATTENDANCE_STORE_PATH = DATA_DIR / "attendance_embeddings.json"
ATTENDANCE_RECORDS_PATH = DATA_DIR / "attendance_records.json"
ADVANCE_SYS_EVENTS_PATH = DATA_DIR / "advance_sys_events.json"
ADVANCE_SYS_FRAMES_DIR = DATA_DIR / "advance_sys_frames"
ATTENDANCE_MATCH_THRESHOLD = float(os.getenv("ATTENDANCE_MATCH_THRESHOLD", "0.86"))
ATTENDANCE_RTSP_URL = os.getenv(
    "ATTENDANCE_RTSP_URL",
    "",
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
ADVANCE_SYS_FRAME_COUNT = int(os.getenv("ADVANCE_SYS_FRAME_COUNT", "4"))
ADVANCE_SYS_COOLDOWN_SECONDS = float(os.getenv("ADVANCE_SYS_COOLDOWN_SECONDS", "30"))
ADVANCE_SYS_MOTION_AREA = float(os.getenv("ADVANCE_SYS_MOTION_AREA", "2400"))
ADVANCE_SYS_FRAME_INTERVAL_SECONDS = float(
    os.getenv("ADVANCE_SYS_FRAME_INTERVAL_SECONDS", "2.0")
)
AZURE_OPENAI_API_KEY = os.getenv("AZURE_OPENAI_API_KEY", "")
AZURE_OPENAI_ENDPOINT = os.getenv("AZURE_OPENAI_ENDPOINT", "").rstrip("/")
AZURE_OPENAI_API_VERSION = os.getenv(
    "AZURE_OPENAI_API_VERSION",
    "2025-01-01-preview",
)
AZURE_OPENAI_DEPLOYMENT = os.getenv("AZURE_OPENAI_DEPLOYMENT", "")
ADMIN_SIGNUP_CODE = os.getenv("ADMIN_SIGNUP_CODE", "edge-admin")
FIREBASE_AUTH_REQUIRED = (
    os.getenv("FIREBASE_AUTH_REQUIRED", "true").lower()
    in {"1", "true", "yes", "on"}
)
FIREBASE_SERVICE_ACCOUNT = os.getenv("FIREBASE_SERVICE_ACCOUNT", "")
FIREBASE_PROJECT_ID = os.getenv("FIREBASE_PROJECT_ID", "")
STORE_LOCK = threading.Lock()
FIREBASE_INIT_ERROR: Optional[str] = None

if firebase_admin is not None:
    try:
        if not firebase_admin._apps:
            if FIREBASE_SERVICE_ACCOUNT:
                firebase_admin.initialize_app(
                    credentials.Certificate(FIREBASE_SERVICE_ACCOUNT)
                )
            else:
                options = {"projectId": FIREBASE_PROJECT_ID} if FIREBASE_PROJECT_ID else None
                firebase_admin.initialize_app(options=options)
    except Exception as exc:
        FIREBASE_INIT_ERROR = str(exc)

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
    domain: str = "general"


class ChatRequest(BaseModel):
    message: str = Field(min_length=1)
    domain: str = "general"


class AttendanceMarkRequest(BaseModel):
    student_id: str = Field(min_length=1)
    method: str = "manual"
    confidence: Optional[float] = None


class AttendanceStreamConfigRequest(BaseModel):
    rtsp_url: str = Field(min_length=1)


class AdminClaimRequest(BaseModel):
    code: str = Field(min_length=1)


class StudentRejectRequest(BaseModel):
    reason: str = ""


class AttendanceStudentCreateResult(BaseModel):
    student_id: str
    name: str
    image_count: int


def _firestore_client() -> Any:
    if firebase_admin is None or firestore is None:
        raise HTTPException(
            status_code=500,
            detail="firebase-admin is not installed on the backend.",
        )
    if FIREBASE_INIT_ERROR:
        raise HTTPException(
            status_code=500,
            detail=f"Firebase Admin is not configured: {FIREBASE_INIT_ERROR}",
        )

    try:
        return firestore.client()
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=f"Could not connect to Firestore: {exc}",
        )


def _optional_authorization_token(authorization: Optional[str]) -> Optional[str]:
    if not authorization:
        return None

    parts = authorization.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1].strip()

    return authorization.strip()


async def _current_user(
    authorization: Optional[str] = Header(default=None),
) -> Dict[str, Any]:
    token = _optional_authorization_token(authorization)
    if not token:
        if FIREBASE_AUTH_REQUIRED:
            raise HTTPException(status_code=401, detail="Firebase token required.")
        return {
            "uid": "local-dev",
            "email": "local-dev@example.com",
            "profile": {
                "role": "admin",
                "status": "approved",
                "studentId": "local-dev",
                "displayName": "Local Dev",
            },
        }

    if firebase_auth is None:
        raise HTTPException(
            status_code=500,
            detail="firebase-admin auth is not installed on the backend.",
        )

    try:
        decoded = firebase_auth.verify_id_token(token)
    except Exception as exc:
        raise HTTPException(status_code=401, detail=f"Invalid Firebase token: {exc}")

    uid = str(decoded.get("uid") or "")
    if not uid:
        raise HTTPException(status_code=401, detail="Firebase token has no uid.")

    db = _firestore_client()
    profile_snapshot = db.collection("users").document(uid).get()
    profile = profile_snapshot.to_dict() or {}
    if not profile:
        profile = {
            "uid": uid,
            "email": decoded.get("email") or "",
            "displayName": decoded.get("name") or decoded.get("email") or "User",
            "role": "student",
            "status": "pending",
            "studentId": uid,
        }

    return {
        "uid": uid,
        "email": decoded.get("email") or profile.get("email") or "",
        "profile": profile,
    }


async def _require_approved_user(
    user: Dict[str, Any] = Depends(_current_user),
) -> Dict[str, Any]:
    profile = user["profile"]
    if profile.get("status") != "approved":
        raise HTTPException(status_code=403, detail="User is not approved.")
    return user


async def _require_admin(
    user: Dict[str, Any] = Depends(_require_approved_user),
) -> Dict[str, Any]:
    if user["profile"].get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin access required.")
    return user


def _jsonable_firestore_value(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {
            str(key): _jsonable_firestore_value(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_jsonable_firestore_value(item) for item in value]
    return value


def _firestore_user_doc(snapshot: Any) -> Dict[str, Any]:
    data = snapshot.to_dict() or {}
    data.setdefault("uid", snapshot.id)
    return {
        str(key): _jsonable_firestore_value(value)
        for key, value in data.items()
    }


def _firestore_attendance_student_doc(snapshot: Any) -> Dict[str, Any]:
    data = snapshot.to_dict() or {}
    data.setdefault("student_id", snapshot.id)
    return {
        str(key): _jsonable_firestore_value(value)
        for key, value in data.items()
    }


@app.get("/health")
async def health() -> Dict[str, str]:
    return {
        "status": "ok",
        "rag_mode": RAG_MODE,
        "private_gpt_url": PRIVATE_GPT_URL,
        "local_store": str(LOCAL_STORE_PATH),
    }


@app.post("/auth/admin/claim")
async def auth_admin_claim(
    request: AdminClaimRequest,
    user: Dict[str, Any] = Depends(_current_user),
) -> Dict[str, Any]:
    if request.code != ADMIN_SIGNUP_CODE:
        raise HTTPException(status_code=403, detail="Invalid admin signup code.")

    db = _firestore_client()
    profile = {
        "uid": user["uid"],
        "email": user.get("email", ""),
        "displayName": user["profile"].get("displayName")
        or user.get("email", "Admin"),
        "role": "admin",
        "status": "approved",
        "studentId": user["uid"],
        "reviewedAt": _utc_timestamp(),
    }
    db.collection("users").document(user["uid"]).set(profile, merge=True)
    return {"profile": profile}


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
async def list_documents(
    user: Dict[str, Any] = Depends(_require_approved_user),
) -> Dict[str, Any]:
    if await _should_use_private_gpt():
        return await _private_gpt_request("GET", "/v1/ingest/list")

    store = _load_local_store()
    return {
        "mode": "local",
        "documents": [
            {
                "doc_id": item["doc_id"],
                "file_name": item["file_name"],
                "domain": item.get("domain", "general"),
            }
            for item in store["documents"]
        ],
    }


@app.post("/rag/ingest-text")
async def ingest_text(
    request: IngestTextRequest,
    user: Dict[str, Any] = Depends(_require_approved_user),
) -> Dict[str, Any]:
    if not await _should_use_private_gpt():
        return _local_ingest_text(request.file_name, request.text, request.domain)

    payload = {"file_name": request.file_name, "text": request.text}
    response = await _private_gpt_request("POST", "/v1/ingest/text", json=payload)
    document_ids = _document_ids(response)

    return {"mode": "private_gpt", "document_ids": document_ids, "raw": response}


@app.post("/rag/ingest-file")
async def ingest_file(
    file: UploadFile = File(...),
    domain: str = Form("general"),
    user: Dict[str, Any] = Depends(_require_approved_user),
) -> Dict[str, Any]:
    content = await file.read()

    if not await _should_use_private_gpt():
        text = _decode_local_file(file.filename or "uploaded-file", content)
        return _local_ingest_text(file.filename or "uploaded-file", text, domain)

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
async def ingest_pm_sample(
    user: Dict[str, Any] = Depends(_require_approved_user),
) -> Dict[str, Any]:
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
async def chat(
    request: ChatRequest,
    user: Dict[str, Any] = Depends(_require_approved_user),
) -> Dict[str, Any]:
    if not await _should_use_private_gpt():
        return _local_chat(request.message, request.domain)

    message = request.message
    domain = _normalize_domain(request.domain)
    if domain != "general":
        message = (
            f"Domain mode: {domain}. Answer only if the question and retrieved "
            f"context belong to {domain}. If not, say it is outside this mode.\n\n"
            f"Question: {request.message}"
        )

    payload = {
        "messages": [{"role": "user", "content": message}],
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
async def attendance_status(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
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
async def build_attendance_embeddings(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
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


@app.post("/admin/students/attendance")
async def create_attendance_student(
    name: str = Form(...),
    student_id: str = Form(...),
    image_urls: str = Form("[]"),
    files: List[UploadFile] = File(...),
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    clean_name = name.strip()
    clean_student_id = student_id.strip()
    if not clean_name:
        raise HTTPException(status_code=400, detail="Student name is required.")
    if not clean_student_id:
        raise HTTPException(status_code=400, detail="Student ID is required.")
    if len(files) < 4:
        raise HTTPException(
            status_code=400,
            detail="Upload at least 4 student images for attendance matching.",
        )
    if Image is None:
        raise HTTPException(
            status_code=500,
            detail="Pillow is required for attendance embeddings. Install backend requirements.",
        )

    try:
        decoded_urls = json.loads(image_urls)
        storage_urls = decoded_urls if isinstance(decoded_urls, list) else []
    except json.JSONDecodeError:
        storage_urls = []

    embeddings: List[List[float]] = []
    image_names: List[str] = []
    skipped: List[Dict[str, str]] = []
    for file in files:
        file_name = file.filename or "student-image"
        content = await file.read()
        try:
            embeddings.append(_image_embedding(content))
            image_names.append(file_name)
        except Exception as exc:
            skipped.append({"file": file_name, "error": str(exc)})

    if len(embeddings) < 4:
        raise HTTPException(
            status_code=400,
            detail="At least 4 uploaded images must be readable image files.",
        )

    student = {
        "student_id": clean_student_id,
        "name": clean_name,
        "image_count": len(embeddings),
        "images": image_names,
        "imageUrls": [str(url) for url in storage_urls],
        "embedding": _mean_embedding(embeddings),
        "model": "local_image_embedding_v1",
        "createdAt": _utc_timestamp(),
        "createdBy": user["uid"],
    }
    _save_firestore_attendance_student(student)
    _upsert_local_attendance_student(student)

    return {
        "student": {
            "student_id": clean_student_id,
            "name": clean_name,
            "image_count": len(embeddings),
        },
        "skipped": skipped,
        "message": "Attendance student saved to Firebase.",
    }


@app.post("/attendance/match-file")
async def match_attendance_file(
    file: UploadFile = File(...),
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
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
async def mark_attendance(
    request: AttendanceMarkRequest,
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
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
async def attendance_records(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    return _load_attendance_records()


@app.get("/attendance/me/calendar")
async def my_attendance_calendar(
    user: Dict[str, Any] = Depends(_require_approved_user),
) -> Dict[str, Any]:
    profile = user["profile"]
    student_id = str(profile.get("studentId") or user["uid"])
    return _student_attendance_calendar(student_id)


@app.get("/attendance/stream/status")
async def attendance_stream_status(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    return {
        "rtsp_url": _attendance_rtsp_url(),
        "opencv_available": cv2 is not None,
        "ready": cv2 is not None and bool(_attendance_rtsp_url()),
    }


@app.post("/attendance/stream/config")
async def attendance_stream_config(
    request: AttendanceStreamConfigRequest,
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    _save_attendance_stream_config(request.rtsp_url.strip())
    return await attendance_stream_status()


@app.get("/attendance/stream/frame")
async def attendance_stream_frame(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Response:
    frame = _read_rtsp_frame()
    jpeg = _encode_frame_jpeg(frame)
    return Response(
        content=jpeg,
        media_type="image/jpeg",
        headers={"Cache-Control": "no-store"},
    )


@app.post("/attendance/stream/check")
async def attendance_stream_check(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
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


@app.get("/admin/students/pending")
async def admin_pending_students(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    db = _firestore_client()
    snapshots = (
        db.collection("users")
        .where("role", "==", "student")
        .where("status", "==", "pending")
        .stream()
    )
    students = [_firestore_user_doc(snapshot) for snapshot in snapshots]
    students.sort(key=lambda item: str(item.get("createdAt") or ""))
    return {"students": students}


@app.post("/admin/students/{uid}/approve")
async def admin_approve_student(
    uid: str,
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    db = _firestore_client()
    ref = db.collection("users").document(uid)
    snapshot = ref.get()
    if not snapshot.exists:
        raise HTTPException(status_code=404, detail="Student profile not found.")
    profile = snapshot.to_dict() or {}
    if profile.get("role") != "student":
        raise HTTPException(status_code=400, detail="Only student profiles can be approved.")

    clean_name = str(profile.get("displayName") or "").strip()
    clean_student_id = str(profile.get("studentId") or "").strip()
    image_urls = profile.get("attendanceImageUrls") or []
    image_names = profile.get("attendanceImageNames") or []
    if not clean_name or not clean_student_id:
        raise HTTPException(
            status_code=400,
            detail="Student profile is missing name or student ID.",
        )
    if not isinstance(image_urls, list) or len(image_urls) < 4:
        raise HTTPException(
            status_code=400,
            detail="Student must submit at least 4 attendance photos before approval.",
        )
    if Image is None:
        raise HTTPException(
            status_code=500,
            detail="Pillow is required for attendance embeddings. Install backend requirements.",
        )

    embeddings: List[List[float]] = []
    downloaded_names: List[str] = []
    skipped: List[Dict[str, str]] = []
    async with httpx.AsyncClient(timeout=30.0) as client:
        for index, url in enumerate(image_urls):
            image_name = (
                str(image_names[index])
                if isinstance(image_names, list) and index < len(image_names)
                else f"attendance-photo-{index + 1}.jpg"
            )
            try:
                response = await client.get(str(url))
                response.raise_for_status()
                embeddings.append(_image_embedding(response.content))
                downloaded_names.append(image_name)
            except Exception as exc:
                skipped.append({"file": image_name, "error": str(exc)})

    if len(embeddings) < 4:
        raise HTTPException(
            status_code=400,
            detail="At least 4 submitted photos must be readable image files.",
        )

    student = {
        "student_id": clean_student_id,
        "name": clean_name,
        "image_count": len(embeddings),
        "images": downloaded_names,
        "imageUrls": [str(url) for url in image_urls],
        "embedding": _mean_embedding(embeddings),
        "model": "local_image_embedding_v1",
        "createdAt": _utc_timestamp(),
        "createdBy": user["uid"],
        "sourceUserUid": uid,
    }
    _save_firestore_attendance_student(student)
    _upsert_local_attendance_student(student)

    ref.set(
        {
            "status": "approved",
            "reviewedAt": _utc_timestamp(),
            "reviewedBy": user["uid"],
            "rejectionReason": "",
            "attendanceEmbeddingStatus": "ready",
            "attendanceEmbeddingUpdatedAt": _utc_timestamp(),
        },
        merge=True,
    )
    return {
        "student": _firestore_user_doc(ref.get()),
        "attendanceStudent": {
            "student_id": clean_student_id,
            "name": clean_name,
            "image_count": len(embeddings),
        },
        "skipped": skipped,
    }


@app.post("/admin/students/{uid}/reject")
async def admin_reject_student(
    uid: str,
    request: StudentRejectRequest,
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    db = _firestore_client()
    ref = db.collection("users").document(uid)
    snapshot = ref.get()
    if not snapshot.exists:
        raise HTTPException(status_code=404, detail="Student profile not found.")

    ref.set(
        {
            "status": "rejected",
            "reviewedAt": _utc_timestamp(),
            "reviewedBy": user["uid"],
            "rejectionReason": request.reason.strip(),
        },
        merge=True,
    )
    return {"student": _firestore_user_doc(ref.get())}


@app.get("/advance-sys/status")
async def advance_sys_status(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    return _ADVANCE_SYS_MONITOR.status()


@app.post("/advance-sys/start")
async def advance_sys_start(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    return _ADVANCE_SYS_MONITOR.start()


@app.post("/advance-sys/stop")
async def advance_sys_stop(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    return _ADVANCE_SYS_MONITOR.stop()


@app.get("/advance-sys/events")
async def advance_sys_events(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    return _load_advance_sys_events()


@app.delete("/advance-sys/events")
async def advance_sys_clear_events(
    user: Dict[str, Any] = Depends(_require_admin),
) -> Dict[str, Any]:
    return _clear_advance_sys_events()


@app.get("/advance-sys/events/{event_id}/frames/{frame_index}")
async def advance_sys_event_frame(
    event_id: str,
    frame_index: int,
    user: Dict[str, Any] = Depends(_require_admin),
) -> Response:
    if not re.fullmatch(r"[A-Za-z0-9_-]+", event_id):
        raise HTTPException(status_code=400, detail="Invalid event id.")
    if frame_index < 1 or frame_index > ADVANCE_SYS_FRAME_COUNT:
        raise HTTPException(status_code=404, detail="Frame not found.")

    frame_path = ADVANCE_SYS_FRAMES_DIR / event_id / f"frame_{frame_index}.jpg"
    if not frame_path.exists():
        raise HTTPException(status_code=404, detail="Frame not found.")

    return Response(
        content=frame_path.read_bytes(),
        media_type="image/jpeg",
        headers={"Cache-Control": "no-store"},
    )


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
    firestore_store = _load_firestore_attendance_store()
    if firestore_store is not None:
        return firestore_store

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


def _load_firestore_attendance_store() -> Optional[Dict[str, Any]]:
    try:
        db = _firestore_client()
        snapshots = db.collection("attendance_students").stream()
        students = [_firestore_attendance_student_doc(snapshot) for snapshot in snapshots]
        students = [
            student
            for student in students
            if isinstance(student.get("embedding"), list)
        ]
        students.sort(key=lambda item: str(item.get("name") or "").lower())
        return {
            "model": "local_image_embedding_v1",
            "source": "firestore",
            "students": students,
            "skipped": [],
        }
    except Exception:
        return None


def _save_firestore_attendance_student(student: Dict[str, Any]) -> None:
    db = _firestore_client()
    db.collection("attendance_students").document(str(student["student_id"])).set(
        student,
        merge=True,
    )


def _upsert_local_attendance_student(student: Dict[str, Any]) -> None:
    store = _load_attendance_store()
    students = [
        item
        for item in store.get("students", [])
        if str(item.get("student_id")) != str(student["student_id"])
    ]
    students.append(student)
    students.sort(key=lambda item: str(item.get("name") or "").lower())
    store["students"] = students
    _save_attendance_store(store)


def _load_attendance_records() -> Dict[str, Any]:
    firestore_records = _load_firestore_attendance_records()
    if firestore_records is not None:
        return firestore_records

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


def _load_firestore_attendance_records() -> Optional[Dict[str, Any]]:
    try:
        db = _firestore_client()
        snapshots = db.collection("attendance_records").stream()
        records = [_firestore_attendance_student_doc(snapshot) for snapshot in snapshots]
        records.sort(key=lambda item: str(item.get("timestamp") or ""), reverse=True)
        return {"records": records}
    except Exception:
        return None


def _save_firestore_attendance_record(record: Dict[str, Any]) -> None:
    try:
        db = _firestore_client()
        record_id = f"{record['student_id']}-{uuid.uuid4().hex[:10]}"
        db.collection("attendance_records").document(record_id).set(record)
    except Exception:
        pass


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
        try:
            capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        except Exception:
            pass

        if not capture.isOpened():
            raise HTTPException(
                status_code=502,
                detail=f"Could not open RTSP stream: {url}",
            )

        frame = None
        for _ in range(2):
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
    _save_firestore_attendance_record(record)
    return record


def _student_attendance_calendar(student_id: str) -> Dict[str, Any]:
    clean_student_id = student_id.strip()
    records = _load_attendance_records().get("records", [])
    by_date: Dict[str, Dict[str, Any]] = {}

    for record in records:
        if not isinstance(record, dict):
            continue
        if str(record.get("student_id") or "") != clean_student_id:
            continue

        timestamp = str(record.get("timestamp") or "")
        try:
            parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        except ValueError:
            continue

        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)

        day_key = parsed.astimezone(timezone.utc).date().isoformat()
        previous = by_date.get(day_key)
        previous_timestamp = str(previous.get("timestamp") or "") if previous else ""
        if previous is None or timestamp > previous_timestamp:
            by_date[day_key] = record

    today = datetime.now(timezone.utc).date()
    calendar: List[Dict[str, Any]] = []
    for offset in range(30):
        day = today - timedelta(days=offset)
        day_key = day.isoformat()
        record = by_date.get(day_key)
        status = "present" if record else ("no_record" if offset == 0 else "absent")
        calendar.append(
            {
                "date": day_key,
                "status": status,
                "timestamp": record.get("timestamp") if record else "",
                "method": record.get("method") if record else "",
                "confidence": record.get("confidence") if record else None,
                "name": record.get("name") if record else "",
            }
        )

    return {"student_id": clean_student_id, "calendar": calendar}


def _utc_timestamp() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).isoformat()


class AdvanceSysMonitor:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._last_error: Optional[str] = None
        self._last_event_at: Optional[str] = None
        self._last_motion_at: Optional[str] = None
        self._last_event_monotonic = 0.0

    def start(self) -> Dict[str, Any]:
        if cv2 is None:
            raise HTTPException(
                status_code=500,
                detail="OpenCV is required for Advance Sys motion monitoring.",
            )

        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return self.status()

            self._stop_event.clear()
            self._last_error = None
            self._thread = threading.Thread(
                target=self._run,
                name="advance-sys-monitor",
                daemon=True,
            )
            self._thread.start()

        return self.status()

    def stop(self) -> Dict[str, Any]:
        thread: Optional[threading.Thread]
        with self._lock:
            self._stop_event.set()
            thread = self._thread

        if thread is not None and thread.is_alive():
            thread.join(timeout=4)

        with self._lock:
            self._thread = None

        return self.status()

    def status(self) -> Dict[str, Any]:
        azure = _azure_openai_status()
        events = _load_advance_sys_events().get("events", [])

        with self._lock:
            running = self._thread is not None and self._thread.is_alive()
            return {
                "running": running,
                "rtsp_url": _attendance_rtsp_url(),
                "opencv_available": cv2 is not None,
                "azure": azure,
                "event_count": len(events),
                "last_event_at": self._last_event_at,
                "last_motion_at": self._last_motion_at,
                "last_error": self._last_error,
                "frame_count": ADVANCE_SYS_FRAME_COUNT,
                "cooldown_seconds": ADVANCE_SYS_COOLDOWN_SECONDS,
                "motion_area": ADVANCE_SYS_MOTION_AREA,
            }

    def _run(self) -> None:
        previous_gray = None

        while not self._stop_event.is_set():
            capture = cv2.VideoCapture(_attendance_rtsp_url())
            try:
                if not capture.isOpened():
                    self._set_error(
                        f"Could not open RTSP stream: {_attendance_rtsp_url()}"
                    )
                    self._wait_or_stop(5)
                    continue

                self._set_error(None)
                previous_gray = None

                while not self._stop_event.is_set():
                    ok, frame = capture.read()
                    if not ok or frame is None:
                        self._set_error("RTSP stream opened but no frame was received.")
                        break

                    motion, previous_gray = _advance_sys_motion_detected(
                        frame,
                        previous_gray,
                    )
                    if motion and self._cooldown_ready():
                        self._last_event_monotonic = time.monotonic()
                        self._set_motion_at(_utc_timestamp())
                        frames = self._capture_event_frames(capture, frame)
                        _save_advance_sys_event(frames)
                        self._set_event_at(_utc_timestamp())

                    self._wait_or_stop(0.08)
            except Exception as exc:
                self._set_error(str(exc))
                self._wait_or_stop(5)
            finally:
                capture.release()

    def _capture_event_frames(self, capture: Any, first_frame: Any) -> List[Any]:
        frames = [first_frame.copy()]

        while (
            len(frames) < ADVANCE_SYS_FRAME_COUNT
            and not self._stop_event.is_set()
        ):
            self._wait_or_stop(ADVANCE_SYS_FRAME_INTERVAL_SECONDS)
            ok, frame = capture.read()
            if ok and frame is not None:
                frames.append(frame.copy())

        while len(frames) < ADVANCE_SYS_FRAME_COUNT:
            frames.append(frames[-1].copy())

        return frames

    def _cooldown_ready(self) -> bool:
        elapsed = time.monotonic() - self._last_event_monotonic
        return elapsed >= ADVANCE_SYS_COOLDOWN_SECONDS

    def _wait_or_stop(self, seconds: float) -> None:
        self._stop_event.wait(max(0.0, seconds))

    def _set_error(self, message: Optional[str]) -> None:
        with self._lock:
            self._last_error = message

    def _set_motion_at(self, timestamp: str) -> None:
        with self._lock:
            self._last_motion_at = timestamp

    def _set_event_at(self, timestamp: str) -> None:
        with self._lock:
            self._last_event_at = timestamp


def _advance_sys_motion_detected(
    frame: Any,
    previous_gray: Any,
) -> Tuple[bool, Any]:
    resized = _resize_frame(frame, max_width=520)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (21, 21), 0)

    if previous_gray is None:
        return False, gray

    delta = cv2.absdiff(previous_gray, gray)
    threshold = cv2.threshold(delta, 25, 255, cv2.THRESH_BINARY)[1]
    threshold = cv2.dilate(threshold, None, iterations=2)
    contours, _ = cv2.findContours(
        threshold,
        cv2.RETR_EXTERNAL,
        cv2.CHAIN_APPROX_SIMPLE,
    )
    has_motion = any(
        cv2.contourArea(contour) >= ADVANCE_SYS_MOTION_AREA
        for contour in contours
    )

    return has_motion, gray


def _save_advance_sys_event(frames: List[Any]) -> Dict[str, Any]:
    event_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:8]}"
    timestamp = _utc_timestamp()
    frame_bytes = _save_advance_sys_frames(event_id, frames)
    analysis = _analyze_advance_sys_frames(frame_bytes)

    event = {
        "event_id": event_id,
        "timestamp": timestamp,
        "scene_title": analysis.get("scene_title", "Motion detected"),
        "analysis_status": analysis.get("status", "unknown"),
        "analysis_error": analysis.get("error"),
        "visible_subjects": analysis.get("visible_subjects", ""),
        "visible_objects": analysis.get("visible_objects", ""),
        "visible_action": analysis.get("visible_action", ""),
        "location_hint": analysis.get("location_hint", ""),
        "summary": analysis.get("summary", ""),
        "confidence": analysis.get("confidence"),
        "frame_count": len(frame_bytes),
    }

    with STORE_LOCK:
        store = _load_advance_sys_events()
        store.setdefault("events", []).append(event)
        _save_advance_sys_events(store)

    return event


def _save_advance_sys_frames(event_id: str, frames: List[Any]) -> List[bytes]:
    folder = ADVANCE_SYS_FRAMES_DIR / event_id
    folder.mkdir(parents=True, exist_ok=True)
    saved: List[bytes] = []

    for index, frame in enumerate(frames[:ADVANCE_SYS_FRAME_COUNT], start=1):
        jpeg = _encode_advance_sys_jpeg(frame)
        (folder / f"frame_{index}.jpg").write_bytes(jpeg)
        saved.append(jpeg)

    return saved


def _encode_advance_sys_jpeg(frame: Any) -> bytes:
    resized = _resize_frame(frame, max_width=1280)
    ok, buffer = cv2.imencode(".jpg", resized, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
    if not ok:
        raise ValueError("Could not encode Advance Sys frame.")
    return bytes(buffer)


def _resize_frame(frame: Any, max_width: int) -> Any:
    height, width = frame.shape[:2]
    if width <= max_width:
        return frame

    scale = max_width / float(width)
    return cv2.resize(
        frame,
        (max_width, int(height * scale)),
        interpolation=cv2.INTER_AREA,
    )


def _analyze_advance_sys_frames(frame_bytes: List[bytes]) -> Dict[str, Any]:
    azure_status = _azure_openai_status()
    if not azure_status["ready"]:
        return {
            "status": "not_configured",
            "error": azure_status["message"],
            "summary": "Azure OpenAI is not configured.",
        }

    try:
        client = AzureOpenAI(
            api_version=AZURE_OPENAI_API_VERSION,
            azure_endpoint=AZURE_OPENAI_ENDPOINT,
            api_key=AZURE_OPENAI_API_KEY,
        )
        content: List[Dict[str, Any]] = [
            {
                "type": "text",
                "text": (
                    "Analyze these consecutive security camera frames from one "
                    "motion event. Return JSON only with keys: scene_title, "
                    "visible_subjects, visible_objects, visible_action, "
                    "location_hint, summary, confidence. Describe the scene, "
                    "what is moving, and what objects are visible. Do not try "
                    "to identify a person or guess a name. Focus on what is "
                    "happening in the frame."
                ),
            }
        ]
        for jpeg in frame_bytes[:10]:
            encoded = base64.b64encode(jpeg).decode("ascii")
            content.append(
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{encoded}"},
                }
            )

        completion = client.chat.completions.create(
            model=AZURE_OPENAI_DEPLOYMENT,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a concise professional motion-scene analysis "
                        "assistant. Return valid JSON only."
                    ),
                },
                {"role": "user", "content": content},
            ],
            temperature=0.1,
            max_tokens=500,
            response_format={"type": "json_object"},
        )
        text = completion.choices[0].message.content or "{}"
        parsed = _parse_json_object(text)

        return {
            "status": "ok",
            "scene_title": str(parsed.get("scene_title", "Motion detected")),
            "visible_subjects": str(parsed.get("visible_subjects", "")),
            "visible_objects": str(parsed.get("visible_objects", "")),
            "visible_action": str(parsed.get("visible_action", "")),
            "location_hint": str(parsed.get("location_hint", "")),
            "summary": str(parsed.get("summary", "")),
            "confidence": parsed.get("confidence"),
        }
    except Exception as exc:
        return {
            "status": "failed",
            "error": str(exc),
            "summary": "Azure OpenAI analysis failed.",
        }


def _azure_openai_status() -> Dict[str, Any]:
    missing: List[str] = []
    if AzureOpenAI is None:
        missing.append("openai package")
    if not AZURE_OPENAI_API_KEY:
        missing.append("AZURE_OPENAI_API_KEY")
    if not AZURE_OPENAI_ENDPOINT:
        missing.append("AZURE_OPENAI_ENDPOINT")
    if not AZURE_OPENAI_DEPLOYMENT:
        missing.append("AZURE_OPENAI_DEPLOYMENT")

    ready = not missing
    return {
        "ready": ready,
        "missing": missing,
        "endpoint": AZURE_OPENAI_ENDPOINT,
        "api_version": AZURE_OPENAI_API_VERSION,
        "deployment": AZURE_OPENAI_DEPLOYMENT,
        "message": "Azure OpenAI is configured."
        if ready
        else f"Missing: {', '.join(missing)}",
    }


def _parse_json_object(text: str) -> Dict[str, Any]:
    try:
        value = json.loads(text)
        return value if isinstance(value, dict) else {}
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            try:
                value = json.loads(text[start : end + 1])
                return value if isinstance(value, dict) else {}
            except json.JSONDecodeError:
                return {}
    return {}


def _load_advance_sys_events() -> Dict[str, Any]:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    if not ADVANCE_SYS_EVENTS_PATH.exists():
        return {"events": []}

    try:
        data = json.loads(ADVANCE_SYS_EVENTS_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"events": []}

    if isinstance(data, dict) and isinstance(data.get("events"), list):
        return data

    return {"events": []}


def _save_advance_sys_events(store: Dict[str, Any]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ADVANCE_SYS_EVENTS_PATH.write_text(
        json.dumps(store, indent=2),
        encoding="utf-8",
    )


def _clear_advance_sys_events() -> Dict[str, Any]:
    with STORE_LOCK:
        _save_advance_sys_events({"events": []})
        if ADVANCE_SYS_FRAMES_DIR.exists():
            shutil.rmtree(ADVANCE_SYS_FRAMES_DIR)
        ADVANCE_SYS_FRAMES_DIR.mkdir(parents=True, exist_ok=True)

    return {"events": []}


_ADVANCE_SYS_MONITOR = AdvanceSysMonitor()


def _local_ingest_text(
    file_name: str,
    text: str,
    domain: str = "general",
) -> Dict[str, Any]:
    cleaned_text = text.strip()
    if not cleaned_text:
        raise HTTPException(status_code=400, detail="Document text is empty.")

    normalized_domain = _normalize_domain(domain)
    document_ids: List[str] = []
    base_id = _safe_id(Path(file_name).stem or "document")
    chunks = _chunk_text(cleaned_text)

    with STORE_LOCK:
        store = _load_local_store()
        store["documents"] = [
            document
            for document in store["documents"]
            if not (
                document.get("file_name") == file_name
                and document.get("domain", "general") == normalized_domain
            )
        ]

        for index, chunk in enumerate(chunks, start=1):
            doc_id = f"{base_id}-{index}"
            document_ids.append(doc_id)
            store["documents"].append(
                {
                    "doc_id": doc_id,
                    "file_name": file_name,
                    "domain": normalized_domain,
                    "text": chunk["text"],
                    "page": chunk.get("page"),
                    "tokens": _tokens(chunk["text"]),
                }
            )

        _save_local_store(store)

    return {
        "mode": "local",
        "domain": normalized_domain,
        "document_ids": document_ids,
        "chunks": len(document_ids),
        "message": "Stored in local RAG index.",
    }


def _local_chat(message: str, domain: str = "general") -> Dict[str, Any]:
    store = _load_local_store()
    normalized_domain = _normalize_domain(domain)
    documents = _documents_for_domain(store["documents"], normalized_domain)

    if not documents:
        return {
            "mode": "local",
            "domain": normalized_domain,
            "answer": (
                "No documents are added for this domain yet. Upload a document "
                f"while {normalized_domain} mode is selected."
            ),
            "sources": [],
        }

    query_tokens = _tokens(message)
    scored = _rank_documents(query_tokens, documents)

    best = [document for score, document in scored if score > 0][:3]
    if not best:
        return {
            "mode": "local",
            "domain": normalized_domain,
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
        "domain": normalized_domain,
        "answer": answer,
        "sources": sources,
        "retrieved_chunks": [
            {
                "doc_id": document["doc_id"],
                "file_name": document["file_name"],
                "domain": document.get("domain", "general"),
                "page": document.get("page"),
                "preview": document["text"][:500],
            }
            for document in best
        ],
    }


def _normalize_domain(domain: str) -> str:
    normalized = re.sub(r"[^a-z]", "", str(domain).lower())
    if normalized in {"medical", "medicine", "health"}:
        return "medical"
    if normalized in {"engineering", "engineer", "engg", "eng"}:
        return "engineering"
    return "general"


def _documents_for_domain(
    documents: List[Dict[str, Any]],
    domain: str,
) -> List[Dict[str, Any]]:
    if domain == "general":
        return documents

    return [
        document
        for document in documents
        if document.get("domain", "general") in {domain, "general"}
    ]


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
