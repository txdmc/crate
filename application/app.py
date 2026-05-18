"""
Pelico Inventory Tracking Application

Environment Variables (all injected by the Helm chart):
  POSTGRES_HOST       PostgreSQL host
  POSTGRES_DB         Database name
  POSTGRES_USER       Database user
  POSTGRES_PASSWORD   Database password
  MINIO_ENDPOINT      MinIO base URL (e.g. http://pelico-minio:9000)
  MINIO_ACCESS_KEY    MinIO access key
  MINIO_SECRET_KEY    MinIO secret key
  SECRET_KEY          Application secret key for signing
  SETUP_REQUIRED      'true' until first-run wizard is completed
  LOG_LEVEL           Logging level (DEBUG, INFO, WARNING, ERROR)
"""

import logging
import os

import psycopg2
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, RedirectResponse
from pydantic import BaseModel

# ── Logging ────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("pelico")

# ── App ────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Pelico",
    description="Inventory Tracking Appliance API",
    version="1.0.0",
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)

# ── Env config ─────────────────────────────────────────────────────────────
SETUP_REQUIRED = os.getenv("SETUP_REQUIRED", "true").lower() == "true"
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "localhost")
POSTGRES_DB = os.getenv("POSTGRES_DB", "pelico")
POSTGRES_USER = os.getenv("POSTGRES_USER", "pelico")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "")


# ── Helpers ────────────────────────────────────────────────────────────────
def _db_connection():
    """Return a raw psycopg2 connection (short-lived, caller must close)."""
    return psycopg2.connect(
        host=POSTGRES_HOST,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
        connect_timeout=3,
    )


def _setup_guard(request: Request):
    """Redirect to /setup when first-run wizard has not been completed."""
    if SETUP_REQUIRED and not request.url.path.startswith("/setup"):
        return RedirectResponse(url="/setup")
    return None


# ── Health & readiness ─────────────────────────────────────────────────────

@app.get("/health", tags=["system"], summary="Liveness probe")
def health():
    """Always returns 200 while the process is running."""
    return {"status": "ok"}


@app.get("/ready", tags=["system"], summary="Readiness probe")
def ready():
    """Returns 200 only when the database is reachable."""
    try:
        conn = _db_connection()
        conn.close()
        return {"status": "ready"}
    except Exception as exc:  # noqa: BLE001
        log.warning("Readiness check failed: %s", exc)
        raise HTTPException(status_code=503, detail="database not reachable") from exc


# ── First-run / setup ──────────────────────────────────────────────────────

@app.get("/setup", tags=["setup"], summary="First-run setup status")
def setup_status():
    """
    Returns the current setup state.  The front-end (or curl) can poll this
    to determine whether configuration is still required.
    """
    return {
        "setup_required": SETUP_REQUIRED,
        "message": (
            "Pelico requires initial configuration. "
            "Please complete the setup wizard."
        ) if SETUP_REQUIRED else "Setup complete.",
    }


# ── Root redirect ──────────────────────────────────────────────────────────

@app.get("/", include_in_schema=False)
def root(request: Request):
    guard = _setup_guard(request)
    if guard:
        return guard
    return {"message": "Pelico Inventory Tracking Application"}


# ── Inventory API ──────────────────────────────────────────────────────────

class Item(BaseModel):
    id: str
    name: str
    quantity: int


# In-memory store (replaced by PostgreSQL persistence in a follow-up)
_inventory: dict = {}


@app.get("/inventory", tags=["inventory"])
def get_inventory(request: Request):
    guard = _setup_guard(request)
    if guard:
        return guard
    return _inventory


@app.post("/inventory", tags=["inventory"], status_code=201)
def add_item(item: Item, request: Request):
    guard = _setup_guard(request)
    if guard:
        return guard
    _inventory[item.id] = {"name": item.name, "quantity": item.quantity}
    log.info("Item added: %s", item.id)
    return {"message": "Item added", "item": _inventory[item.id]}


@app.delete("/inventory/{item_id}", tags=["inventory"])
def delete_item(item_id: str, request: Request):
    guard = _setup_guard(request)
    if guard:
        return guard
    if item_id not in _inventory:
        raise HTTPException(status_code=404, detail="Item not found")
    del _inventory[item_id]
    log.info("Item deleted: %s", item_id)
    return {"message": "Item deleted"}
