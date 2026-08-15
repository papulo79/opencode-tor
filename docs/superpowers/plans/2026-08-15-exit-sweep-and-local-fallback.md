# Exit Sweep Daemon + Local Model Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the `plugins/ip-rotate` plugin (a) a background daemon that keeps a list of known-good Tor exits fresh so the rotator stops rotating blind, and (b) an automatic fallback to a local llama.cpp model when no Zen-usable exit remains, with automatic revert once Zen's rate limit resets.

**Architecture:** Everything lives in `plugins/ip-rotate/` (Python for the sweep daemon, TypeScript for the plugin), never in `packages/`, so it survives any upstream core sync. The rotator reads a JSONL file the daemon maintains before falling back to blind `NEWNYM`; the plugin's event handler falls back to a local model (reusing the existing `resumer.prompt` call, extended to carry a model override) once rotations are exhausted, tracking a global "Zen blocked until X" state persisted to disk and reverting automatically via a scheduled timer.

**Tech Stack:** Bun/TypeScript (existing plugin code), Python 3 stdlib only (existing daemon script), Bash (existing wrapper/installer).

**Spec:** `docs/superpowers/specs/2026-08-15-exit-sweep-and-local-fallback.md`

## Global Constraints

- Nothing in this plan touches `packages/`; all changes are under `plugins/ip-rotate/`.
- No new runtime dependencies (no npm packages, no Python packages beyond stdlib).
- No HTTP server for the sweep daemon — the rotator reads `exits-sweep.jsonl` directly from disk.
- Every degrade path must be silent (log + fall back), never throw into the session.
- Follow existing style: no semicolons in TS, `const`, early returns, no `any`, Prettier printWidth 120 (root `AGENTS.md`).
- Tests run from the package dir: `cd plugins/ip-rotate && bun test` (TS) and the `test/*.sh` scripts directly (shell), plus `python3 plugins/ip-rotate/test/sweep-budget.test.py` (new, pure Python unit test, no network/Tor).

---

### Task 1: Pure exit-pool selection logic (`src/exit-pool.ts`)

**Files:**
- Create: `plugins/ip-rotate/src/exit-pool.ts`
- Test: `plugins/ip-rotate/test/exit-pool.test.ts`

**Interfaces:**
- Produces: `ExitRecord = { fp: string; ip: string; verdict: "ok" | "limited" | "unreachable" | "mismatch" | "error"; checked_at?: number }`, `parseExitPool(jsonl: string): ExitRecord[]`, `pickKnownGoodExit(records: ExitRecord[], excludeIp?: string): ExitRecord | undefined`. Task 2 (rotator) consumes both.

- [ ] **Step 1: Write the failing test**

```ts
// plugins/ip-rotate/test/exit-pool.test.ts
import { describe, expect, test } from "bun:test"
import { parseExitPool, pickKnownGoodExit } from "../src/exit-pool"

const jsonl = [
  JSON.stringify({ fp: "AAA", ip: "1.1.1.1", verdict: "ok", checked_at: 100 }),
  JSON.stringify({ fp: "BBB", ip: "2.2.2.2", verdict: "ok", checked_at: 200 }),
  JSON.stringify({ fp: "CCC", ip: "3.3.3.3", verdict: "limited", checked_at: 300 }),
  "not json",
  "",
].join("\n")

describe("parseExitPool", () => {
  test("ignora líneas vacías o inválidas", () => {
    expect(parseExitPool(jsonl)).toHaveLength(3)
  })
})

describe("pickKnownGoodExit", () => {
  test("elige el ok más reciente", () => {
    expect(pickKnownGoodExit(parseExitPool(jsonl))?.fp).toBe("BBB")
  })

  test("excluye la IP actual", () => {
    expect(pickKnownGoodExit(parseExitPool(jsonl), "2.2.2.2")?.fp).toBe("AAA")
  })

  test("undefined si no hay ok", () => {
    const onlyLimited = JSON.stringify({ fp: "X", ip: "9.9.9.9", verdict: "limited" })
    expect(pickKnownGoodExit(parseExitPool(onlyLimited))).toBeUndefined()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/ip-rotate && bun test test/exit-pool.test.ts`
Expected: FAIL — `../src/exit-pool` not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// plugins/ip-rotate/src/exit-pool.ts
export type ExitRecord = {
  fp: string
  ip: string
  verdict: "ok" | "limited" | "unreachable" | "mismatch" | "error"
  checked_at?: number
}

export function parseExitPool(jsonl: string): ExitRecord[] {
  return jsonl
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .flatMap((line) => {
      try {
        const record = JSON.parse(line)
        return isExitRecord(record) ? [record] : []
      } catch {
        return []
      }
    })
}

export function pickKnownGoodExit(records: ExitRecord[], excludeIp?: string): ExitRecord | undefined {
  return records
    .filter((r) => r.verdict === "ok" && r.ip !== excludeIp)
    .sort((a, b) => (b.checked_at ?? 0) - (a.checked_at ?? 0))[0]
}

