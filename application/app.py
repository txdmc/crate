"""
Crate Inventory Tracking Application

Routes:
  GET  /                         → redirects based on state
  GET  /login                    → login page
  POST /login                    → authenticate, set session cookie
  POST /logout                   → clear session, redirect to /login
  GET  /setup                    → first-run wizard (only when setup required)
  POST /setup                    → process wizard, persist to DB
  GET  /health                   → liveness probe (always 200)
  GET  /ready                    → readiness probe (200 when DB reachable)
  GET  /inventory                → JSON list (API clients)
  POST /inventory                → HTML-form add
  DELETE /inventory/{id}         → JSON delete (API clients)
  POST /inventory/{id}/delete    → HTML-form delete
  GET  /settings                 → settings page
  POST /settings/site            → update site name
  POST /settings/password        → change password
"""

import hashlib
import hmac
import logging
import os
import secrets
import uuid
from contextlib import contextmanager

import psycopg2
import psycopg2.extras
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from pydantic import BaseModel

# ── Logging ────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("crate")

# ── Environment config ─────────────────────────────────────────────────────
POSTGRES_HOST     = os.getenv("POSTGRES_HOST", "localhost")
POSTGRES_DB       = os.getenv("POSTGRES_DB", "crate")
POSTGRES_USER     = os.getenv("POSTGRES_USER", "crate")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "")
SECRET_KEY        = os.getenv("SECRET_KEY", secrets.token_hex(32))

# ── Runtime state (loaded from DB on startup) ──────────────────────────────
SETUP_REQUIRED = True
_config: dict = {"site_name": "Crate", "admin_username": "admin"}
_admin:  dict = {}   # {username, password_hash, password_salt}

# ── Session signing ────────────────────────────────────────────────────────
_signer         = URLSafeTimedSerializer(SECRET_KEY, salt="crate-session")
SESSION_COOKIE  = "crate_session"
SESSION_MAX_AGE = 8 * 3600  # 8 hours

# ── FastAPI app ────────────────────────────────────────────────────────────
app = FastAPI(
    title="Crate",
    description="Inventory Tracking Appliance API",
    version="0.1.0",
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")


# ── DB helpers ─────────────────────────────────────────────────────────────
@contextmanager
def _db():
    conn = psycopg2.connect(
        host=POSTGRES_HOST,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
        connect_timeout=3,
    )
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _init_db() -> None:
    """Create schema and load persisted state into module globals."""
    global SETUP_REQUIRED, _config, _admin
    try:
        with _db() as conn:
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS crate_config (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
            """)
            cur.execute("""
                CREATE TABLE IF NOT EXISTS crate_inventory (
                    id       TEXT PRIMARY KEY,
                    name     TEXT    NOT NULL,
                    sku      TEXT    NOT NULL DEFAULT '',
                    quantity INTEGER NOT NULL DEFAULT 0,
                    location TEXT    NOT NULL DEFAULT ''
                )
            """)

            cur.execute("SELECT key, value FROM crate_config")
            cfg = {k: v for k, v in cur.fetchall()}

            if cfg.get("setup_complete") == "true":
                SETUP_REQUIRED = False
                _config = {
                    "site_name":      cfg.get("site_name", "Crate"),
                    "admin_username": cfg.get("admin_username", "admin"),
                }
                _admin = {
                    "username":      cfg.get("admin_username", "admin"),
                    "password_hash": cfg.get("admin_password_hash", ""),
                    "password_salt": cfg.get("admin_password_salt", ""),
                }
            cur.close()
        log.info("DB initialised — setup_required=%s", SETUP_REQUIRED)
    except Exception as exc:
        log.warning("DB init failed (app continues, will retry on requests): %s", exc)


@app.on_event("startup")
def startup() -> None:
    _init_db()


def _db_save_config(pairs: dict) -> None:
    with _db() as conn:
        cur = conn.cursor()
        for k, v in pairs.items():
            cur.execute(
                """
                INSERT INTO crate_config (key, value) VALUES (%s, %s)
                ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
                """,
                (k, v),
            )


def _db_items_list() -> list:
    try:
        with _db() as conn:
            cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
            cur.execute(
                "SELECT id, name, sku, quantity, location "
                "FROM crate_inventory ORDER BY name"
            )
            return [dict(r) for r in cur.fetchall()]
    except Exception as exc:
        log.warning("Failed to load inventory: %s", exc)
        return []


def _db_upsert_item(item_id: str, data: dict) -> None:
    with _db() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO crate_inventory (id, name, sku, quantity, location)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (id) DO UPDATE
              SET name=EXCLUDED.name, sku=EXCLUDED.sku,
                  quantity=EXCLUDED.quantity, location=EXCLUDED.location
            """,
            (item_id, data["name"], data["sku"], data["quantity"], data["location"]),
        )


def _db_delete_item(item_id: str) -> bool:
    with _db() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM crate_inventory WHERE id = %s", (item_id,))
        return cur.rowcount > 0


# ── Auth helpers ───────────────────────────────────────────────────────────
def _hash_password(password: str, salt: str = None):
    if salt is None:
        salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 260_000)
    return h.hex(), salt


