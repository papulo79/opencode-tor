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
    // rotateToKnownGood espera 10s reales antes de re-verificar la IP.
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
  }, 15000)

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

  test("resetea ExitNodes/StrictNodes antes de caer a rotación a ciegas si el exit conocido ya no sirve", async () => {
    const commands: string[] = []
    const control = fakeControlServer((line) => commands.push(line))

    // IPs únicas por llamada: 1ª = currentIp() inicial, 2ª = previous dentro de
    // rotateToKnownGood, 3ª = next dentro de rotateToKnownGood (distinta de las
    // anteriores para que rotateToKnownGood devuelva un exit "conocido" válido).
    let ipCalls = 0
    const ipServer = Bun.serve({
      port: 0,
      fetch() {
        ipCalls++
        return new Response(`${ipCalls}.${ipCalls}.${ipCalls}.${ipCalls}`)
      },
    })

    // El endpoint de prueba (probeUrl) siempre responde "limitado": fuerza a que
    // rotateUntilClean concluya que el exit conocido ya no sirve y caiga a ciegas.
    const probeServer = Bun.serve({
      port: 0,
      fetch() {
        return new Response("FreeUsageLimitError: rate limit")
      },
    })

    const dir = mkdtempSync(join(tmpdir(), "ip-rotate-"))
    const poolPath = join(dir, "exits-sweep.jsonl")
    writeFileSync(poolPath, JSON.stringify({ fp: "GOODFP", ip: "9.9.9.9", verdict: "ok", checked_at: 1 }) + "\n")

    const config = parseConfig({
      controlPort: control.port,
      verifyUrl: `http://127.0.0.1:${ipServer.port}`,
      probeUrl: `http://127.0.0.1:${probeServer.port}`,
      proxyUrl: "",
      exitPoolPath: poolPath,
      probeMaxAttempts: 0,
    })
    const rotator = createRotator(config)

    const result = await rotator.rotateUntilClean!()

    control.stop(true)
    ipServer.stop(true)
    probeServer.stop(true)

    expect(result).toBeUndefined()
    expect(commands.some((c) => c.includes("SETCONF ExitNodes=GOODFP StrictNodes=1"))).toBe(true)
    expect(commands.some((c) => c.includes("SETCONF ExitNodes= StrictNodes=0"))).toBe(true)
  }, 15000)
})