function isExitRecord(value: unknown): value is ExitRecord {
  if (value === null || typeof value !== "object") return false
  const r = value as Record<string, unknown>
  return typeof r.fp === "string" && typeof r.ip === "string" && typeof r.verdict === "string"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/ip-rotate && bun test test/exit-pool.test.ts`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add plugins/ip-rotate/src/exit-pool.ts plugins/ip-rotate/test/exit-pool.test.ts
git commit -m "feat(plugin): add pure exit-pool selection logic"
```

---

### Task 2: Rotator tries a known-good exit before blind NEWNYM

**Files:**
- Modify: `plugins/ip-rotate/src/rotator.ts` (refactor `sendNewnym` into `sendCommands`, add `rotateToKnownGood`, wire into `rotateUntilClean`)
- Modify: `plugins/ip-rotate/src/config.ts` (add `exitPoolPath`)
- Test: `plugins/ip-rotate/test/rotator-known-good.test.ts`

**Interfaces:**
- Consumes: `parseExitPool`, `pickKnownGoodExit`, `ExitRecord` from Task 1.
- Produces: `Rotator.rotateToKnownGood?(excludeIp?: string): Promise<string | undefined>` (optional interface member, same pattern as existing `rotateUntilClean?`). `Config.exitPoolPath: string`.

- [ ] **Step 1: Add `exitPoolPath` to config**

In `plugins/ip-rotate/src/config.ts`, add the import and field:

```ts
import { homedir } from "node:os"
import { join } from "node:path"
```

Add to `Config` type: `exitPoolPath: string`.
Add to `DEFAULTS`: `exitPoolPath: join(homedir(), ".opencode-tor", "exits-sweep.jsonl"),`.
Add to `parseConfig` return object: `exitPoolPath: str("exitPoolPath") ?? DEFAULTS.exitPoolPath,`.

- [ ] **Step 2: Write the failing test**

```ts
// plugins/ip-rotate/test/rotator-known-good.test.ts
import { describe, expect, test } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { parseConfig } from "../src/config"
import { createRotator } from "../src/rotator"

function fakeControlServer(onCommand: (line: string) => void) {
  return Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: {
      data(socket, data) {
        const text = new TextDecoder().decode(data)
        for (const line of text.split("\r\n")) {
          if (!line) continue
          onCommand(line)
          socket.write("250 OK\r\n")
        }
      },
      open() {},
      close() {},
      error() {},
    },
  })
}

describe("rotator known-good exit", () => {
  test("fuerza SETCONF con el fingerprint conocido y devuelve la IP nueva", async () => {
    const commands: string[] = []
    const control = fakeControlServer((line) => commands.push(line))

    let ipCalls = 0
    const ipServer = Bun.serve({
      port: 0,
      fetch() {
        ipCalls++
        return new Response(ipCalls === 1 ? "9.9.9.9" : "1.1.1.1")
      },
    })

    const dir = mkdtempSync(join(tmpdir(), "ip-rotate-"))
    const poolPath = join(dir, "exits-sweep.jsonl")
    writeFileSync(poolPath, JSON.stringify({ fp: "GOODFP", ip: "1.1.1.1", verdict: "ok", checked_at: 1 }) + "\n")

    const config = parseConfig({
      controlPort: control.port,
      verifyUrl: `http://127.0.0.1:${ipServer.port}`,
      proxyUrl: "",
      exitPoolPath: poolPath,
    })
    const rotator = createRotator(config)

    const next = await rotator.rotateToKnownGood!("9.9.9.9")

    control.stop(true)
    ipServer.stop(true)

    expect(next).toBe("1.1.1.1")
    expect(commands.some((c) => c.includes("SETCONF ExitNodes=GOODFP StrictNodes=1"))).toBe(true)
  })

  test("undefined si el pool no existe", async () => {
    const control = fakeControlServer(() => {})
    const config = parseConfig({
      controlPort: control.port,
      exitPoolPath: "/nonexistent/exits-sweep.jsonl",
    })
    const rotator = createRotator(config)
    const next = await rotator.rotateToKnownGood!(undefined)
    control.stop(true)
    expect(next).toBeUndefined()
  })
})
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd plugins/ip-rotate && bun test test/rotator-known-good.test.ts`
Expected: FAIL — `rotateToKnownGood` is not a function.

- [ ] **Step 4: Refactor `sendNewnym` into `sendCommands` and add `rotateToKnownGood`**

In `plugins/ip-rotate/src/rotator.ts`, add the import:

```ts
import { parseExitPool, pickKnownGoodExit } from "./exit-pool"
```

Add `rotateToKnownGood?` to the `Rotator` interface:

```ts
export interface Rotator {
  currentIp(): Promise<string | undefined>
  rotate(): Promise<string | undefined>
  rotateUntilClean?(): Promise<string | undefined>
  rotateToKnownGood?(excludeIp?: string): Promise<string | undefined>
}
```

Replace the `private async sendNewnym(): Promise<boolean>` method body with a generalized `sendCommands`, and add `rotateToKnownGood`:

```ts
  async rotateToKnownGood(excludeIp?: string): Promise<string | undefined> {
    let records
    try {
      records = parseExitPool(await Bun.file(this.config.exitPoolPath).text())
    } catch {
      return undefined
    }
    const candidate = pickKnownGoodExit(records, excludeIp)
    if (!candidate) return undefined

    const ok = await this.setExitNode(candidate.fp)
    if (!ok) return undefined

    await new Promise((resolve) => setTimeout(resolve, 10000))
    const next = await this.currentIp()
    if (next === undefined || next === excludeIp) return undefined
    return next
  }

  private setExitNode(fingerprint: string): Promise<boolean> {
    return this.sendCommands([`SETCONF ExitNodes=${fingerprint} StrictNodes=1`, "SIGNAL NEWNYM"])
  }

  private sendNewnym(): Promise<boolean> {
    return this.sendCommands(["SIGNAL NEWNYM"])
  }

  private async sendCommands(cmds: string[]): Promise<boolean> {
    const { config } = this
    try {
      let buffer = ""
      const pending: Array<(ok: boolean) => void> = []

      const socket = await Promise.race([
        Bun.connect({
          hostname: "127.0.0.1",
          port: config.controlPort,
          socket: {
            data(socket, data) {
              buffer += new TextDecoder().decode(data)
              let idx: number
              while ((idx = buffer.indexOf("\r\n")) !== -1) {
                const line = buffer.slice(0, idx)
                buffer = buffer.slice(idx + 2)
                const isOk = line.startsWith("250")
                if (!line.startsWith("250-")) {
                  const resolve = pending.shift()
                  if (resolve) resolve(isOk)
                }
              }
            },
            open() {},
            error() {},
            close() {},
          },
        }),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error("connect timeout")), 5000)),
      ])

      const send = (cmd: string) =>
        new Promise<boolean>((resolve) => {
          pending.push(resolve)
          socket.write(cmd)
          setTimeout(() => {
            const idx = pending.indexOf(resolve)
            if (idx !== -1) pending.splice(idx, 1)
            resolve(false)
          }, 5000)
        })

      const authOk = await send(`AUTHENTICATE "${config.controlPassword || ""}"\r\n`)
      if (!authOk) {
        socket.end()
        socket.close()
        return false
      }
      let allOk = true
      for (const cmd of cmds) {
        const ok = await send(`${cmd}\r\n`)
        if (!ok) allOk = false
      }
      socket.write("QUIT\r\n")
      socket.end()
      socket.close()
      return allOk
    } catch {
      return false
    }
  }
