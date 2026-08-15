import { afterAll, describe, expect, test } from "bun:test"
import { parseConfig } from "../src/config"
import { probeModel } from "../src/rotator"

const LIMITED = JSON.stringify({
  type: "error",
  error: { type: "FreeUsageLimitError", message: "Rate limit exceeded. Please try again later." },
})
const CLEAN = JSON.stringify({
  id: "x",
  object: "chat.completion",
  choices: [{ message: { role: "assistant", content: "hola" } }],
})

function configFor(url: string) {
  // proxyUrl vacío: conexión directa al servidor de test (sin Tor).
  return parseConfig({ probeUrl: url, proxyUrl: "" })
}

describe("probeModel", () => {
  const server = Bun.serve({
    port: 0,
    fetch(req) {
      const path = new URL(req.url).pathname
      if (path === "/limited") return new Response(LIMITED, { status: 200 })
      if (path === "/clean") return new Response(CLEAN, { status: 200 })
      return new Response("not found", { status: 404 })
    },
  })
  afterAll(() => server.stop(true))
  const base = `http://127.0.0.1:${server.port}`

  test("devuelve false cuando el exit está limitado", async () => {
    expect(await probeModel(configFor(`${base}/limited`))).toBe(false)
  })

  test("devuelve true cuando el modelo responde", async () => {
    expect(await probeModel(configFor(`${base}/clean`))).toBe(true)
  })

  test("devuelve false ante un endpoint caído", async () => {
    expect(await probeModel(configFor(`http://127.0.0.1:1/nope`))).toBe(false)
  })
})
