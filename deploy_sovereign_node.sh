#!/usr/bin/env bash
# ==============================================================================
# Sovereign / FractalMesh ARM64 Node — Self-Contained Bootstrapper (ALL SUBSYSTEMS)
# Target: Termux / ARM64 Linux (uses $PREFIX/bin/python3 on Termux) and generic Linux
#
# Guardrails:
#   - Zero hardcoded API keys, passwords, or session tokens
#   - IRONVISION_AUTOFIRE=0 (draft / human-gated posture; never auto-sends)
#   - SQLite WAL + busy_timeout=30000; paired read-only backup + integrity_check
#   - Never runs byte-level text replacements (sed -i) on .db/.db-wal/.db-shm
#   - Never deletes WAL sidecars
#   - Never overwrites application configuration (snippets only, human must copy)
#   - MCP server binds to 127.0.0.1 only
#   - Never prints credential values (presence only)
#
# Usage:
#   bash deploy_sovereign_node.sh              # bootstrap + wire all subsystems + verify
#   bash deploy_sovereign_node.sh --audit      # bootstrap + fleet audit (safe repairs only)
#   bash deploy_sovereign_node.sh --with-cron  # also print (not install) a cron/termux line
#
# Subsystems wired:
#   1. Local OpenAI-compatible LLM router (Ollama first) w/ fallback health checks
#   2. Hugging Face (HF_TOKEN + Inference router)
#   3. OpenRouter
#   4. OpenCode (config snippet + detection)
#   5. Obsidian (vault draft export, read-safe)
#   6. OpenHands (detection + health check + snippet)
#   7. OpenClaw (detection + gateway snippet, draft-only)
#   8. Loopback-only MCP server (health + draft staging)
#   9. Fleet audit mode (safe repairs: perms, backups, report; no destructive ops)
# ==============================================================================
set -euo pipefail

NODE_ROOT="${HOME}/sovereign-node"
SRC_DIR="${NODE_ROOT}/src"
DATA_DIR="${NODE_ROOT}/data"
BACKUP_DIR="${NODE_ROOT}/backups"
DRAFT_DIR="${NODE_ROOT}/drafts"
LOG_DIR="${NODE_ROOT}/logs"
INT_DIR="${NODE_ROOT}/integrations"
REPORT_DIR="${NODE_ROOT}/reports"
ENV_FILE="${NODE_ROOT}/.env"
AUDIT_MODE=0
WITH_CRON=0

log_info() { printf "[INFO] %s\n" "$1"; }
log_warn() { printf "[WARN] %s\n" "$1" >&2; }
log_err()  { printf "[ERR] %s\n" "$1" >&2; }

resolve_python() {
  if [[ -n "${PREFIX:-}" && -x "${PREFIX}/bin/python3" ]]; then
    printf "%s" "${PREFIX}/bin/python3"
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1; then
    command -v python
  else
    log_err "No Python 3 interpreter found."
    exit 1
  fi
}

generate_hex_secret() {
  local py_bin="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    "$py_bin" -c "import secrets; print(secrets.token_hex(32))"
  fi
}

prepare_dirs() {
  log_info "Creating node directory tree at ${NODE_ROOT}..."
  mkdir -p "$NODE_ROOT" "$SRC_DIR" "$DATA_DIR" "$BACKUP_DIR" "$DRAFT_DIR" "$LOG_DIR" "$INT_DIR" "$REPORT_DIR"
  chmod 700 "$NODE_ROOT" "$DATA_DIR" "$BACKUP_DIR"
}

