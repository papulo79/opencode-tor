#!/usr/bin/env python3
"""sweep-exits: enumera los exits de Tor y prueba cuáles pasan el endpoint de Zen.

Itera la lista oficial de exits (Onionoo), fuerza cada uno con
SETCONF ExitNodes=<fingerprint> StrictNodes=1 vía puerto de control, y clasifica:
ok (chat.completion), limited (FreeUsageLimitError/429), unreachable, mismatch.

Resultados append-only en JSONL (reanudable: salta fingerprints ya probados).
Uso: sweep-exits.py [--limit N] [--out PATH]
"""
import json, socket, subprocess, sys, time, urllib.request
from pathlib import Path

OPENCODE_TOR_DIR = Path.home() / ".opencode-tor"
CONTROL = ("127.0.0.1", 9051)
PROXY = "http://127.0.0.1:8118"
ZEN_URL = "https://opencode.ai/zen/v1/chat/completions"
ZEN_BODY = json.dumps({"model": "big-pickle", "messages": [{"role": "user", "content": "di hola"}], "max_tokens": 8})
ONIONOO = "https://onionoo.torproject.org/details?type=relay&running=true&flag=exit"
CIRCUIT_WAIT = 12  # NEWNYM va rate-limitado a ~10s; margen para construir el circuito


def control_password() -> str:
    cfg = json.loads((OPENCODE_TOR_DIR / "opencode.json").read_text())
    return cfg["plugin"][0][1]["controlPassword"]


class TorControl:
    def __init__(self):
        self.buf = b""

    def connect(self, password: str):
        self.sock = socket.create_connection(CONTROL, timeout=15)
        self.sock.settimeout(15)
        if not self.cmd(f'AUTHENTICATE "{password}"'):
            raise RuntimeError("auth al control de Tor fallida")

    def cmd(self, line: str) -> bool:
        self.sock.sendall(line.encode() + b"\r\n")
        # Respuestas multilínea: 250-... hasta 250 final
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
            if text[:3].isdigit():  # 5xx etc.
                return False

    def close(self):
        try:
            self.cmd("QUIT")
        except Exception:
            pass
        self.sock.close()


def curl(url: str, timeout: int, data: str | None = None) -> str:
    cmd = ["curl", "-s", "--max-time", str(timeout), "--proxy", PROXY]
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


def fetch_exits() -> list[dict]:
    with urllib.request.urlopen(ONIONOO, timeout=30) as res:
        data = json.load(res)
    return [{"fp": r["fingerprint"], "ip": r["exit_addresses"][0]} for r in data["relays"] if r.get("exit_addresses")]


def main() -> int:
    limit, out = None, OPENCODE_TOR_DIR / "exits-sweep.jsonl"
    args = sys.argv[1:]
    while args:
        if args[0] == "--limit":
            limit = int(args[1]); args = args[2:]
        elif args[0] == "--out":
            out = Path(args[1]); args = args[2:]
        else:
            args = args[1:]

    done = set()
    if out.exists():
        for line in out.read_text().splitlines():
            try:
                done.add(json.loads(line)["fp"])
            except Exception:
                pass

    exits = [e for e in fetch_exits() if e["fp"] not in done]
    if limit:
        exits = exits[:limit]
    print(f"sweep-exits: {len(done)} ya probados, {len(exits)} pendientes", flush=True)

    tor = TorControl()
    tor.connect(control_password())
    counts = {"ok": 0, "limited": 0, "unreachable": 0, "mismatch": 0, "error": 0}
    try:
        for i, exit_ in enumerate(exits):
            verdict, actual_ip = "unreachable", None
            try:
                if tor.cmd(f"SETCONF ExitNodes=${exit_['fp']} StrictNodes=1"):
                    tor.cmd("SIGNAL NEWNYM")  # ignora el rate limit de NEWNYM; el circuito cambia por SETCONF
                    time.sleep(CIRCUIT_WAIT)
                    ip_body = curl("https://api.ipify.org", 20).strip()
                    actual_ip = ip_body or None
                    if actual_ip != exit_["ip"]:
                        verdict = "mismatch"
                    else:
                        verdict = classify(curl(ZEN_URL, 45, ZEN_BODY))
            except Exception:
                # Exit caído o circuito imposible: reconectar control por si acaso
                try:
                    tor.close()
                except Exception:
                    pass
                tor = TorControl()
                tor.connect(control_password())
                verdict = "unreachable"
            counts[verdict] = counts.get(verdict, 0) + 1
            record = {"fp": exit_["fp"], "ip": exit_["ip"], "verdict": verdict}
            if actual_ip:
                record["actual_ip"] = actual_ip
            with out.open("a") as f:
                f.write(json.dumps(record) + "\n")
            print(f"[{i + 1}/{len(exits)}] {exit_['ip']} -> {verdict} (acumulado: {counts})", flush=True)
    finally:
        try:
            tor.cmd("SETCONF ExitNodes= StrictNodes=0")  # dejar Tor como estaba
            tor.close()
        except Exception:
            pass
    print(f"sweep-exits: fin. {counts}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
