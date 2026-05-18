"""
Pelico Inventory Tracking Application

Routes:
  GET  /                      → inventory UI (HTML) or redirect to /setup
  GET  /setup                 → first-run wizard (HTML)
  POST /setup                 → process wizard form
  GET  /health                → liveness probe (always 200)
  GET  /ready                 → readiness probe (200 when DB reachable)
  GET  /inventory             → JSON list of items
  POST /inventory             → HTML form add
  DELETE /inventory/{id}      → JSON delete (API clients)
  POST /inventory/{id}/delete → HTML form delete (browsers)
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

# ── Config from environment ────────────────────────────────────────────────
SETUP_REQUIRED    = os.getenv("SETUP_REQUIRED", "true").lower() == "true"
POSTGRES_HOST     = os.getenv("POSTGRES_HOST", "localhost")
POSTGRES_DB       = os.getenv("POSTGRES_DB", "pelico")
POSTGRES_USER     = os.getenv("POSTGRES_USER", "pelico")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "")

# In-memory state (replaced by PostgreSQL persistence in a future milestone)
_inventory: dict = {}   # {id: {name, sku, quantity, location}}
_config:    dict = {"site_name": "Pelico"}

# ── App ────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Pelico",
    description="Inventory Tracking Appliance API",
    version="0.1.0",
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


def _items_list():
    """Return inventory as a list of dicts (for template iteration)."""
    return [{"id": k, **v} for k, v in _inventory.items()]


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


# ── Root ───────────────────────────────────────────────────────────────────

@app.get("/", include_in_schema=False)
def root(request: Request):
    if SETUP_REQUIRED:
        return RedirectResponse(url="/setup")
    return templates.TemplateResponse(
        "inventory.html",
        {
            "request": request,
            "site_name": _config.get("site_name", "Pelico"),
            "items": _items_list(),
        },
    )


# ── Setup wizard ───────────────────────────────────────────────────────────

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

    # TODO: persist credentials to PostgreSQL
    # TODO: validate license key
    # TODO: update ConfigMap SETUP_REQUIRED=false for persistence across restarts
    _config = {
        "site_name": site_name.strip() or "Pelico",
        "admin_username": admin_username.strip(),
    }
    SETUP_REQUIRED = False
    log.info("Setup completed. Site: %s, Admin: %s", _config["site_name"], admin_username)
    return RedirectResponse(url="/", status_code=303)


# ── Inventory ──────────────────────────────────────────────────────────────

class Item(BaseModel):
    id: str
    name: str
    sku: str = ""
    quantity: int = 0
    location: str = ""


@app.get("/inventory", tags=["inventory"])
def get_inventory():
    """JSON list — for API clients."""
    return _items_list()


@app.post("/inventory", tags=["inventory"])
def add_item(
    request: Request,
    name: str = Form(...),
    sku: str = Form(""),
    quantity: int = Form(0),
    location: str = Form(""),
):
    """HTML-form-compatible add."""
    if SETUP_REQUIRED:
        return RedirectResponse(url="/setup", status_code=303)
    import uuid
    item_id = str(uuid.uuid4())[:8]
    _inventory[item_id] = {
        "name": name.strip(),
        "sku": sku.strip(),
        "quantity": quantity,
        "location": location.strip(),
    }
    log.info("Item added: %s (%s)", name, item_id)
    return RedirectResponse(url="/", status_code=303)


@app.delete("/inventory/{item_id}", tags=["inventory"])
def delete_item(item_id: str):
    """JSON delete — for API clients."""
    if item_id not in _inventory:
        raise HTTPException(status_code=404, detail="Item not found")
    del _inventory[item_id]
    log.info("Item deleted: %s", item_id)
    return {"message": "Item deleted"}


@app.post("/inventory/{item_id}/delete", tags=["inventory"])
def delete_item_form(item_id: str):
    """HTML-form-compatible delete (browsers cannot send DELETE)."""
    if item_id in _inventory:
        del _inventory[item_id]
        log.info("Item deleted: %s", item_id)
    return RedirectResponse(url="/", status_code=303)