# ------------------------------------------------------------------------------
# Environment file (chmod 600). Preserves an existing FRACTAL_ATTEST_KEY.
# ------------------------------------------------------------------------------
init_env_file() {
  local py_bin="$1"
  log_info "Initializing environment file at ${ENV_FILE} (chmod 600)..."

  local existing_attest=""
  if [[ -f "$ENV_FILE" ]]; then
    existing_attest="$(grep -E '^FRACTAL_ATTEST_KEY=' "$ENV_FILE" | head -n1 | cut -d'=' -f2- | tr -d '"' || true)"
  fi
  local attest_key="${FRACTAL_ATTEST_KEY:-$existing_attest}"
  if [[ -z "$attest_key" ]]; then
    attest_key="$(generate_hex_secret "$py_bin")"
  fi

  cat <<EOF > "$ENV_FILE"
# ==============================================================================
# Sovereign / FractalMesh Node Environment (Populate rotated secrets locally)
# ==============================================================================
NODE_ROOT="${NODE_ROOT}"
DATA_DIR="${DATA_DIR}"
BACKUP_DIR="${BACKUP_DIR}"
DRAFT_DIR="${DRAFT_DIR}"
LOG_DIR="${LOG_DIR}"
INTEGRATIONS_DIR="${INT_DIR}"

# Core Governance & Database Settings
IRONVISION_AUTOFIRE="0"
SQLITE_BUSY_TIMEOUT_MS="30000"
FRACTAL_OPERATOR_ID="${FRACTAL_OPERATOR_ID:-node-arm64-01}"
FRACTAL_ATTEST_KEY="${attest_key}"

# Local Inference & Tunnel Endpoints
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
MCP_LOCAL_PORT="${MCP_LOCAL_PORT:-8443}"
MCP_REMOTE_PORT="${MCP_REMOTE_PORT:-18443}"
MCP_SSH_HOST="${MCP_SSH_HOST:-}"
MCP_SSH_KEY="${MCP_SSH_KEY:-${HOME}/.ssh/id_ed25519}"

# LLM Providers (OpenAI-compatible unless noted; leave blank until rotated)
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
OPENROUTER_MODEL="${OPENROUTER_MODEL:-openrouter/auto}"
HF_TOKEN="${HF_TOKEN:-}"
HF_MODEL="${HF_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
GEMINI_API_KEY="${GEMINI_API_KEY:-}"
GROQ_API_KEY="${GROQ_API_KEY:-}"
CEREBRAS_API_KEY="${CEREBRAS_API_KEY:-}"
MISTRAL_API_KEY="${MISTRAL_API_KEY:-}"
SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
LANGFUSE_HOST="${LANGFUSE_HOST:-}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"
LANGSMITH_API_KEY="${LANGSMITH_API_KEY:-}"

# Subsystem Paths (auto-detected at write time; edit freely)
OBSIDIAN_VAULT_PATH="${OBSIDIAN_VAULT_PATH:-}"
OPENHANDS_BASE_URL="${OPENHANDS_BASE_URL:-http://127.0.0.1:3000}"
OPENCLAW_BASE_URL="${OPENCLAW_BASE_URL:-http://127.0.0.1:18789}"
EOF

  chmod 600 "$ENV_FILE"
}

# ------------------------------------------------------------------------------
# Core vault: WAL-safe ledger + paired backup checker (unchanged behavior)
# ------------------------------------------------------------------------------
write_vault_and_runner() {
  log_info "Writing WAL-safe ledger, paired backup checker, and draft stager..."
  cat <<'PYEOF' > "${SRC_DIR}/node_core.py"
#!/usr/bin/env python3
"""
WAL-Safe SQLite Ledger, Paired Snapshot Integrity Checker, and Draft Stager.
Enforces IRONVISION_AUTOFIRE=0 (never auto-sends external messages).
"""
import argparse
import hashlib
import hmac
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict


def open_wal_db(db_path: Path, busy_timeout_ms: int = 30000) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), timeout=max(5.0, busy_timeout_ms / 1000.0))
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute(f"PRAGMA busy_timeout={int(busy_timeout_ms)};")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp_utc TEXT NOT NULL,
            operator_id TEXT NOT NULL,
            category TEXT NOT NULL,
            summary TEXT NOT NULL,
            attestation_hmac TEXT NOT NULL,
            prev_hash TEXT NOT NULL,
            event_sha256 TEXT NOT NULL UNIQUE
        )
        """
    )
    conn.commit()
    return conn


def check_integrity(db_path: Path) -> str:
    if not db_path.exists():
        return "missing"
    uri = f"{db_path.resolve().as_uri()}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        row = conn.execute("PRAGMA integrity_check;").fetchone()
        return str(row[0]) if row else "unknown"
    finally:
        conn.close()


def append_event(db_path: Path, busy_timeout_ms: int, operator_id: str,
                 attest_key: str, category: str, summary: str) -> Dict[str, Any]:
    conn = open_wal_db(db_path, busy_timeout_ms)
    try:
        last_row = conn.execute(
            "SELECT event_sha256 FROM audit_events ORDER BY id DESC LIMIT 1;"
        ).fetchone()
        prev_hash = last_row[0] if last_row and last_row[0] else "GENESIS"
        ts_utc = datetime.now(timezone.utc).isoformat()
        att_hmac = hmac.new(
            key=attest_key.encode("utf-8"),
            msg=f"{operator_id}:{category}:{summary}:{ts_utc}".encode("utf-8"),
            digestmod=hashlib.sha256,
        ).hexdigest()
        payload = {
            "timestamp_utc": ts_utc,
            "operator_id": operator_id,
            "category": category,
            "summary": summary,
            "attestation_hmac": att_hmac,
            "prev_hash": prev_hash,
        }
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        event_sha256 = hashlib.sha256(canonical).hexdigest()
        conn.execute(
            """
            INSERT INTO audit_events (
                timestamp_utc, operator_id, category, summary,
                attestation_hmac, prev_hash, event_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (ts_utc, operator_id, category, summary, att_hmac, prev_hash, event_sha256),
        )
        conn.commit()
        return {"timestamp_utc": ts_utc, "prev_hash": prev_hash, "event_sha256": event_sha256}
    finally:
        conn.close()


def backup_paired_readonly(db_path: Path, backup_root: Path) -> Dict[str, Any]:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    snap_dir = backup_root / f"snap_{stamp}"
    snap_dir.mkdir(parents=True, exist_ok=True)
    copied = []
    for suffix in ("", "-wal", "-shm"):
        src = Path(f"{db_path}{suffix}")
        if src.exists():
            dst = snap_dir / src.name
            dst.write_bytes(src.read_bytes())
            os.chmod(dst, 0o444)
            copied.append(dst.name)
    os.chmod(snap_dir, 0o555)
    snap_db = snap_dir / db_path.name
    snap_check = check_integrity(snap_db) if snap_db.exists() else "no_db_in_snapshot"
    return {"snapshot_dir": str(snap_dir), "files": copied, "snapshot_integrity": snap_check}


