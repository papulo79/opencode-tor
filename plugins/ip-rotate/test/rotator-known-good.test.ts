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
})
