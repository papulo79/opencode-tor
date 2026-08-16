#!/usr/bin/env python3
"""exit-sweep-daemon: barrido acotado de exits Tor contra el endpoint de Zen.

Se lanza al arrancar opencode-tor (detached, sobrevive al cierre) y hace UNA
pasada acotada por presupuesto de tiempo/cantidad, en este orden de prioridad:
1) revalidar exits marcados "ok" (los que usa el rotator ahora mismo)
2) probar exits nuevos (añadidos a la red desde el último barrido)
3) revisar exits "limited"/"unreachable"/"mismatch"/"error" (menor prioridad)
Termina solo al agotar el presupuesto o la cola; el siguiente lanzamiento de
opencode-tor retoma donde lo dejó (JSONL persistido, mutable por fingerprint).

Por defecto usa el MISMO Tor que la sesión en vivo (puerto de control 9051,
proxy 8118) por compatibilidad con invocaciones manuales/standalone. Cuando lo
lanza `opencode-tor`, en cambio, recibe `--control-port`/`--proxy` apuntando a
un Tor dedicado y aislado del que usa la sesión (ver opencode-tor:
start_sweep_tor) para no pisar el ExitNodes/proxy que están sirviendo tráfico
de Zen en ese momento.

Uso: exit-sweep-daemon.py [--budget-minutes N] [--budget-count N] [--out PATH]
                           [--lock PATH] [--control-port N] [--proxy URL]
"""
import json, os, signal, socket, subprocess, sys, time, urllib.request
from pathlib import Path

OPENCODE_TOR_DIR = Path.home() / ".opencode-tor"
CONTROL_HOST = "127.0.0.1"
DEFAULT_CONTROL_PORT = 9051
DEFAULT_PROXY = "http://127.0.0.1:8118"
ZEN_URL = "https://opencode.ai/zen/v1/chat/completions"
ZEN_BODY = json.dumps({"model": "big-pickle", "messages": [{"role": "user", "content": "di hola"}], "max_tokens": 8})
ONIONOO = "https://onionoo.torproject.org/details?type=relay&running=true&flag=exit"
CIRCUIT_WAIT = 12  # NEWNYM va rate-limitado a ~10s; margen para construir el circuito
DEFAULT_BUDGET_MINUTES = 30
DEFAULT_BUDGET_COUNT = 40


def control_password() -> str:
    cfg = json.loads((OPENCODE_TOR_DIR / "opencode.json").read_text())
    return cfg["plugin"][0][1]["controlPassword"]


class TorControl:
    def __init__(self):
        self.buf = b""

    def connect(self, password: str, port: int = DEFAULT_CONTROL_PORT):
        self.sock = socket.create_connection((CONTROL_HOST, port), timeout=15)
        self.sock.settimeout(15)
        if not self.cmd(f'AUTHENTICATE "{password}"'):
            raise RuntimeError("auth al control de Tor fallida")

    def cmd(self, line: str) -> bool:
        self.sock.sendall(line.encode() + b"\r\n")
        while True:
            while b"\r\n" not in self.buf:
                data = self.sock.recv(4096)
                if not data:
                    raise RuntimeError("control cerró la conexión")
                self.buf += data
            raw, self.buf = self.buf.split(b"\r\n", 1)
            text = raw.decode(errors="replace")
            if text.startswith("250 "):
                return True
            if text.startswith("250-"):
                continue
            if text[:3].isdigit():
                return False

    def close(self):
        try:
            self.cmd("QUIT")
        except Exception:
            pass
        self.sock.close()


def curl(url: str, timeout: int, proxy: str = DEFAULT_PROXY, data: str | None = None) -> str:
    cmd = ["curl", "-s", "--max-time", str(timeout), "--proxy", proxy]
    if data is not None:
        cmd += ["-H", "Authorization: Bearer public", "-H", "Content-Type: application/json", "-d", data]
    cmd.append(url)
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def classify(body: str) -> str:
    low = body.lower()
    if any(p in low for p in ("freeusagelimiterror", "rate limit", "too many", "429")):
        return "limited"
    if "chat.completion" in body:
        return "ok"
    return "error"


def fetch_onionoo_fps() -> dict:
    """fp -> ip para los exits activos ahora mismo."""
    with urllib.request.urlopen(ONIONOO, timeout=30) as res:
        data = json.load(res)
    return {r["fingerprint"]: r["exit_addresses"][0] for r in data["relays"] if r.get("exit_addresses")}


def load_known(path: Path) -> dict:
    """fp -> record (incluye ip, verdict, checked_at, actual_ip opcional)."""
    known = {}
    if not path.exists():
        return known
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            known[record["fp"]] = record
        except Exception:
            continue
    return known


def save_known(path: Path, known: dict) -> None:
    """Reescritura completa atómica (temp + rename): known es mutable por fp,
    ya no vale un append como en la versión anterior de este script."""
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as f:
        for record in known.values():
            f.write(json.dumps(record) + "\n")
    tmp.replace(path)