def stage_draft(draft_dir: Path, title: str, body: str) -> Path:
    draft_dir.mkdir(parents=True, exist_ok=True)
    safe_slug = "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in title.lower())[:40] or "draft"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_file = draft_dir / f"{stamp}_{safe_slug}.txt"
    out_file.write_text(f"STATUS: STAGED_DRAFT_ONLY\nTITLE: {title}\n\n{body}\n", encoding="utf-8")
    return out_file


def main() -> int:
    autofire = os.environ.get("IRONVISION_AUTOFIRE", "0").strip()
    if autofire != "0":
        print("[ERR] IRONVISION_AUTOFIRE must be '0' in this runner.", file=sys.stderr)
        return 2

    parser = argparse.ArgumentParser(description="Sovereign Node Core Runner")
    parser.add_argument("--summary", default="Node health and WAL ledger check")
    parser.add_argument("--draft-title", default="")
    parser.add_argument("--draft-body", default="")
    args = parser.parse_args()

    data_dir = Path(os.environ.get("DATA_DIR", str(Path.home() / "sovereign-node" / "data")))
    backup_dir = Path(os.environ.get("BACKUP_DIR", str(Path.home() / "sovereign-node" / "backups")))
    draft_dir = Path(os.environ.get("DRAFT_DIR", str(Path.home() / "sovereign-node" / "drafts")))
    timeout_ms = int(os.environ.get("SQLITE_BUSY_TIMEOUT_MS", "30000"))
    operator_id = os.environ.get("FRACTAL_OPERATOR_ID", "node-arm64-01")
    attest_key = os.environ.get("FRACTAL_ATTEST_KEY", "")
    if not attest_key:
        print("[ERR] FRACTAL_ATTEST_KEY is empty.", file=sys.stderr)
        return 2

    db_path = data_dir / "sovereign_ledger.db"
    ev = append_event(db_path, timeout_ms, operator_id, attest_key, "CHECKPOINT", args.summary)
    live_check = check_integrity(db_path)
    snap = backup_paired_readonly(db_path, backup_dir)

    draft_path_str = ""
    if args.draft_title and args.draft_body:
        d_path = stage_draft(draft_dir, args.draft_title, args.draft_body)
        draft_path_str = str(d_path)

    print(json.dumps({
        "autofire": autofire,
        "live_integrity": live_check,
        "event": ev,
        "backup": snap,
        "staged_draft": draft_path_str or None,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod +x "${SRC_DIR}/node_core.py"
}

# ------------------------------------------------------------------------------
# Subsystem 1-3: LLM router (local-first, OpenAI-compatible, fallback health checks)
# Providers tried in order; each must pass a health check before use. Output is
# always written to DRAFT_DIR. Nothing is ever sent anywhere by this module.
# ------------------------------------------------------------------------------
write_llm_router() {
  log_info "Writing OpenAI-compatible LLM router with fallback health checks..."
  cat <<'PYEOF' > "${SRC_DIR}/llm_router.py"
#!/usr/bin/env python3
"""
Local-first OpenAI-compatible LLM router with per-provider fallback health checks.

Provider cascade (first healthy provider with a usable credential wins):
  1. ollama        (local, OLLAMA_BASE_URL, OpenAI-compatible /v1)
  2. huggingface   (https://router.huggingface.co/v1, HF_TOKEN)
  3. openrouter    (https://openrouter.ai/api/v1, OPENROUTER_API_KEY)
  4. groq          (https://api.groq.com/openai/v1, GROQ_API_KEY)
  5. mistral       (https://api.mistral.ai/v1, MISTRAL_API_KEY)
  6. cerebras      (https://api.cerebras.ai/v1, CEREBRAS_API_KEY)
  7. gemini        (https://generativelanguage.googleapis.com/v1beta/openai/, GEMINI_API_KEY)
  8. openai        (https://api.openai.com/v1, OPENAI_API_KEY)
  9. anthropic     (native /v1/messages, ANTHROPIC_API_KEY; treated last)

Every generated completion is staged as a local draft. This module never posts,
emails, or transmits a draft anywhere. Health checks only fetch /models lists.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

PROVIDERS = [
    {
        "name": "ollama",
        "base": lambda env: env.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/"),
        "chat": "/v1/chat/completions",
        "model_env": "OLLAMA_MODEL",
        "default_model": "llama3.2:3b",
        "key_env": None,
    },
    {
        "name": "huggingface",
        "base": lambda env: "https://router.huggingface.co/v1",
        "chat": "/chat/completions",
        "model_env": "HF_MODEL",
        "default_model": "Qwen/Qwen2.5-7B-Instruct",
        "key_env": "HF_TOKEN",
    },
    {
        "name": "openrouter",
        "base": lambda env: "https://openrouter.ai/api/v1",
        "chat": "/chat/completions",
        "model_env": "OPENROUTER_MODEL",
        "default_model": "openrouter/auto",
        "key_env": "OPENROUTER_API_KEY",
    },
    {
        "name": "groq",
        "base": lambda env: "https://api.groq.com/openai/v1",
        "chat": "/chat/completions",
        "model_env": "GROQ_MODEL",
        "default_model": "llama-3.1-8b-instant",
        "key_env": "GROQ_API_KEY",
    },
    {
        "name": "mistral",
        "base": lambda env: "https://api.mistral.ai/v1",
        "chat": "/chat/completions",
        "model_env": "MISTRAL_MODEL",
        "default_model": "mistral-small-latest",
        "key_env": "MISTRAL_API_KEY",
    },
    {
        "name": "cerebras",
        "base": lambda env: "https://api.cerebras.ai/v1",
        "chat": "/chat/completions",
        "model_env": "CEREBRAS_MODEL",
        "default_model": "llama3.1-8b",
        "key_env": "CEREBRAS_API_KEY",
    },
    {
        "name": "gemini",
        "base": lambda env: "https://generativelanguage.googleapis.com/v1beta/openai",
        "chat": "/chat/completions",
        "model_env": "GEMINI_MODEL",
        "default_model": "gemini-2.0-flash",
        "key_env": "GEMINI_API_KEY",
    },
    {
        "name": "openai",
        "base": lambda env: "https://api.openai.com/v1",
        "chat": "/chat/completions",
        "model_env": "OPENAI_MODEL",
        "default_model": "gpt-4o-mini",
        "key_env": "OPENAI_API_KEY",
    },
    {
        "name": "anthropic",
        "base": lambda env: "https://api.anthropic.com/v1",
        "chat": "/messages",
        "model_env": "ANTHROPIC_MODEL",
        "default_model": "claude-sonnet-4-5",
        "key_env": "ANTHROPIC_API_KEY",
        "native": True,
    },
]

TIMEOUT_SECONDS = 10


def http_json(url: str, method: str = "GET", headers=None, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
        return resp.status, json.loads(resp.read().decode("utf-8"))


def credential(env, spec) -> str:
    key_env = spec["key_env"]
    return (env.get(key_env, "").strip() if key_env else "") or ""


def auth_headers(spec, key: str) -> dict:
    if spec["name"] == "anthropic":
        return {"x-api-key": key, "anthropic-version": "2023-06-01"}
    return {"Authorization": f"Bearer {key}"}


def probe(env, spec):
    """Health check a provider. Returns (ok, detail). Never returns secrets."""
    key = credential(env, spec)
    if spec["key_env"] and not key:
        return False, f"{spec['key_env']} empty"
    base = spec["base"](env)
    headers = auth_headers(spec, key) if key else {}
    try:
        if spec.get("native"):
            status, body = http_json(
                f"{base}/models",
                headers=headers and {"x-api-key": key, "anthropic-version": "2023-06-01"},
            )
        else:
            status, body = http_json(f"{base}/models", headers=headers)
        if status == 200:
            return True, "models endpoint ok"
        return False, f"HTTP {status}"
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            return False, f"credential rejected (HTTP {exc.code})"
        return False, f"HTTP {exc.code}"
    except Exception as exc:
        return False, f"unreachable ({type(exc).__name__})"


def generate(env, prompt: str, system: str = ""):
    """Try providers in cascade order. Returns dict, never sends anywhere."""
    results = {"selected": None, "attempts": []}
    for spec in PROVIDERS:
        ok, detail = probe(env, spec)
        model = env.get(spec["model_env"], "").strip() or spec["default_model"]
        if not ok:
            results["attempts"].append({"provider": spec["name"], "status": "skip", "detail": detail})
            continue
        base = spec["base"](env)
        headers = auth_headers(spec, credential(env, spec))
        try:
            if spec.get("native"):
                status, body = http_json(
                    f"{base}{spec['chat']}",
                    method="POST",
                    headers=headers,
                    payload={
                        "model": model,
                        "max_tokens": 2048,
                        "system": system or "You are a draft-staging assistant. Output draft text only.",
                        "messages": [{"role": "user", "content": prompt}],
                    },
                )
                text = "".join(
                    block.get("text", "") for block in body.get("content", [])
                    if isinstance(block, dict) and block.get("type") == "text"
                )
            else:
                messages = []
                if system:
                    messages.append({"role": "system", "content": system})
                messages.append({"role": "user", "content": prompt})
                status, body = http_json(
                    f"{base}{spec['chat']}",
                    method="POST",
                    headers=headers,
                    payload={"model": model, "messages": messages},
                )
                text = (body.get("choices") or [{}])[0].get("message", {}).get("content", "")
            results["attempts"].append({"provider": spec["name"], "status": "ok", "detail": f"HTTP {status} model {model}"})
            results["selected"] = {"provider": spec["name"], "model": model, "text": text, "autofire": False}
            return results
        except Exception as exc:
            results["attempts"].append(
                {"provider": spec["name"], "status": "fail", "detail": type(exc).__name__}
            )
    return results


def main() -> int:
    if os.environ.get("IRONVISION_AUTOFIRE", "0").strip() != "0":
        print("[ERR] Router refuses to run with IRONVISION_AUTOFIRE != 0.", file=sys.stderr)
        return 2
    prompt = sys.stdin.read().strip()
    if not prompt:
        print("[ERR] Provide a prompt on stdin.", file=sys.stderr)
        return 2
    env = {k: os.environ.get(k, "") for k in (
        "OLLAMA_BASE_URL", "HF_TOKEN", "OPENROUTER_API_KEY", "GROQ_API_KEY",
        "MISTRAL_API_KEY", "CEREBRAS_API_KEY", "GEMINI_API_KEY", "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY", "OLLAMA_MODEL", "HF_MODEL", "OPENROUTER_MODEL",
    )}
    results = generate(env, prompt)
    out_dir = Path(os.environ.get("DRAFT_DIR", str(Path.home() / "sovereign-node" / "drafts")))
    out_dir.mkdir(parents=True, exist_ok=True)
    if results.get("selected"):
        sel = results["selected"]
        slug = "llm-draft"
        from datetime import datetime, timezone
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        out_file = out_dir / f"{stamp}_{sel['provider']}_{slug}.txt"
        out_file.write_text(
            f"STATUS: STAGED_DRAFT_ONLY\nPROVIDER: {sel['provider']}\nMODEL: {sel['model']}\n\n{sel['text']}\n",
            encoding="utf-8",
        )
        results["staged_draft"] = str(out_file)
    print(json.dumps(results, indent=2))
    return 0 if results.get("selected") else 1


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod +x "${SRC_DIR}/llm_router.py"
}

# ------------------------------------------------------------------------------
# Subsystems 4-7: OpenCode / Obsidian / OpenHands / OpenClaw wiring.
# Policy: NEVER modify existing application configuration. We write snippets
# under $NODE_ROOT/integrations/ and detect installations. The human operator
# copies snippets manually (human-gated posture).
# ------------------------------------------------------------------------------
detect_opencode() {
  local found=0
  for config in \
    "${HOME}/.config/opencode/opencode.json" \
    "${HOME}/.config/opencode/opencode.jsonc" \
    "${HOME}/.opencode/opencode.json" \
    "${HOME}/.opencode.json"; do
    if [[ -f "$config" ]]; then
      log_info "OpenCode config detected: $config (left untouched)"
      found=1
    fi
  done
  if command -v opencode >/dev/null 2>&1; then
    log_info "OpenCode executable: $(command -v opencode)"
    found=1
  fi
  [[ "$found" == "0" ]] && log_warn "OpenCode installation not detected; snippet written anyway"
}

wire_opencode() {
  local mcp_port="$1"
  detect_opencode
  cat <<EOF > "${INT_DIR}/opencode-mcp-snippet.json"
{
  "_comment": "OpenCode human-gated wiring snippet. Copy the 'mcp' block into your opencode.json if desired. Server is loopback-only.",
  "mcp": {
    "sovereign-node": {
      "type": "remote",
      "url": "http://127.0.0.1:${mcp_port}/health",
      "enabled": false,
      "_note": "Set enabled=true manually after verifying 'bash ${NODE_ROOT}/run_mcp.sh'"
    }
  }
}
EOF
  chmod 600 "${INT_DIR}/opencode-mcp-snippet.json"
  log_info "OpenCode snippet: ${INT_DIR}/opencode-mcp-snippet.json"
}

wire_obsidian() {
  local vault="${OBSIDIAN_VAULT_PATH:-}"
  if [[ -z "$vault" ]]; then
    for candidate in \
      "${HOME}/storage/shared/Documents/Obsidian" \
      "${HOME}/storage/shared/obsidian" \
      "${HOME}/Documents/Obsidian" \
      "${HOME}/Obsidian"; do
      if [[ -d "$candidate" ]]; then
        vault="$candidate"
        break
      fi
    done
  fi
  if [[ -n "$vault" && -d "$vault" ]]; then
    log_info "Obsidian vault detected: $vault"
    local inbox="${vault}/Sovereign Drafts"
    if [[ ! -d "$inbox" ]]; then
      log_info "Creating Obsidian inbox folder: $inbox"
      if mkdir -p "$inbox" 2>/dev/null; then
        log_info "Obsidian inbox ready (drafts exported there on demand only)"
      else
        log_warn "Could not create inbox (storage permissions?). Vault path recorded only."
      fi
    fi
    printf 'OBSIDIAN_VAULT_PATH="%s"\nOBSIDIAN_INBOX="%s"\n' \
      "$vault" "$inbox" > "${INT_DIR}/obsidian.env"
    chmod 600 "${INT_DIR}/obsidian.env"
  else
    log_warn "Obsidian vault not found. Set OBSIDIAN_VAULT_PATH in ${ENV_FILE} and re-run."
    printf '# Set OBSIDIAN_VAULT_PATH and re-run deploy_sovereign_node.sh\n# Example (Termux): OBSIDIAN_VAULT_PATH="$HOME/storage/shared/Documents/Obsidian"\n' \
      > "${INT_DIR}/obsidian.env.tmpl"
  fi
}

wire_openhands() {
  local base="${OPENHANDS_BASE_URL:-http://127.0.0.1:3000}"
  local detected=0
  if [[ -d "${HOME}/.openhands" ]]; then
    log_info "OpenHands home detected: ${HOME}/.openhands"
    detected=1
  fi
  if command -v openhands >/dev/null 2>&1; then
    log_info "OpenHands executable: $(command -v openhands)"
    detected=1
  fi
  cat <<EOF > "${INT_DIR}/openhands.env"
# OpenHands wiring (snippets only; never overwrites OpenHands own config)
OPENHANDS_BASE_URL="${base}"
OPENHANDS_DETECTED="${detected}"
OPENHANDS_GATED="1"
EOF
  chmod 600 "${INT_DIR}/openhands.env"
  log_info "OpenHands snippet: ${INT_DIR}/openhands.env"
}

check_openhands_health() {
  local base="${OPENHANDS_BASE_URL:-http://127.0.0.1:3000}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4 "${base}" 2>/dev/null || true)"
  [[ -n "$code" ]] || code="NO_RESPONSE"
  log_info "OpenHands ${base} -> HTTP ${code}"
}

wire_openclaw() {
  local base="${OPENCLAW_BASE_URL:-http://127.0.0.1:18789}"
  local detected=0
  if command -v openclaw >/dev/null 2>&1; then
    log_info "OpenClaw executable: $(command -v openclaw)"
    detected=1
  fi
  if [[ -d "${HOME}/.openclaw" ]]; then
    log_info "OpenClaw home detected: ${HOME}/.openclaw"
    detected=1
  fi
  cat <<EOF > "${INT_DIR}/openclaw-gateway.env"
# OpenClaw gateway wiring. DRAFT-ONLY: outbound sends stay disabled until the
# operator edits this file and sets OPENCLAW_ALLOW_OUTBOUND=1 manually.
OPENCLAW_BASE_URL="${base}"
OPENCLAW_DETECTED="${detected}"
OPENCLAW_ALLOW_OUTBOUND="0"
EOF
  chmod 600 "${INT_DIR}/openclaw-gateway.env"
  log_info "OpenClaw gateway snippet: ${INT_DIR}/openclaw-gateway.env (outbound disabled)"
}

# ------------------------------------------------------------------------------
# Subsystem 8: Loopback-only MCP server (health check + draft staging).
# Binds to 127.0.0.1 explicitly. No tunneling, no 0.0.0.0.
# ------------------------------------------------------------------------------
write_mcp_server() {
  log_info "Writing loopback-only MCP server stub..."
  cat <<'PYEOF' > "${SRC_DIR}/mcp_server.py"
#!/usr/bin/env python3
"""Loopback-only MCP-style server. GET /health, POST /draft (stages a draft).

Refuses IRONVISION_AUTOFIRE != 0. Binds exclusively to 127.0.0.1.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from node_core import stage_draft  # noqa: E402


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {
                "status": "ok",
                "autofire": os.environ.get("IRONVISION_AUTOFIRE", "0"),
                "draft_only": True,
            })
        else:
            self._send(404, {"error": "not found", "routes": ["/health", "/draft"]})

    def do_POST(self):
        if os.environ.get("IRONVISION_AUTOFIRE", "0").strip() != "0":
            self._send(403, {"error": "autofire disabled; server runs draft-only"})
            return
        if self.path != "/draft":
            self._send(404, {"error": "not found", "routes": ["/health", "/draft"]})
            return
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            data = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
            draft_dir = Path(os.environ.get("DRAFT_DIR", str(Path.home() / "sovereign-node" / "drafts")))
            path = stage_draft(draft_dir, str(data.get("title", "untitled")), str(data.get("body", "")))
            self._send(200, {"staged_draft": str(path), "sent": False})
        except Exception as exc:
            self._send(400, {"error": type(exc).__name__})

    def log_message(self, fmt, *args):
        sys.stderr.write("[mcp] %s\n" % (fmt % args))


def main() -> int:
    if os.environ.get("IRONVISION_AUTOFIRE", "0").strip() != "0":
        print("[ERR] MCP server requires IRONVISION_AUTOFIRE=0.", file=sys.stderr)
        return 2
    host = "127.0.0.1"
    port = int(os.environ.get("MCP_LOCAL_PORT", "8443"))
    server = HTTPServer((host, port), Handler)
    print(f"Loopback-only MCP server on http://{host}:{port} (draft-only). Ctrl-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod +x "${SRC_DIR}/mcp_server.py"

  cat <<'EOF' > "${NODE_ROOT}/run_mcp.sh"
#!/usr/bin/env bash
set -euo pipefail
NODE_ROOT="${HOME}/sovereign-node"
ENV_FILE="${NODE_ROOT}/.env"
export IRONVISION_AUTOFIRE="0"
if [[ -f "$ENV_FILE" ]]; then
  chmod 600 "$ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
if [[ -n "${PREFIX:-}" && -x "${PREFIX}/bin/python3" ]]; then
  PY_BIN="${PREFIX}/bin/python3"
else
  PY_BIN="$(command -v python3)"
fi
exec "$PY_BIN" "${NODE_ROOT}/src/mcp_server.py"
EOF
  chmod 700 "${NODE_ROOT}/run_mcp.sh"
}

# ------------------------------------------------------------------------------
# Wrapper runner (env loading + logging, unchanged posture)
# ------------------------------------------------------------------------------
write_wrapper_script() {
  cat <<'EOF' > "${NODE_ROOT}/run_node.sh"
#!/usr/bin/env bash
set -euo pipefail
NODE_ROOT="${HOME}/sovereign-node"
ENV_FILE="${NODE_ROOT}/.env"
LOG_FILE="${NODE_ROOT}/logs/node.log"

if [[ -n "${PREFIX:-}" && -x "${PREFIX}/bin/python3" ]]; then
  PY_BIN="${PREFIX}/bin/python3"
else
  PY_BIN="$(command -v python3)"
fi

if [[ -f "$ENV_FILE" ]]; then
  chmod 600 "$ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
export IRONVISION_AUTOFIRE="0"
mkdir -p "$(dirname "$LOG_FILE")"
"$PY_BIN" "${NODE_ROOT}/src/node_core.py" "$@" | tee -a "$LOG_FILE"
EOF
  chmod 700 "${NODE_ROOT}/run_node.sh"

  cat <<'EOF' > "${NODE_ROOT}/run_llm_router.sh"
#!/usr/bin/env bash
set -euo pipefail
NODE_ROOT="${HOME}/sovereign-node"
ENV_FILE="${NODE_ROOT}/.env"
export IRONVISION_AUTOFIRE="0"
if [[ -f "$ENV_FILE" ]]; then
  chmod 600 "$ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
if [[ -n "${PREFIX:-}" && -x "${PREFIX}/bin/python3" ]]; then
  PY_BIN="${PREFIX}/bin/python3"
else
  PY_BIN="$(command -v python3)"
fi
exec "$PY_BIN" "${NODE_ROOT}/src/llm_router.py"
EOF
  chmod 700 "${NODE_ROOT}/run_llm_router.sh"
}

# ------------------------------------------------------------------------------
# Verification pass: subsystem health + credential PRESENCE only (never values)
# ------------------------------------------------------------------------------
verify_subsystems() {
  local py_bin="$1"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local report="${REPORT_DIR}/subsystems-${stamp}.txt"
  set +a
  {
    echo "SOVEREIGN NODE SUBSYSTEM VERIFICATION — ${stamp}"
    echo
    echo "--- Credentials (presence only, never values) ---"
    if [[ -f "$ENV_FILE" ]]; then
      "$py_bin" - "$ENV_FILE" <<'PY'
import re, sys
lines = open(sys.argv[1], errors="ignore").read().splitlines()

def value_looks_like_placeholder(v):
    return v.startswith("__") or len(v) < 8

for line in lines:
    m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", line)
    if not m:
        continue
    key, val = m.groups()
    if not any(t in key for t in ("API_KEY", "TOKEN", "ATTEST", "SECRET")):
        continue
    val = val.strip().strip('"').strip("'")
    if not val:
        print(f"{key}: EMPTY")
    elif value_looks_like_placeholder(val):
        print(f"{key}: PLACEHOLDER")
    else:
        print(f"{key}: PRESENT")
PY
    fi
    echo
    echo "--- Tooling ---"
    for cmd in python3 git curl node npm pm2 ollama jq openssl; do
      if command -v "$cmd" >/dev/null 2>&1; then
        echo "FOUND  $cmd: $(command -v "$cmd")"
      else
        echo "MISSING $cmd"
      fi
    done
    echo
    echo "--- OpenCode ---"
    ls -1 "${INT_DIR}"/opencode-mcp-snippet.json 2>/dev/null || true
    echo
    echo "--- Obsidian / OpenHands / OpenClaw ---"
    ls -1 "${INT_DIR}"/obsidian.env* "${INT_DIR}"/openhands.env "${INT_DIR}"/openclaw-gateway.env 2>/dev/null || true
    grep -h "^OPENHANDS_BASE_URL\|^OPENCLAW_BASE_URL\|^OBSIDIAN_VAULT_PATH" \
      "${INT_DIR}"/openhands.env "${INT_DIR}"/openclaw-gateway.env "${INT_DIR}"/obsidian.env 2>/dev/null || true
    echo
    echo "Report: $report"
  } > "$report"
  chmod 600 "$report"
  cat "$report"
  log_info "Verification report written to $report"
}

# ------------------------------------------------------------------------------
# Subsystem 9: Fleet audit (safe-repair posture, no destructive operations)
#   - back up secrets files (never displayed) and chmod 600 them
#   - back up PM2 state before any inspection
#   - discover git repos
#   - probe known service ports on LOOPBACK only
#   - no unknown process killed, no config overwritten, no transactions executed
# ------------------------------------------------------------------------------
fleet_audit() {
  local py_bin="$1"
  local stamp work backup report
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  work="${NODE_ROOT}/fleet-audit"
  backup="${work}/backups/${stamp}"
  report="${REPORT_DIR}/fleet-${stamp}.txt"
  mkdir -p "$backup" "$(dirname "$report")"
  chmod 700 "$work" "$backup"

  log_info "=== FLEET AUDIT (safe mode) — $stamp ==="
  {
    echo "FLEET AUDIT — $stamp"
    echo "Device: $(uname -a 2>/dev/null || echo unknown)"
    echo
    echo "Repair policy:"
    echo "- Secret file permissions protected (chmod 600)."
    echo "- PM2 state backed up before inspection."
    echo "- No credentials printed."
    echo "- No unknown processes killed."
    echo "- No application configuration overwritten."
    echo "- No financial transactions executed."
    echo
    echo "--- 1. Secret files protected (names only) ---"
    find "$HOME" -maxdepth 5 -type f \
      \( -name ".env" -o -name ".env.local" -o -name "*.secrets.env" -o -name ".fractalmesh_secrets.env" \) \
      -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "${NODE_ROOT}/*" \
      2>/dev/null | while IFS= read -r file; do
        cp -p "$file" "$backup/$(basename "$(dirname "$file")")-$(basename "$file").backup" 2>/dev/null || true
        chmod 600 "$file" 2>/dev/null || true
        echo "protected: $file"
      done
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    echo "protected: $ENV_FILE"
    echo
    echo "--- 2. PM2 state ---"
    if command -v pm2 >/dev/null 2>&1; then
      pm2 jlist > "$backup/pm2-jlist.json" 2>/dev/null || true
      [[ -f "${HOME}/.pm2/dump.pm2" ]] && cp -p "${HOME}/.pm2/dump.pm2" "$backup/pm2-dump.pm2"
      echo "PM2 state backed up to $backup"
    else
      echo "PM2 unavailable"
    fi
    echo
    echo "--- 3. Git repos discovered ---"
    find "$HOME" -maxdepth 5 -type d -name .git \
      -not -path "*/node_modules/*" -not -path "*/.npm/*" \
      2>/dev/null | while IFS= read -r gitdir; do
        repo="${gitdir%/.git}"
        echo "REPO: $repo ($(git -C "$repo" branch --show-current 2>/dev/null || echo '?'))"
      done
    echo
    echo "--- 4. Loopback service ports ---"
    local port result
    local ports="11434 3000 18789 ${MCP_LOCAL_PORT:-8443}"
    for port in $(printf '%s\n' $ports | grep -E '^[0-9]+$' | sort -u); do
      result="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4 \
        "http://127.0.0.1:${port}/health" 2>/dev/null || true)"
      [[ -n "$result" ]] || result="NO_RESPONSE"
      echo "PORT $port HTTP $result"
    done
    echo
    echo "Backup dir: $backup"
    echo "Report: $report"
  } | tee "$report"
  chmod 600 "$report"
}

maybe_print_cron() {
  cat <<EOF
# Optional scheduling (printed, NOT installed — human-gated).
# Cron (generic Linux):
#   15 * * * * ${HOME}/sovereign-node/run_node.sh --summary "hourly checkpoint" >> ${HOME}/sovereign-node/logs/cron.log 2>&1
# Termux (no cron daemon by default): use cronie or termux-job-scheduler:
#   pkg install cronie termux-services
#   crontab -e   # then add the line above
EOF
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --audit) AUDIT_MODE=1 ;;
      --with-cron) WITH_CRON=1 ;;
      *) log_warn "Unknown argument ignored: $arg" ;;
    esac
  done

  local py_bin
  py_bin="$(resolve_python)"
  prepare_dirs
  init_env_file "$py_bin"
  load_env_file

  write_vault_and_runner
  write_llm_router
  write_mcp_server
  write_wrapper_script

  log_info "Wiring subsystems (snippet-only; no existing app config is modified)..."
  wire_opencode "${MCP_LOCAL_PORT:-8443}"
  wire_obsidian
  wire_openhands
  check_openhands_health
  wire_openclaw

  log_info "Running initial WAL ledger + paired backup verification..."
  bash "${NODE_ROOT}/run_node.sh" --summary "Initial bootstrap check with all subsystems"

  verify_subsystems "$py_bin"

  if [[ "$AUDIT_MODE" == "1" ]]; then
    fleet_audit "$py_bin"
  fi
  if [[ "$WITH_CRON" == "1" ]]; then
    maybe_print_cron
  fi

  log_info "Complete. Workspace ready at ${NODE_ROOT}"
  log_info "Subsystems wired: ollama router, huggingface, openrouter, groq, mistral, cerebras, gemini, openai, anthropic, opencode, obsidian, openhands, openclaw, loopback MCP, fleet audit"
  log_info "Runner: ${NODE_ROOT}/run_node.sh | Router: ${NODE_ROOT}/run_llm_router.sh (prompt on stdin) | MCP: ${NODE_ROOT}/run_mcp.sh"
}

# Shellcheck-scoped helpers defined after use-prevention guard above main:
load_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    chmod 600 "$ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

main "$@"
