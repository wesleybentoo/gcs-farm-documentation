"""
Farmbox API — Teste completo de endpoints
Salva cada resposta em JSON em ./farmbox_responses/

Auth confirmado pela Postman collection:
    Header  ->  Authorization: <TOKEN>   (token CRU, sem 'Bearer'/'Token')
    BaseURL ->  https://farmbox.cc/api/v1
    Respostas vêm em envelope: {"<recurso>": [...], "pagination": {...}}

Uso:
    python farmbox_test_endpoints.py

Requisitos: Python 3.8+ (sem dependências externas)
"""

import urllib.request
import urllib.error
import json
import os
import sys
import time
from datetime import datetime, timezone

# ─── Configuração ────────────────────────────────────────────────────────────
TOKEN   = "Hlr3mHzEfGSTiwt1v5aFIA"
BASE    = "https://farmbox.cc/api/v1"
OUT_DIR = os.path.join(os.path.dirname(__file__), "farmbox_responses")
# ─────────────────────────────────────────────────────────────────────────────

# A collection usa apikey no header Authorization com o token CRU.
# Mantemos fallbacks só por segurança, mas o primeiro é o que funciona.
AUTH_HEADERS_TO_TRY = [
    {"Authorization": TOKEN},                 # ✅ formato correto (token cru)
    {"Authorization": f"Bearer {TOKEN}"},
    {"Authorization": f"Token {TOKEN}"},
    {"X-Api-Token": TOKEN},
]

# Endpoints de listagem (GET) extraídos da Postman collection.
# Não fazemos mutações (POST/PUT/DELETE).
ENDPOINTS = [
    # ── Estruturas ──
    ("activity_types",           "/activity_types"),
    ("beaks",                    "/beaks"),
    ("cultures",                 "/cultures"),
    ("varieties",                "/varieties"),
    ("equipments",               "/equipments"),
    ("farms",                    "/farms"),
    ("harvests",                 "/harvests"),
    ("phenological_stages",      "/phenological_stages"),
    ("plantations",              "/plantations"),
    ("plots",                    "/plots"),
    ("pluviometers",             "/pluviometers"),
    ("storages",                 "/storages"),
    ("users",                    "/users"),
    # ── Insumos ──
    ("input_types",              "/input_types"),
    ("inputs",                   "/inputs"),
    ("input_values",             "/input_values"),
    ("batches",                  "/batches"),
    ("movimentations",           "/movimentations"),
    # ── Operações / Monitoramento ──
    ("monitorings",              "/monitorings"),
    ("monitoring_day_results",   "/monitoring_day_results"),
    ("monitoring_tolerances",    "/monitoring_tolerances"),
    ("applications",             "/applications"),
    ("count_days",               "/count_days"),
    ("count_monitorings",        "/count_monitorings"),
    ("notes",                    "/notes"),
    ("pluviometer_monitorings",  "/pluviometer_monitorings"),
    ("phenological_stage_samples", "/phenological_stage_samples"),
    ("trap_monitorings",         "/trap_monitorings"),
    ("resource_subscriptions",   "/resource_subscriptions"),
]

os.makedirs(OUT_DIR, exist_ok=True)

# Chaves de envelope que NÃO são a lista de dados
META_KEYS = {"pagination", "next_page_url", "deleted_since", "meta", "links"}