def select_batch(known: dict, onionoo_fps: list, budget_count: int) -> list:
    """Orden de prioridad: 1) revalidar 'ok' existentes, 2) exits nuevos
    (en onionoo, no en known), 3) el resto de known (limited/unreachable/...).
    Puro: sin I/O, para poder testear sin red ni Tor."""
    ok = [fp for fp, r in known.items() if r.get("verdict") == "ok"]
    new = [fp for fp in onionoo_fps if fp not in known]
    rest = [fp for fp in known if fp not in ok]

    seen = set()
    result = []
    for fp in ok + new + rest:
        if fp in seen:
            continue
        seen.add(fp)
        result.append(fp)
        if len(result) >= budget_count:
            break
    return result


def acquire_lock(lock_path: Path) -> bool:
    """False si ya hay un daemon vivo con ese lock (otro opencode-tor lanzado
    en paralelo); True y escribe el PID propio en caso contrario."""
    if lock_path.exists():
        try:
            pid = int(lock_path.read_text().strip())
            os.kill(pid, 0)  # no mata; solo comprueba que el proceso existe
            return False
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    lock_path.write_text(str(os.getpid()))
    return True


def release_lock(lock_path: Path) -> None:
    try:
        lock_path.unlink()
    except FileNotFoundError:
        pass


def main() -> int:
    budget_minutes, budget_count = DEFAULT_BUDGET_MINUTES, DEFAULT_BUDGET_COUNT
    out = OPENCODE_TOR_DIR / "exits-sweep.jsonl"
    lock = OPENCODE_TOR_DIR / "exit-sweep.lock"
    control_port = DEFAULT_CONTROL_PORT
    proxy = DEFAULT_PROXY
    args = sys.argv[1:]
    while args:
        if args[0] == "--budget-minutes":
            budget_minutes = int(args[1]); args = args[2:]
        elif args[0] == "--budget-count":
            budget_count = int(args[1]); args = args[2:]
        elif args[0] == "--out":
            out = Path(args[1]); args = args[2:]
        elif args[0] == "--lock":
            lock = Path(args[1]); args = args[2:]
        elif args[0] == "--control-port":
            control_port = int(args[1]); args = args[2:]
        elif args[0] == "--proxy":
            proxy = args[1]; args = args[2:]
        else:
            args = args[1:]

    if not acquire_lock(lock):
        print("exit-sweep-daemon: ya hay una pasada en curso, salgo", flush=True)
        return 0

    def cleanup(*_):
        release_lock(lock)
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    try:
        known = load_known(out)
        onionoo = fetch_onionoo_fps()
        batch = select_batch(known, list(onionoo.keys()), budget_count)
        print(f"exit-sweep-daemon: {len(batch)} exits en esta pasada (presupuesto {budget_count}/{budget_minutes}min)", flush=True)

        deadline = time.monotonic() + budget_minutes * 60
        tor = TorControl()
        tor.connect(control_password(), control_port)
        counts = {"ok": 0, "limited": 0, "unreachable": 0, "mismatch": 0, "error": 0}
        try:
            for i, fp in enumerate(batch):
                if time.monotonic() >= deadline:
                    print("exit-sweep-daemon: presupuesto de tiempo agotado, corto la pasada", flush=True)
                    break
                expected_ip = onionoo.get(fp) or known.get(fp, {}).get("ip")
                verdict, actual_ip = "unreachable", None
                try:
                    if tor.cmd(f"SETCONF ExitNodes=${fp} StrictNodes=1"):
                        tor.cmd("SIGNAL NEWNYM")
                        time.sleep(CIRCUIT_WAIT)
                        ip_body = curl("https://api.ipify.org", 20, proxy).strip()
                        actual_ip = ip_body or None
                        if expected_ip and actual_ip != expected_ip:
                            verdict = "mismatch"
                        else:
                            verdict = classify(curl(ZEN_URL, 45, proxy, ZEN_BODY))
                except Exception:
                    try:
                        tor.close()
                    except Exception:
                        pass
                    tor = TorControl()
                    tor.connect(control_password(), control_port)
                    verdict = "unreachable"
                counts[verdict] = counts.get(verdict, 0) + 1
                known[fp] = {
                    "fp": fp,
                    "ip": expected_ip or known.get(fp, {}).get("ip", ""),
                    "verdict": verdict,
                    "checked_at": int(time.time() * 1000),
                    **({"actual_ip": actual_ip} if actual_ip else {}),
                }
                save_known(out, known)
                print(f"[{i + 1}/{len(batch)}] {fp} -> {verdict} (acumulado: {counts})", flush=True)
        finally:
            try:
                tor.cmd("SETCONF ExitNodes= StrictNodes=0")
                tor.close()
            except Exception:
                pass
        print(f"exit-sweep-daemon: fin de pasada. {counts}", flush=True)
        return 0
    finally:
        release_lock(lock)


if __name__ == "__main__":
    sys.exit(main())