```

Delete the old `sendNewnym` implementation (the one with the inlined AUTHENTICATE/SIGNAL NEWNYM/QUIT logic) — it's now `sendCommands(["SIGNAL NEWNYM"])`.

- [ ] **Step 5: Wire `rotateToKnownGood` into `rotateUntilClean`**

Replace the body of `rotateUntilClean`:

```ts
  async rotateUntilClean(): Promise<string | undefined> {
    const current = await this.currentIp()
    if (current !== undefined && (await probeModel(this.config))) return current

    const known = await this.rotateToKnownGood(current)
    if (known !== undefined) {
      console.log(`[ip-rotate] exit conocido probado: ${known}`)
      if (await probeModel(this.config)) return known
      console.log("[ip-rotate] exit conocido ya no sirve, rotando a ciegas")
    }

    for (let attempt = 1; attempt <= this.config.probeMaxAttempts; attempt++) {
      const next = await this.rotate()
      if (next === undefined) continue
      console.log(`[ip-rotate] intento ${attempt}: probando exit ${next} contra ${this.config.probeModel}`)
      if (await probeModel(this.config)) return next
      console.log(`[ip-rotate] intento ${attempt}: exit ${next} limitado, rotando de nuevo`)
    }
    return undefined
  }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd plugins/ip-rotate && bun test`
Expected: all tests pass (existing 19 + 5 new = 24).

- [ ] **Step 7: Commit**

```bash
git add plugins/ip-rotate/src/rotator.ts plugins/ip-rotate/src/config.ts plugins/ip-rotate/test/rotator-known-good.test.ts
git commit -m "feat(plugin): try known-good exit from sweep pool before blind rotation"
```

---

### Task 3: Exit-sweep daemon script (budget + priority, pure logic tested separately)

**Files:**
- Create: `plugins/ip-rotate/exit-sweep-daemon.py` (replaces `plugins/ip-rotate/sweep-exits.py`)
- Delete: `plugins/ip-rotate/sweep-exits.py`
- Test: `plugins/ip-rotate/test/sweep-budget.test.py`

**Interfaces:**
- Produces: `select_batch(known: dict, onionoo_fps: list, budget_count: int) -> list` (pure, no I/O — Task 5's wrapper integration and README reference this script's CLI flags: `--budget-minutes`, `--budget-count`, `--out`, `--lock`).

- [ ] **Step 1: Write the failing test for the pure priority function**

```python
#!/usr/bin/env python3
# plugins/ip-rotate/test/sweep-budget.test.py
import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "exit-sweep-daemon.py"
spec = importlib.util.spec_from_file_location("exit_sweep_daemon", MODULE_PATH)
daemon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(daemon)


