"""
Pelico Inventory Tracking Application

Routes:
  GET  /           → inventory UI (redirects to /setup when setup required)
  GET  /setup      → first-run wizard
  POST /setup      → process wizard form, mark setup complete
  GET  /health     → liveness probe (always 200)
  GET  /ready      → readiness probe (200 when DB reachable)
  GET  /inventory  → JSON list
  POST /inventory  → JSON add
  DELETE /inventory/{id} → JSON delete
"""

import logging
import os

import psycopg2
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel

# ── Logging ────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("pelico")

# ── Config from environment ───────────────────────────────────────────────
SETUP_REQUIRED  = os.getenv("SETUP_REQUIRED", "true").lower() == "true"
POSTGRES_HOST   = os.getenv("POSTGRES_HOST", "localhost")
POSTGRES_DB     = os.getenv("POSTGRES_DB", "pelico")
POSTGRES_USER   = os.getenv("POSTGRES_USER", "pelico")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "")

# In-memory state (replaced by DB persistence in a future milestone)
_inventory: dict = {}
_config:    dict = {"site_name": "Pelico"}

# ── App ────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Pelico",
    description="Inventory Tracking Appliance API",
    version="1.0.0",
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)

app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")


# ── Helpers ────────────────────────────────────────────────────────────────
def _db_connection():
    return psycopg2.connect(
        host=POSTGRES_HOST,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
        connect_timeout=3,
    )


# ── Health & readiness ─────────────────────────────────────────────────────

@app.get("/health", tags=["system"], summary="Liveness probe")
def health():
    return {"status": "ok"}


@app.get("/ready", tags=["system"], summary="Readiness probe")
def ready():
    try:
        conn = _db_connection()
        conn.close()
        return {"status": "ready"}
    except Exception as exc:  # noqa: BLE001
        log.warning("Readiness check failed: %s", exc)
        raise HTTPException(status_code=503, detail="database not reachable") from exc


# ── Root: inventory UI ─────────────────────────────────────────────────────

@app.get("/", include_in_schema=False)
def root(request: Request):
    if SETUP_REQUIRED:
        return RedirectResponse(url="/setup")
    return templates.TemplateResponse(
        "inventory.html",
        {"request": request, "site_name": _config.get("site_name", "Pelico")},
    )


# ── Setup wizard ─────────────────────────────────────────────────────────────

@app.get("/setup", include_in_schema=False)
def setup_get(request: Request):
    if not SETUP_REQUIRED:
        return RedirectResponse(url="/")
    return templates.TemplateResponse("setup.html", {"request": request})


@app.post("/setup", include_in_schema=False)
def setup_post(
    request: Request,
    license_key: str = Form(""),
    admin_username: str = Form(...),
    admin_password: str = Form(...),
    admin_password2: str = Form(...),
    site_name: str = Form("Pelico"),
):
    global SETUP_REQUIRED, _config

    # Server-side validation
    if admin_password != admin_password2:
        return templates.TemplateResponse(
            "setup.html",
            {
                "request": request,
                "error": "Passwords do not match.",
                "admin_username": admin_username,
                "site_name": site_name,
                "license_key": license_key,
            },
            status_code=422,
        )
    if len(admin_password) < 8:
        return templates.TemplateResponse(
            "setup.html",
            {
                "request": request,
                "error": "Password must be at least 8 characters.",
                "admin_username": admin_username,
                "site_name": site_name,
                "license_key": license_key,
            },
            status_code=422,
        )

    # TODO: persist admin credentials to PostgreSQL
    # TODO: validate license key against license server or offline cert
    # TODO: update k8s ConfigMap SETUP_REQUIRED=false for persistence across restarts
    _config = {
        "site_name": site_name.strip() or "Pelico",
        "admin_username": admin_username.strip(),
    }
    SETUP_REQUIRED = False
    log.info("Setup completed. Site: %s, Admin: %s", _config["site_name"], admin_username)

    # POST → Redirect → GET (303 See Other)
    return RedirectResponse(url="/", status_code=303)


# ── Inventory JSON API ──────────────────────────────────────────────────────

class Item(BaseModel):
    id: str
    name: str
    quantity: int


@app.get("/inventory", tags=["inventory"])
def get_inventory():
    return _inventory


@app.post("/inventory", tags=["inventory"], status_code=201)
def add_item(item: Item):
    _inventory[item.id] = {"name": item.name, "quantity": item.quantity}
    log.info("Item added: %s", item.id)
    return {"message": "Item added", "item": _inventory[item.id]}


@app.delete("/inventory/{item_id}", tags=["inventory"])
def delete_item(item_id: str):
    if item_id not in _inventory:
        raise HTTPException(status_code=404, detail="Item not found")
    del _inventory[item_id]
    log.info("Item deleted: %s", item_id)
    return {"message": "Item deleted"}


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