def _verify_password(password: str, stored_hash: str, salt: str) -> bool:
    h, _ = _hash_password(password, salt)
    return hmac.compare_digest(h, stored_hash)


def _get_session_user(request: Request):
    token = request.cookies.get(SESSION_COOKIE)
    if not token:
        return None
    try:
        return _signer.loads(token, max_age=SESSION_MAX_AGE)
    except (BadSignature, SignatureExpired):
        return None


def _set_session_cookie(response: Response, username: str) -> None:
    token = _signer.dumps(username)
    response.set_cookie(
        SESSION_COOKIE, token,
        max_age=SESSION_MAX_AGE,
        httponly=True,
        samesite="lax",
    )


def _auth_ctx(request: Request) -> dict:
    """Template context for authenticated pages."""
    return {
        "request":        request,
        "admin_username": _config.get("admin_username", "admin"),
        "site_name":      _config.get("site_name", "Crate"),
    }


# ── Health & readiness ─────────────────────────────────────────────────────
@app.get("/health", tags=["system"], summary="Liveness probe")
def health():
    return {"status": "ok"}


@app.get("/ready", tags=["system"], summary="Readiness probe")
def ready():
    try:
        with _db() as conn:
            conn.cursor().execute("SELECT 1")
        return {"status": "ready"}
    except Exception as exc:
        log.warning("Readiness check failed: %s", exc)
        raise HTTPException(status_code=503, detail="database not reachable") from exc


# ── Root ───────────────────────────────────────────────────────────────────
@app.get("/", include_in_schema=False)
def root(request: Request):
    if SETUP_REQUIRED:
        return RedirectResponse(url="/setup", status_code=303)
    if not _get_session_user(request):
        return RedirectResponse(url="/login", status_code=303)
    return templates.TemplateResponse(
        "inventory.html",
        {**_auth_ctx(request), "items": _db_items_list()},
    )


# ── Setup wizard ───────────────────────────────────────────────────────────
@app.get("/setup", include_in_schema=False)
def setup_get(request: Request):
    if not SETUP_REQUIRED:
        return RedirectResponse(url="/login", status_code=303)
    return templates.TemplateResponse("setup.html", {"request": request})


@app.post("/setup", include_in_schema=False)
def setup_post(
    request: Request,
    license_key: str = Form(""),
    admin_username: str = Form(...),
    admin_password: str = Form(...),
    admin_password2: str = Form(...),
    site_name: str = Form("Crate"),
):
    global SETUP_REQUIRED, _config, _admin

    def _err(msg: str):
        return templates.TemplateResponse(
            "setup.html",
            {
                "request": request, "error": msg,
                "admin_username": admin_username,
                "site_name": site_name,
                "license_key": license_key,
            },
            status_code=422,
        )

    if admin_password != admin_password2:
        return _err("Passwords do not match.")
    if len(admin_password) < 8:
        return _err("Password must be at least 8 characters.")

    pw_hash, pw_salt = _hash_password(admin_password)
    site  = site_name.strip() or "Crate"
    uname = admin_username.strip()

    try:
        _db_save_config({
            "setup_complete":      "true",
            "site_name":           site,
            "admin_username":      uname,
            "admin_password_hash": pw_hash,
            "admin_password_salt": pw_salt,
        })
    except Exception as exc:
        log.error("Failed to persist setup: %s", exc)
        return _err("Database error — could not save setup. Check DB connectivity.")

    _config        = {"site_name": site, "admin_username": uname}
    _admin         = {"username": uname, "password_hash": pw_hash, "password_salt": pw_salt}
    SETUP_REQUIRED = False
    log.info("Setup completed. Site: %s, Admin: %s", site, uname)
    return RedirectResponse(url="/login", status_code=303)


# ── Login / Logout ─────────────────────────────────────────────────────────
@app.get("/login", include_in_schema=False)
def login_get(request: Request):
    if SETUP_REQUIRED:
        return RedirectResponse(url="/setup", status_code=303)
    if _get_session_user(request):
        return RedirectResponse(url="/", status_code=303)
    return templates.TemplateResponse(
        "login.html",
        {"request": request, "site_name": _config.get("site_name", "Crate")},
    )