class TestSelectBatch(unittest.TestCase):
    def test_prioritizes_ok_then_new_then_rest(self):
        known = {"A": {"verdict": "ok"}, "B": {"verdict": "limited"}}
        onionoo = ["A", "B", "C"]
        result = daemon.select_batch(known, onionoo, budget_count=10)
        self.assertEqual(result, ["A", "C", "B"])

    def test_respects_budget_count(self):
        known = {"A": {"verdict": "ok"}, "B": {"verdict": "ok"}}
        result = daemon.select_batch(known, ["A", "B"], budget_count=1)
        self.assertEqual(result, ["A"])

    def test_no_duplicates_when_known_fp_also_in_onionoo(self):
        known = {"A": {"verdict": "limited"}}
        result = daemon.select_batch(known, ["A"], budget_count=10)
        self.assertEqual(result, ["A"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 plugins/ip-rotate/test/sweep-budget.test.py`
Expected: FAIL — `plugins/ip-rotate/exit-sweep-daemon.py` doesn't exist yet.

- [ ] **Step 3: Create `exit-sweep-daemon.py`**

```python
#!/usr/bin/env python3
"""exit-sweep-daemon: barrido acotado de exits Tor contra el endpoint de Zen.

Se lanza al arrancar opencode-tor (detached, sobrevive al cierre) y hace UNA
pasada acotada por presupuesto de tiempo/cantidad, en este orden de prioridad:
1) revalidar exits marcados "ok" (los que usa el rotator ahora mismo)
2) probar exits nuevos (añadidos a la red desde el último barrido)
3) revisar exits "limited"/"unreachable"/"mismatch"/"error" (menor prioridad)
Termina solo al agotar el presupuesto o la cola; el siguiente lanzamiento de
opencode-tor retoma donde lo dejó (JSONL persistido, mutable por fingerprint).
Uso: exit-sweep-daemon.py [--budget-minutes N] [--budget-count N] [--out PATH] [--lock PATH]
"""
import json, os, signal, socket, subprocess, sys, time, urllib.request
from pathlib import Path

OPENCODE_TOR_DIR = Path.home() / ".opencode-tor"
CONTROL = ("127.0.0.1", 9051)
PROXY = "http://127.0.0.1:8118"
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

    def connect(self, password: str):
        self.sock = socket.create_connection(CONTROL, timeout=15)
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
        tor.connect(control_password())
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
                        ip_body = curl("https://api.ipify.org", 20).strip()
                        actual_ip = ip_body or None
                        if expected_ip and actual_ip != expected_ip:
                            verdict = "mismatch"
                        else:
                            verdict = classify(curl(ZEN_URL, 45, ZEN_BODY))
                except Exception:
                    try:
                        tor.close()
                    except Exception:
                        pass
                    tor = TorControl()
                    tor.connect(control_password())
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
```

- [ ] **Step 4: Remove the old script**

```bash
git rm plugins/ip-rotate/sweep-exits.py
```

- [ ] **Step 5: Run test to verify it passes**

Run: `python3 plugins/ip-rotate/test/sweep-budget.test.py -v`
Expected: PASS (3 tests), no network/Tor access performed (the module-level network calls are guarded by `if __name__ == "__main__":`).

- [ ] **Step 6: Commit**

```bash
git add plugins/ip-rotate/exit-sweep-daemon.py plugins/ip-rotate/test/sweep-budget.test.py
git commit -m "feat(plugin): replace one-shot sweep-exits.py with budgeted exit-sweep-daemon.py"
```

---

### Task 4: Wrapper launches the daemon detached, with lock check

**Files:**
- Modify: `plugins/ip-rotate/opencode-tor` (add `start_exit_sweep_daemon`, call it after `wait_ready`)
- Modify: `plugins/ip-rotate/test/wrapper.test.sh`

**Interfaces:**
- Consumes: `exit-sweep-daemon.py` CLI flags from Task 3 (`--out`, `--lock`; budget flags left at their defaults here).
- Produces: env var `EXIT_SWEEP_DAEMON_CMD` (test seam, same pattern as `OPENCODE_TOR_BIN`), lock file at `$OPENCODE_TOR_DIR/exit-sweep.lock`.

- [ ] **Step 1: Add the daemon launcher to the wrapper**

In `plugins/ip-rotate/opencode-tor`, add near the top (with the other env defaults):

```bash
EXIT_SWEEP_DAEMON_CMD="${EXIT_SWEEP_DAEMON_CMD:-python3 $OPENCODE_TOR_DIR/plugins/ip-rotate/exit-sweep-daemon.py}"
```

Add the function (after `print_banner`, before `trap stop_tor EXIT`):

```bash
start_exit_sweep_daemon() {
  local lock="$OPENCODE_TOR_DIR/exit-sweep.lock"
  if [ -f "$lock" ]; then
    local pid
    pid=$(cat "$lock" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "opencode-tor: barrido de exits ya en curso (pid $pid)"
      return 0
    fi
  fi
  # shellcheck disable=SC2086
  set -- $EXIT_SWEEP_DAEMON_CMD
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "opencode-tor: '$1' no disponible, sin barrido de exits en background" >&2
    return 0
  fi
  setsid "$@" --out "$OPENCODE_TOR_DIR/exits-sweep.jsonl" --lock "$lock" \
    >"$OPENCODE_TOR_DIR/exit-sweep.log" 2>&1 < /dev/null &
  disown
  echo "opencode-tor: barrido de exits lanzado en background"
}
```

Call it right after `wait_ready` (before exporting the proxy env vars, order doesn't matter but keep it grouped with Tor startup):

```bash
start_tor
if [ "${OPENCODE_TOR_SKIP_READY:-}" != "1" ]; then
  wait_ready
fi
start_exit_sweep_daemon
```

- [ ] **Step 2: Syntax check**

Run: `bash -n plugins/ip-rotate/opencode-tor`
Expected: no errors.

- [ ] **Step 3: Extend `wrapper.test.sh` — daemon gets launched**

Add to `plugins/ip-rotate/test/wrapper.test.sh`, before the final `OPENCODE_TOR_DIR=... "$PWD/opencode-tor" ...` invocation:

```bash
# Stub del daemon de sweep: registra su invocación.
export EXIT_SWEEP_LOG="$WORK/exit-sweep-calls.log"
cat > "$WORK/fake-daemon.sh" <<'STUB'
#!/usr/bin/env bash
echo "daemon args: $*" >> "$EXIT_SWEEP_LOG"
STUB
chmod +x "$WORK/fake-daemon.sh"
```

Add `EXIT_SWEEP_DAEMON_CMD="$WORK/fake-daemon.sh"` to the env vars of the existing wrapper invocation line (same `OPENCODE_TOR_DIR=... PATH=... "$PWD/opencode-tor" "run" "hola mundo"` call).

After the existing assertions, add:

```bash
grep -q "daemon args: --out $WORK/exits-sweep.jsonl --lock $WORK/exit-sweep.lock" "$EXIT_SWEEP_LOG" \
  || { echo "FAIL: daemon de sweep no se lanzó con los args esperados"; cat "$EXIT_SWEEP_LOG" 2>&1; exit 1; }
echo "PASS: daemon de sweep lanzado"

# Segunda invocación con lock ya tomado por un proceso vivo (este propio shell
# de test, $$): el daemon NO debe relanzarse.
: > "$EXIT_SWEEP_LOG"
echo "$$" > "$WORK/exit-sweep.lock"
OPENCODE_TOR_DIR="$WORK" \
OPENCODE_TOR_BIN="$WORK/bin/opencode" \
OPENCODE_TOR_CONTAINER="ip-rotate-tor-test" \
OPENCODE_TOR_SKIP_READY=1 \
OPENCODE_TOR_KEEP=1 \
EXIT_SWEEP_DAEMON_CMD="$WORK/fake-daemon.sh" \
PATH="$WORK:$PATH" \
"$PWD/opencode-tor" "run" "hola de nuevo" > "$WORK/out2.log" 2>&1 || true

[ ! -s "$EXIT_SWEEP_LOG" ] || { echo "FAIL: daemon relanzado con lock ya tomado"; cat "$EXIT_SWEEP_LOG"; exit 1; }
grep -q "barrido de exits ya en curso" "$WORK/out2.log" \
  || { echo "FAIL: no se avisó del lock activo"; cat "$WORK/out2.log"; exit 1; }
echo "PASS: lock respetado, daemon no duplicado"
```

- [ ] **Step 4: Run the test**

Run: `cd plugins/ip-rotate && test/wrapper.test.sh`
Expected: `PASS: wrapper test`, `PASS: daemon de sweep lanzado`, `PASS: lock respetado, daemon no duplicado`.

- [ ] **Step 5: Commit**

```bash
git add plugins/ip-rotate/opencode-tor plugins/ip-rotate/test/wrapper.test.sh
git commit -m "feat(plugin): launch exit-sweep daemon detached from the wrapper, guarded by lockfile"
```

---

### Task 5: Package the daemon into the installer

**Files:**
- Modify: `plugins/ip-rotate/build-install.sh`

- [ ] **Step 1: Add the existence check and base64 payload**

Add to the file-existence checks near the top (with the other `[ -f ... ] || { echo "falta ..."; exit 1; }` lines):

```bash
[ -f "$PLUGIN_DIR/exit-sweep-daemon.py" ] || { echo "falta exit-sweep-daemon.py" >&2; exit 1; }
```

Add alongside the other `*_B64=` assignments:

```bash
DAEMON_B64=$(base64 < "$PLUGIN_DIR/exit-sweep-daemon.py" | tr -d '\n')
```

- [ ] **Step 2: Add the placeholder and deployment step**

Add to the placeholder block (with `TORRC_B64='__TORRC_B64__'` etc.):

```bash
DAEMON_B64='__DAEMON_B64__'
```

After the `# --- 5c. logo TUI ---` deployment block (which writes `art/opencode-tor.txt`), add:

```bash
# --- 5e. exit-sweep daemon ---
echo "$DAEMON_B64" | base64 -d > "$PLUGIN_OUT/exit-sweep-daemon.py"
chmod 755 "$PLUGIN_OUT/exit-sweep-daemon.py"
```

- [ ] **Step 3: Add to the final sed substitution**

Update the `sed` line to include `__DAEMON_B64__`:

```bash
sed 's|__PLUGIN_B64__|'"$PLUGIN_B64"'|; s|__WRAPPER_B64__|'"$WRAPPER_B64"'|; s|__UNINSTALL_B64__|'"$UNINSTALL_B64"'|; s|__REFRESH_B64__|'"$REFRESH_B64"'|; s|__TUI_LOGO_B64__|'"$TUI_LOGO_B64"'|; s|__ART_B64__|'"$ART_B64"'|; s|__DAEMON_B64__|'"$DAEMON_B64"'|; s|__TORRC_B64__|'"$TORRC_B64"'|' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
```

- [ ] **Step 4: Extend `generator.test.sh`**

Add to `plugins/ip-rotate/test/generator.test.sh`:

```bash
grep -q '__DAEMON_B64__' "$OUT" && { echo "FAIL: placeholder daemon sin sustituir"; exit 1; }
```

- [ ] **Step 5: Regenerate and run tests**

```bash
cd plugins/ip-rotate
bash -n build-install.sh
./build-install.sh
bash -n install-opencode-tor.sh
test/generator.test.sh
```

Expected: `bash -n` clean on both scripts; `PASS: generator smoke test`.

- [ ] **Step 6: Commit**

```bash
git add plugins/ip-rotate/build-install.sh plugins/ip-rotate/install-opencode-tor.sh plugins/ip-rotate/test/generator.test.sh
git commit -m "feat(plugin): embed exit-sweep-daemon.py in the installer"
```

---

### Task 6: `localModel` config option

**Files:**
- Modify: `plugins/ip-rotate/src/config.ts`

**Interfaces:**
- Produces: `Config.localModel?: { providerID: string; modelID: string }`. Task 8 (index.ts) and Task 9 (build-install.sh) consume this.

- [ ] **Step 1: Add the field and parsing**

Add to the `Config` type:

```ts
localModel?: { providerID: string; modelID: string }
```

Add a helper (near `isString`/`isNumber`):

```ts
function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object"
}
```

In `parseConfig`, before the `return`:

```ts
const localModelInput = options.localModel
const localModel =
  isRecord(localModelInput) && isString(localModelInput.providerID) && isString(localModelInput.modelID)
    ? { providerID: localModelInput.providerID, modelID: localModelInput.modelID }
    : undefined
```

Add to the returned object: `localModel,`.

- [ ] **Step 2: Write the test**

```ts
// Add to plugins/ip-rotate/test/config.test.ts (create if it doesn't exist)
import { describe, expect, test } from "bun:test"
import { parseConfig } from "../src/config"

describe("parseConfig localModel", () => {
  test("undefined si no se pasa", () => {
    expect(parseConfig({}).localModel).toBeUndefined()
  })

  test("se recoge cuando viene bien formado", () => {
    const config = parseConfig({ localModel: { providerID: "local", modelID: "qwen36" } })
    expect(config.localModel).toEqual({ providerID: "local", modelID: "qwen36" })
  })

  test("undefined si viene mal formado", () => {
    expect(parseConfig({ localModel: { providerID: "local" } }).localModel).toBeUndefined()
  })
})
```

- [ ] **Step 3: Run tests**

Run: `cd plugins/ip-rotate && bun test test/config.test.ts`
Expected: PASS (3 tests). If `test/config.test.ts` didn't exist before, this is its first run — verify it fails first without Step 1's changes if you're following strict TDD ordering (write test, see it fail on `toBeUndefined()`/`toEqual()` mismatch, then confirm Step 1 already applied makes it pass).

- [ ] **Step 4: Commit**

```bash
git add plugins/ip-rotate/src/config.ts plugins/ip-rotate/test/config.test.ts
git commit -m "feat(plugin): add optional localModel config for the fallback provider"
```

---

### Task 7: Zen-block global state (persisted)

**Files:**
- Modify: `plugins/ip-rotate/src/state.ts`
- Test: `plugins/ip-rotate/test/zen-block-state.test.ts`

**Interfaces:**
- Produces: `ZenModel = { providerID: string; modelID: string }`, `createZenBlockState(path: string): ZenBlockState` where `ZenBlockState = { isBlocked(): boolean; until(): number | undefined; block(untilMs: number): void; clear(): void; trackFallback(sessionID: string, previousModel: ZenModel): void; fallbackSessions(): Map<string, ZenModel> }`. Task 8 (index.ts) consumes this.

- [ ] **Step 1: Write the failing test**

```ts
// plugins/ip-rotate/test/zen-block-state.test.ts
import { describe, expect, test } from "bun:test"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createZenBlockState } from "../src/state"

function tmpPath() {
  return join(mkdtempSync(join(tmpdir(), "ip-rotate-state-")), "zen-block.json")
}

describe("createZenBlockState", () => {
  test("no bloqueado por defecto", () => {
    const state = createZenBlockState(tmpPath())
    expect(state.isBlocked()).toBe(false)
  })

  test("bloqueado hasta una hora futura", () => {
    const state = createZenBlockState(tmpPath())
    state.block(Date.now() + 60000)
    expect(state.isBlocked()).toBe(true)
  })

  test("no extiende el bloqueo si la nueva hora es anterior a la ya guardada", () => {
    const path = tmpPath()
    const state = createZenBlockState(path)
    const later = Date.now() + 120000
    state.block(later)
    state.block(Date.now() + 60000)
    expect(state.until()).toBe(later)
  })

  test("clear limpia bloqueo y sesiones en fallback", () => {
    const state = createZenBlockState(tmpPath())
    state.block(Date.now() + 60000)
    state.trackFallback("s1", { providerID: "local", modelID: "qwen36" })
    state.clear()
    expect(state.isBlocked()).toBe(false)
    expect(state.fallbackSessions().size).toBe(0)
  })

  test("persiste y se recarga desde disco", () => {
    const path = tmpPath()
    const until = Date.now() + 60000
    createZenBlockState(path).block(until)
    const reloaded = createZenBlockState(path)
    expect(reloaded.until()).toBe(until)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/ip-rotate && bun test test/zen-block-state.test.ts`
Expected: FAIL — `createZenBlockState` not exported.

- [ ] **Step 3: Implement in `src/state.ts`**

Add to `plugins/ip-rotate/src/state.ts`:

```ts
import { readFileSync, writeFileSync } from "node:fs"

export type ZenModel = { providerID: string; modelID: string }

export type ZenBlockState = {
  isBlocked(): boolean
  until(): number | undefined
  block(untilMs: number): void
  clear(): void
  trackFallback(sessionID: string, previousModel: ZenModel): void
  fallbackSessions(): Map<string, ZenModel>
}

type ZenBlockFile = { until?: number }

export function createZenBlockState(path: string): ZenBlockState {
  let until: number | undefined
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as ZenBlockFile
    if (typeof parsed.until === "number") until = parsed.until
  } catch {
    until = undefined
  }
  const fallbackSessions = new Map<string, ZenModel>()

  const persist = () => {
    try {
      writeFileSync(path, JSON.stringify({ until } satisfies ZenBlockFile))
    } catch {
      // Persistencia best-effort: si falla, el bloqueo sigue activo en memoria para este proceso.
    }
  }

  return {
    isBlocked: () => until !== undefined && Date.now() < until,
    until: () => until,
    block: (untilMs) => {
      if (until !== undefined && until >= untilMs) return
      until = untilMs
      persist()
    },
    clear: () => {
      until = undefined
      fallbackSessions.clear()
      persist()
    },
    trackFallback: (sessionID, previousModel) => fallbackSessions.set(sessionID, previousModel),
    fallbackSessions: () => fallbackSessions,
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/ip-rotate && bun test test/zen-block-state.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Add `zenBlockPath` to config**

In `plugins/ip-rotate/src/config.ts`, add to `Config`: `zenBlockPath: string`. Add to `DEFAULTS`: `zenBlockPath: join(homedir(), ".opencode-tor", "zen-block.json"),` (reuses the `homedir`/`join` imports added in Task 2). Add to `parseConfig`'s return: `zenBlockPath: str("zenBlockPath") ?? DEFAULTS.zenBlockPath,`.

- [ ] **Step 6: Commit**

```bash
git add plugins/ip-rotate/src/state.ts plugins/ip-rotate/src/config.ts plugins/ip-rotate/test/zen-block-state.test.ts
git commit -m "feat(plugin): add persisted global zen-block state"
```

---

### Task 8: Detector extracts the exact retry-after from Zen's error

**Files:**
- Modify: `plugins/ip-rotate/src/detector.ts`
- Test: `plugins/ip-rotate/test/detector.test.ts`

**Interfaces:**
- Produces: `extractRetryAfterMs(event: unknown): number | undefined`. Task 10 (index.ts) consumes this.

- [ ] **Step 1: Write the failing test**

Add to `plugins/ip-rotate/test/detector.test.ts`:

```ts
import { extractRetryAfterMs } from "../src/detector"

describe("extractRetryAfterMs", () => {
  test("lee retry-after-ms si está presente", () => {
    const event = {
      type: "session.error",
      properties: {
        error: { data: { responseHeaders: { "retry-after-ms": "5000" } } },
      },
    }
    expect(extractRetryAfterMs(event)).toBe(5000)
  })

  test("cae a retry-after en segundos si no hay -ms", () => {
    const event = {
      type: "session.error",
      properties: { error: { data: { responseHeaders: { "retry-after": "10" } } } },
    }
    expect(extractRetryAfterMs(event)).toBe(10000)
  })

  test("undefined sin cabeceras", () => {
    const event = { type: "session.error", properties: { error: { data: {} } } }
    expect(extractRetryAfterMs(event)).toBeUndefined()
  })

  test("undefined para otros tipos de evento", () => {
    expect(extractRetryAfterMs({ type: "session.status", properties: {} })).toBeUndefined()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/ip-rotate && bun test test/detector.test.ts`
Expected: FAIL — `extractRetryAfterMs` not exported.

- [ ] **Step 3: Implement in `src/detector.ts`**

Add (the file already has `asRecord` and `isString` defined — reuse them):

```ts
export function extractRetryAfterMs(event: unknown): number | undefined {
  const record = asRecord(event)
  if (!record || record.type !== "session.error") return undefined
  const props = asRecord(record.properties)
  const error = asRecord(props?.error)
  const data = asRecord(error?.data)
  const headers = asRecord(data?.responseHeaders)
  if (!headers) return undefined

  const ms = headers["retry-after-ms"]
  if (isString(ms)) {
    const parsed = Number.parseFloat(ms)
    if (!Number.isNaN(parsed)) return parsed
  }
  const seconds = headers["retry-after"]
  if (isString(seconds)) {
    const parsed = Number.parseFloat(seconds)
    if (!Number.isNaN(parsed)) return parsed * 1000
  }
  return undefined
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/ip-rotate && bun test test/detector.test.ts`
Expected: PASS (all existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add plugins/ip-rotate/src/detector.ts plugins/ip-rotate/test/detector.test.ts
git commit -m "feat(plugin): extract exact retry-after from Zen's rate-limit error"
```

---

### Task 9: Resumer accepts a model override

**Files:**
- Modify: `plugins/ip-rotate/src/resumer.ts`
- Test: `plugins/ip-rotate/test/resumer.test.ts` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Resumer.resume(sessionID: string, model?: { providerID: string; modelID: string }): Promise<void>`. Task 10 (index.ts) consumes this new signature.

- [ ] **Step 1: Write the failing test**

```ts
// plugins/ip-rotate/test/resumer.test.ts
import { describe, expect, test } from "bun:test"
import { createResumer } from "../src/resumer"
import { parseConfig } from "../src/config"

function mockClient(prompts: Array<Record<string, unknown>>) {
  return {
    session: {
      messages: async () => ({
        data: [{ info: { role: "user" }, parts: [{ type: "text", text: "hola" }] }],
      }),
      prompt: async (input: Record<string, unknown>) => {
        prompts.push(input)
        return { data: {} }
      },
    },
    // oxlint-disable-next-line typescript-eslint/no-explicit-any
  } as any
}

describe("RepromptResumer with model override", () => {
  test("incluye el modelo en el body cuando se pasa", async () => {
    const prompts: Array<Record<string, unknown>> = []
    const resumer = createResumer(parseConfig({ resume: "reprompt" }), mockClient(prompts))

    await resumer.resume("s1", { providerID: "local", modelID: "qwen36" })

    expect(prompts).toHaveLength(1)
    expect(prompts[0].body).toEqual({
      parts: [{ type: "text", text: "hola" }],
      model: { providerID: "local", modelID: "qwen36" },
    })
  })

  test("no incluye model cuando no se pasa (compatibilidad)", async () => {
    const prompts: Array<Record<string, unknown>> = []
    const resumer = createResumer(parseConfig({ resume: "reprompt" }), mockClient(prompts))

    await resumer.resume("s1")

    expect(prompts[0].body).toEqual({ parts: [{ type: "text", text: "hola" }] })
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/ip-rotate && bun test test/resumer.test.ts`
Expected: FAIL — `resume` doesn't accept a second argument / body shape mismatch.

- [ ] **Step 3: Update `src/resumer.ts`**

Change the interface:

```ts
export interface Resumer {
  resume(sessionID: string, model?: { providerID: string; modelID: string }): Promise<void>
}
```

Update `NoopResumer`:

```ts
class NoopResumer implements Resumer {
  async resume(): Promise<void> {
    // El retry interno de processor.ts (429 reintentables) reintentará solo.
  }
}
```

Update `RepromptResumer.resume`:

```ts
  async resume(sessionID: string, model?: { providerID: string; modelID: string }): Promise<void> {
    try {
      const response = await this.client.session.messages({ path: { id: sessionID } })
      const messages = response.data ?? response
      const lastUser = [...messages].reverse().find((m) => m.info.role === "user")
      if (!lastUser) {
        console.log(`[ip-rotate] sesión ${sessionID} sin mensajes de usuario: no reanudo`)
        return
      }

      const parts = lastUser.parts
        .filter(isTextPart)
        .map((part) => ({ type: "text" as const, text: part.text }))

      if (parts.length === 0) {
        console.log(`[ip-rotate] último mensaje de usuario de ${sessionID} sin texto: no reanudo`)
        return
      }

      await this.client.session.prompt({
        path: { id: sessionID },
        body: model ? { parts, model } : { parts },
      })
      console.log(
        model
          ? `[ip-rotate] sesión ${sessionID} reanudada con modelo ${model.providerID}/${model.modelID}`
          : `[ip-rotate] sesión ${sessionID} reanudada con el último prompt`,
      )
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      console.log(`[ip-rotate] no pude reanudar sesión ${sessionID}: ${message}`)
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/ip-rotate && bun test test/resumer.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/ip-rotate/src/resumer.ts plugins/ip-rotate/test/resumer.test.ts
git commit -m "feat(plugin): let the resumer reprompt with a different model"
```

---

### Task 10: Wire the fallback flow into `index.ts`

**Files:**
- Modify: `plugins/ip-rotate/index.ts`
- Modify: `plugins/ip-rotate/test/flow.test.ts`

**Interfaces:**
- Consumes: `extractRetryAfterMs` (Task 8), `createZenBlockState` (Task 7), `Resumer.resume(sessionID, model?)` (Task 9), `Config.localModel`/`Config.probeModel` (Task 6 / existing).

- [ ] **Step 1: Write the failing tests**

Add to `plugins/ip-rotate/test/flow.test.ts` (extend the existing `mockClient` to record `prompt` calls, and add new test cases):

```ts
function mockClientWithPrompts(prompts: Array<Record<string, unknown>>) {
  const app = { log: async () => ({ data: undefined }) }
  const session = {
    messages: async () => ({
      data: [{ info: { role: "user" }, parts: [{ type: "text", text: "hola" }] }],
    }),
    prompt: async (input: Record<string, unknown>) => {
      prompts.push(input)
      return { data: {} }
    },
  }
  return { app, session } as unknown as Parameters<typeof server>[0]["client"]
}

describe("ip-rotate local fallback", () => {
  test("cae a local tras agotar rotaciones, sin IP viable", async () => {
    const prompts: Array<Record<string, unknown>> = []
    const client = mockClientWithPrompts(prompts)
    const rotator = { currentIp: async () => "1.2.3.4", rotateUntilClean: async () => undefined }
    const hooks = await server(client, {
      cooldownMs: 0,
      maxRotationsPerSession: 1,
      resume: "reprompt",
      localModel: { providerID: "local", modelID: "qwen36" },
      zenBlockPath: `/tmp/ip-rotate-test-zen-block-${Date.now()}-a.json`,
      rotator,
    })

    await hooks.event!(errorEvent("s1"))

    expect(prompts).toHaveLength(1)
    expect(prompts[0].body).toEqual({
      parts: [{ type: "text", text: "hola" }],
      model: { providerID: "local", modelID: "qwen36" },
    })
  })

  test("sin localModel configurado, no hay fallback (comportamiento actual)", async () => {
    const prompts: Array<Record<string, unknown>> = []
    const client = mockClientWithPrompts(prompts)
    const rotator = { currentIp: async () => "1.2.3.4", rotateUntilClean: async () => undefined }
    const hooks = await server(client, {
      cooldownMs: 0,
      maxRotationsPerSession: 1,
      zenBlockPath: `/tmp/ip-rotate-test-zen-block-${Date.now()}-b.json`,
      rotator,
    })

    await hooks.event!(errorEvent("s1"))

    expect(prompts).toHaveLength(0)
  })

  test("sesión nueva durante bloqueo global va directa a local, sin rotar", async () => {
    let rotations = 0
    const prompts: Array<Record<string, unknown>> = []
    const client = mockClientWithPrompts(prompts)
    const rotator = {
      currentIp: async () => "1.2.3.4",
      rotateUntilClean: async () => {
        rotations++
        return undefined
      },
    }
    const zenBlockPath = `/tmp/ip-rotate-test-zen-block-${Date.now()}-c.json`
    const hooks = await server(client, {
      cooldownMs: 0,
      maxRotationsPerSession: 1,
      localModel: { providerID: "local", modelID: "qwen36" },
      zenBlockPath,
      rotator,
    })

    await hooks.event!(errorEvent("s1"))
    await hooks.event!(errorEvent("s2"))

    expect(rotations).toBe(1) // solo la primera sesión intentó rotar
    expect(prompts).toHaveLength(2) // ambas cayeron a local
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/ip-rotate && bun test test/flow.test.ts`
Expected: FAIL — `localModel`/`zenBlockPath` options ignored, no fallback triggered, prompts stay empty.

- [ ] **Step 3: Rewrite `index.ts`**

Replace the full file:

```ts
import type { Hooks, PluginInput, PluginOptions } from "@opencode-ai/plugin"
import { parseConfig } from "./src/config"
import { extractRetryAfterMs, isIpBlocked } from "./src/detector"
import type { Rotator } from "./src/rotator"
import { createRotator } from "./src/rotator"
import { createResumer } from "./src/resumer"
import { createState, createZenBlockState } from "./src/state"

// Seam de test: permite inyectar un Rotator (p. ej. stub) sin tocar detector/resumer.
export type IpRotateOptions = PluginOptions & { rotator?: Rotator }

const DEFAULT_RETRY_AFTER_MS = 24 * 60 * 60 * 1000 // ventana diaria de Zen si el header no viene

export const server = async (input: PluginInput, options?: IpRotateOptions): Promise<Hooks> => {
  const config = parseConfig(options)
  const state = createState()
  const zenBlock = createZenBlockState(config.zenBlockPath)
  const rotator = options?.rotator ?? createRotator(config)
  const resumer = createResumer(config, input.client)

  console.log("[ip-rotate] plugin loaded")

  let revertTimer: ReturnType<typeof setTimeout> | undefined

  const scheduleRevert = () => {
    const until = zenBlock.until()
    if (until === undefined) return
    if (revertTimer) clearTimeout(revertTimer)
    revertTimer = setTimeout(async () => {
      revertTimer = undefined
      const sessions = new Map(zenBlock.fallbackSessions())
      zenBlock.clear()
      for (const [sessionID, model] of sessions) {
        console.log(`[ip-rotate] bloqueo de Zen expirado, devolviendo sesión ${sessionID} a ${model.providerID}/${model.modelID}`)
        await resumer.resume(sessionID, model)
      }
    }, Math.max(0, until - Date.now()))
  }

  scheduleRevert() // rehidrata el timer si el proceso arranca con un bloqueo aún vigente

  const fallbackToLocal = async (sessionID: string, event: unknown): Promise<boolean> => {
    if (!config.localModel) return false
    const retryAfterMs = extractRetryAfterMs(event) ?? DEFAULT_RETRY_AFTER_MS
    const until = Date.now() + retryAfterMs
    zenBlock.block(until)
    zenBlock.trackFallback(sessionID, { providerID: "opencode", modelID: config.probeModel })
    scheduleRevert()
    console.log(`[ip-rotate] sin IPs viables: sesión ${sessionID} cae a local hasta ${new Date(until).toISOString()}`)
    await resumer.resume(sessionID, config.localModel)
    return true
  }

  return {
    dispose: async () => {},
    event: async ({ event }) => {
      const properties = (event.properties ?? {}) as Record<string, unknown>
      const sessionID = typeof properties.sessionID === "string" ? properties.sessionID : undefined
      if (!sessionID) return

      // Tras recuperación (idle) se resetea el contador de rotaciones de la sesión.
      if (isIdle(event)) {
        if (state.rotationsBySession.delete(sessionID)) {
          console.log(`[ip-rotate] sesión ${sessionID} idle tras recuperación: contador reseteado`)
        }
        return
      }

      if (!isIpBlocked(event, config.errorPatterns)) return

      if (zenBlock.isBlocked()) {
        console.log(`[ip-rotate] Zen ya sabido bloqueado, sesión ${sessionID} directa a fallback local`)
        await fallbackToLocal(sessionID, event)
        return
      }

      const now = Date.now()
      if (now - state.lastRotationAt < config.cooldownMs) {
        console.log(`[ip-rotate] rate limit en sesión ${sessionID} ignorado (cooldown activo)`)
        return
      }

      const used = state.rotationsBySession.get(sessionID) ?? 0
      if (used >= config.maxRotationsPerSession) {
        console.log(`[ip-rotate] rate limit en sesión ${sessionID}: rotaciones agotadas`)
        await fallbackToLocal(sessionID, event)
        return
      }

      state.rotationsBySession.set(sessionID, used + 1)
      state.lastRotationAt = now

      const previous = state.lastKnownIp
      console.log(`[ip-rotate] rate limit detectado en sesión ${sessionID}, rotando IP...`)
      const next = rotator.rotateUntilClean ? await rotator.rotateUntilClean() : await rotator.rotate()

      if (next === undefined) {
        console.log(`[ip-rotate] rotación fallida en sesión ${sessionID}`)
        if (used + 1 >= config.maxRotationsPerSession) {
          await fallbackToLocal(sessionID, event)
        }
        return
      }

      state.lastKnownIp = next
      console.log(`[ip-rotate] IP rotada: ${previous ?? "desconocida"} -> ${next}`)
      console.log("[ip-rotate] IP rotada, reanudando sesión")
      await resumer.resume(sessionID)
      try {
        await input.client.app.log({
          body: { service: "ip-rotate", level: "info", message: `IP rotada, reanudando sesión ${sessionID}` },
        })
      } catch {
        // La notificación es best-effort; nunca romper la sesión.
      }
    },
  }
}

function isIdle(event: unknown): boolean {
  if (!event || typeof event !== "object") return false
  const e = event as { type?: string; properties?: Record<string, unknown> }
  if (e.type === "session.idle") return true
  if (e.type !== "session.status") return false
  const status = e.properties?.status
  return isRecord(status) && status.type === "idle"
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd plugins/ip-rotate && bun test`
Expected: all tests pass (existing flow tests still hold — no `localModel` configured in those, so `fallbackToLocal` is a no-op returning `false`, unchanged behavior).

- [ ] **Step 5: Commit**

```bash
git add plugins/ip-rotate/index.ts plugins/ip-rotate/test/flow.test.ts
git commit -m "feat(plugin): fall back to local model when no IP is viable, revert automatically when Zen resets"
```

---

### Task 11: Wire `localModel` into the installer's conditional local-provider block

**Files:**
- Modify: `plugins/ip-rotate/build-install.sh`

- [ ] **Step 1: Update the opencode.json generation**

Replace the block from `# --- 4. opencode.json ---` through the `cat > "$INSTALL_DIR/opencode.json"` heredoc with:

```bash
# --- 4. opencode.json ---
# Provider local opcional: si hay un llama.cpp/OpenAI-compatible sirviendo en
# 127.0.0.1:8080 (o el modelo GGUF descargado), se registra `local/qwen36` y se
# pasa `localModel` al plugin para el fallback automático de ip-rotate.
# Condicional para que el instalador siga siendo genérico en otras máquinas.
LOCAL_PROVIDER=""
PLUGIN_OPTIONS="{ \"controlPassword\": \"$CONTROL_PASSWORD\" }"
if curl -s --max-time 2 http://127.0.0.1:8080/health >/dev/null 2>&1 || [ -f "$HOME/llamacpp/models/qwen3.6/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf" ]; then
  LOCAL_PROVIDER=',
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local Qwen3.6",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": { "qwen36": { "name": "Qwen3.6 35B-A3B (local)", "tool_call": true } }
    }
  }'
  PLUGIN_OPTIONS="{ \"controlPassword\": \"$CONTROL_PASSWORD\", \"localModel\": { \"providerID\": \"local\", \"modelID\": \"qwen36\" } }"
fi
cat > "$INSTALL_DIR/opencode.json" <<JSON
{
  "plugin": [["file://$INSTALL_DIR/plugins/ip-rotate", $PLUGIN_OPTIONS]]$LOCAL_PROVIDER
}
JSON
```

- [ ] **Step 2: Syntax check and regenerate**

```bash
cd plugins/ip-rotate
bash -n build-install.sh
./build-install.sh
bash -n install-opencode-tor.sh
```

Expected: clean on both.

- [ ] **Step 3: Run the full shell test suite**

```bash
cd plugins/ip-rotate
test/generator.test.sh
test/wrapper.test.sh
test/uninstall.test.sh
```

Expected: all three print `PASS`.

- [ ] **Step 4: Commit**

```bash
git add plugins/ip-rotate/build-install.sh plugins/ip-rotate/install-opencode-tor.sh
git commit -m "feat(plugin): pass localModel plugin option when the installer detects the local llama.cpp provider"
```

---

### Task 12: README and full verification pass

**Files:**
- Modify: `plugins/ip-rotate/README.md`

- [ ] **Step 1: Document the new options and behavior**

Add a section to `plugins/ip-rotate/README.md` (after the existing options table/description) covering:
- `exitPoolPath` / `zenBlockPath` config options and their defaults.
- `localModel` config option, and that the installer sets it automatically when it detects the local llama.cpp provider (cross-reference `docs/superpowers/specs/2026-08-15-local-model-qwen36.md`).
- The exit-sweep daemon: what it does, that it's launched by the wrapper detached, its budget flags (`--budget-minutes`, `--budget-count`), and that `EXIT_SWEEP_DAEMON_CMD` can override the launch command.
- The local-fallback flow and automatic revert, referencing `docs/superpowers/specs/2026-08-15-exit-sweep-and-local-fallback.md` for the full design.

- [ ] **Step 2: Run the complete test suite**

```bash
cd plugins/ip-rotate
bun test
test/generator.test.sh
test/wrapper.test.sh
test/uninstall.test.sh
python3 test/sweep-budget.test.py -v
bash -n opencode-tor build-install.sh install-opencode-tor.sh
```

Expected: all green, no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add plugins/ip-rotate/README.md
git commit -m "docs(plugin): document exit-sweep daemon and local-model fallback"
```

---

## Self-Review Notes

- **Spec coverage:** Objetivos 1-2 (barrido continuo, prioridad) → Tasks 1-5. Objetivo 3 (rotator prefiere exit conocido) → Task 2. Objetivos 4-5 (fallback local + revert automático con hora exacta) → Tasks 6-10. Instalador auto-configurando `localModel` → Task 11. "Nunca romper la sesión" → every fallback path in `rotator.ts`/`index.ts` degrades silently (verified: `rotateToKnownGood` returns `undefined` on any failure, `fallbackToLocal` returns `false` without `localModel`, `resumer.resume` always catches).
- **Type consistency checked:** `Rotator.rotateToKnownGood?(excludeIp?: string)` (Task 2) matches the call site in `rotateUntilClean` (same task) and the test (Task 2). `ZenBlockState` methods (Task 7) match their usage in `index.ts` (Task 10): `isBlocked()`, `until()`, `block()`, `clear()`, `trackFallback()`, `fallbackSessions()`. `Resumer.resume(sessionID, model?)` (Task 9) matches all call sites added in Task 10 (`fallbackToLocal`, `scheduleRevert`'s timer callback) and the existing no-arg call (rotation-success path) still compiles since `model` is optional.
- **No placeholders:** every step has literal file content, no "TBD" or "add error handling" left unstated — errors are handled explicitly (silent degrade, documented per-task).
