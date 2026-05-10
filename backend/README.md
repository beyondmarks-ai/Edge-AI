# Edge RAG Backend

This FastAPI service connects the Flutter `Rag` screen to a running PrivateGPT
server when requested. By default it runs a built-in local RAG store so the app
works immediately without starting PrivateGPT.

## Run

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
$env:PRIVATE_GPT_URL = "http://localhost:8001"
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

For the default local mode, `PRIVATE_GPT_URL` is optional. To force PrivateGPT,
set:

```powershell
$env:RAG_MODE = "privategpt"
```

Use `http://10.0.2.2:8000` from the Android emulator. Use
`http://localhost:8000` if you run the Flutter app on Windows desktop.

## Endpoints

- `GET /health`
- `GET /rag/ocr-status`
- `GET /rag/documents`
- `POST /rag/ingest-text`
- `POST /rag/ingest-file`
- `POST /rag/ingest-sample-pm`
- `POST /rag/chat`

## Local RAG and OCR

Default mode is local RAG:

```powershell
$env:RAG_MODE = "local"
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

Local mode supports:

- PDF selectable text extraction with `pypdf`
- OCR fallback for scanned PDF pages with PyMuPDF + Tesseract
- TXT, MD, and CSV text ingestion
- word-overlap chunking
- BM25 retrieval with source chunk/page metadata

Install Python packages:

```powershell
pip install -r requirements.txt
```

For scanned PDFs, also install the Tesseract OCR engine on Windows and make sure
`tesseract.exe` is on `PATH`. Then verify:

```powershell
curl http://localhost:8000/rag/ocr-status
```

You want:

```json
"tesseract_binary_ready": true
```

OCR is not mathematically perfect. Clean scans, straight pages, readable fonts,
and good contrast produce much better results.

When `RAG_MODE=privategpt`, the backend expects PrivateGPT to expose
`/v1/ingest/text`, `/v1/ingest/file`, `/v1/ingest/list`, and
`/v1/chat/completions`.