@app.post("/login", include_in_schema=False)
def login_post(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    if SETUP_REQUIRED:
        return RedirectResponse(url="/setup", status_code=303)

    valid = (
        _admin
        and username == _admin.get("username")
        and _verify_password(password, _admin["password_hash"], _admin["password_salt"])
    )
    if not valid:
        return templates.TemplateResponse(
            "login.html",
            {
                "request":   request,
                "site_name": _config.get("site_name", "Crate"),
                "error":     "Invalid username or password.",
                "username":  username,
            },
            status_code=401,
        )

    response = RedirectResponse(url="/", status_code=303)
    _set_session_cookie(response, username)
    log.info("Login: %s", username)
    return response


@app.post("/logout", include_in_schema=False)
def logout():
    response = RedirectResponse(url="/login", status_code=303)
    response.delete_cookie(SESSION_COOKIE)
    return response


# ── Settings ───────────────────────────────────────────────────────────────
@app.get("/settings", include_in_schema=False)
def settings_get(request: Request):
    if SETUP_REQUIRED:
        return RedirectResponse(url="/setup", status_code=303)
    if not _get_session_user(request):
        return RedirectResponse(url="/login", status_code=303)
    return templates.TemplateResponse("settings.html", _auth_ctx(request))


@app.post("/settings/site", include_in_schema=False)
def settings_site(request: Request, site_name: str = Form(...)):
    if not _get_session_user(request):
        return RedirectResponse(url="/login", status_code=303)
    site = site_name.strip() or "Crate"
    try:
        _db_save_config({"site_name": site})
        _config["site_name"] = site
        return templates.TemplateResponse(
            "settings.html",
            {**_auth_ctx(request), "success_site": "Site name updated."},
        )
    except Exception as exc:
        log.error("settings/site: %s", exc)
        return templates.TemplateResponse(
            "settings.html",
            {**_auth_ctx(request), "error_site": "Database error — could not save."},
            status_code=500,
        )


@app.post("/settings/password", include_in_schema=False)
def settings_password(
    request: Request,
    current_password: str = Form(...),
    new_password: str = Form(...),
    new_password2: str = Form(...),
):
    if not _get_session_user(request):
        return RedirectResponse(url="/login", status_code=303)

    def _err(msg: str):
        return templates.TemplateResponse(
            "settings.html",
            {**_auth_ctx(request), "error_pw": msg},
            status_code=422,
        )

    if not _admin:
        return _err("Session error — please log in again.")
    if not _verify_password(current_password, _admin["password_hash"], _admin["password_salt"]):
        return _err("Current password is incorrect.")
    if new_password != new_password2:
        return _err("New passwords do not match.")
    if len(new_password) < 8:
        return _err("Password must be at least 8 characters.")

    pw_hash, pw_salt = _hash_password(new_password)
    try:
        _db_save_config({"admin_password_hash": pw_hash, "admin_password_salt": pw_salt})
        _admin["password_hash"] = pw_hash
        _admin["password_salt"] = pw_salt
        return templates.TemplateResponse(
            "settings.html",
            {**_auth_ctx(request), "success_pw": "Password updated."},
        )
    except Exception as exc:
        log.error("settings/password: %s", exc)
        return _err("Database error — could not save.")


# ── Inventory ──────────────────────────────────────────────────────────────
class Item(BaseModel):
    id: str
    name: str
    sku: str = ""
    quantity: int = 0
    location: str = ""


@app.get("/inventory", tags=["inventory"])
def get_inventory(request: Request):
    """JSON list — for API clients."""
    if not _get_session_user(request):
        raise HTTPException(status_code=401, detail="Not authenticated")
    return _db_items_list()


@app.post("/inventory", tags=["inventory"])
def add_item(
    request: Request,
    name: str = Form(...),
    sku: str = Form(""),
    quantity: int = Form(0),
    location: str = Form(""),
):
    if SETUP_REQUIRED:
        return RedirectResponse(url="/setup", status_code=303)
    if not _get_session_user(request):
        return RedirectResponse(url="/login", status_code=303)
    item_id = str(uuid.uuid4())[:8]
    data = {
        "name":     name.strip(),
        "sku":      sku.strip(),
        "quantity": quantity,
        "location": location.strip(),
    }
    _db_upsert_item(item_id, data)
    log.info("Item added: %s (%s)", name, item_id)
    return RedirectResponse(url="/", status_code=303)


@app.delete("/inventory/{item_id}", tags=["inventory"])
def delete_item(item_id: str, request: Request):
    """JSON delete — for API clients."""
    if not _get_session_user(request):
        raise HTTPException(status_code=401, detail="Not authenticated")
    if not _db_delete_item(item_id):
        raise HTTPException(status_code=404, detail="Item not found")
    log.info("Item deleted: %s", item_id)
    return {"message": "Item deleted"}


@app.post("/inventory/{item_id}/delete", tags=["inventory"])
def delete_item_form(item_id: str, request: Request):
    """HTML-form delete."""
    if not _get_session_user(request):
        return RedirectResponse(url="/login", status_code=303)
    _db_delete_item(item_id)
    log.info("Item deleted: %s", item_id)
    return RedirectResponse(url="/", status_code=303)