def fetch(url, headers):
    req = urllib.request.Request(url, headers={**headers, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode("utf-8")
            return r.status, body, None
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8") if e.fp else ""
        return e.code, body, None
    except Exception as ex:
        return None, None, str(ex)


def extract_list(data):
    """Dado o envelope da Farmbox, devolve (lista_de_registros, chave) ou (None, None)."""
    if isinstance(data, list):
        return data, None
    if isinstance(data, dict):
        for k, v in data.items():
            if k not in META_KEYS and isinstance(v, list):
                return v, k
    return None, None


def parse(body):
    try:
        return json.loads(body) if body else None
    except json.JSONDecodeError:
        return {"raw": body[:500]}


def detect_auth(base_url):
    """Testa variações de header de autenticação em /farms."""
    print("\n🔑 Detectando formato de autenticação...")
    for headers in AUTH_HEADERS_TO_TRY:
        k, v = list(headers.items())[0]
        status, body, err = fetch(f"{base_url}/farms", headers)
        if err:
            print(f"  💥 {k}: {v[:30]}... → ERRO: {err}")
            continue
        print(f"  {'✅' if status == 200 else '❌'} {k}: {v[:30]}... → HTTP {status}")
        if status == 200:
            return headers
    return None


def test_endpoints(auth_headers):
    results = {}
    print(f"\n📡 Testando {len(ENDPOINTS)} endpoints...\n")

    farm_id = None
    plantation_id = None
    monitoring_id = None
    application_id = None

    for name, path in ENDPOINTS:
        url = f"{BASE}{path}"
        print(f"  GET {path:<32}", end="", flush=True)

        status, body, err = fetch(url, auth_headers)
        if err:
            print(f"💥 ERRO: {err}")
            results[name] = {"error": err, "url": url}
            continue

        data = parse(body)
        items, key = extract_list(data)
        count_str = f" ({len(items)} registros via '{key}')" if items is not None else ""
        print(f"HTTP {status}{count_str}")

        results[name] = {"status": status, "url": url, "data": data}

        # Captura IDs reais para os testes /:id
        if items:
            first = items[0] if isinstance(items[0], dict) else {}
            if name == "farms" and farm_id is None:
                farm_id = first.get("id")
            if name == "plantations" and plantation_id is None:
                plantation_id = first.get("id")
            if name == "monitorings" and monitoring_id is None:
                monitoring_id = first.get("id")
            if name == "applications" and application_id is None:
                application_id = first.get("id")

        time.sleep(0.3)  # rate limit gentil

    # ── Testes com IDs reais (recursos aninhados) ──
    id_tests = []
    if farm_id:
        id_tests.append(("farms_by_id", f"/farms/{farm_id}"))
    if plantation_id:
        id_tests.append(("plantation_by_id", f"/plantations/{plantation_id}"))
        id_tests.append(("plantation_cropped_volumes",
                         f"/plantations/{plantation_id}/cropped_volumes"))
    if monitoring_id:
        id_tests.append(("monitoring_by_id", f"/monitorings/{monitoring_id}"))
    if application_id:
        id_tests.append(("application_by_id", f"/applications/{application_id}"))
        id_tests.append(("application_progresses",
                         f"/applications/{application_id}/application_progresses"))

    if id_tests:
        print(f"\n  ── Testes com IDs reais ──")
    for name, path in id_tests:
        url = f"{BASE}{path}"
        print(f"  GET {path:<48}", end="", flush=True)
        status, body, err = fetch(url, auth_headers)
        if err:
            print(f"💥 {err}")
            results[name] = {"error": err, "url": url}
            continue
        data = parse(body)
        print(f"HTTP {status}")
        results[name] = {"status": status, "url": url, "data": data}
        time.sleep(0.3)

    return results


def save_results(results, auth_headers):
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    summary_path = os.path.join(OUT_DIR, f"_summary_{ts}.json")
    full_path    = os.path.join(OUT_DIR, f"_full_{ts}.json")

    with open(full_path, "w", encoding="utf-8") as f:
        json.dump({
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "auth_header": list(auth_headers.keys())[0],
            "base_url": BASE,
            "results": results,
        }, f, indent=2, ensure_ascii=False)

    summary = {}
    for name, res in results.items():
        if "error" in res:
            summary[name] = {"error": res["error"], "url": res.get("url")}
            continue
        data = res.get("data")
        items, key = extract_list(data)
        fields = None
        if items and isinstance(items[0], dict):
            fields = list(items[0].keys())
        summary[name] = {
            "status": res.get("status"),
            "url": res.get("url"),
            "count": len(items) if items is not None else "?",
            "list_key": key,
            "fields": fields,
        }

    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)

    for name, res in results.items():
        ep_path = os.path.join(OUT_DIR, f"{name}.json")
        with open(ep_path, "w", encoding="utf-8") as f:
            json.dump(res.get("data"), f, indent=2, ensure_ascii=False)

    print(f"\n✅ Respostas salvas em: {OUT_DIR}")
    print(f"   Resumo:   {summary_path}")
    print(f"   Completo: {full_path}")
    return summary_path, full_path


def main():
    print("=" * 60)
    print("  Farmbox API — Teste de Endpoints")
    print(f"  Base URL : {BASE}")
    print(f"  Token    : {TOKEN[:8]}***")
    print("=" * 60)

    auth = detect_auth(BASE)
    if not auth:
        print("\n❌ Nenhum formato de autenticação funcionou. Verifique o token.")
        sys.exit(1)

    auth_key = list(auth.keys())[0]
    auth_val = list(auth.values())[0]
    print(f"\n✅ Auth confirmado: {auth_key}: {auth_val}")

    results = test_endpoints(auth)
    save_results(results, auth)

    print("\n─── Sumário ───────────────────────────────────────────────")
    ok  = sum(1 for r in results.values() if r.get("status") == 200)
    err = sum(1 for r in results.values() if r.get("status") != 200 or "error" in r)
    print(f"  ✅ {ok} endpoints OK  |  ❌ {err} com erro")


if __name__ == "__main__":
    main()
