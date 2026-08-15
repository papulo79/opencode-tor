import { describe, expect, test } from "bun:test"
import { readFileSync, writeFileSync } from "node:fs"
import { server } from "../index"

type Event = { event: { id: string; type: string; properties: Record<string, unknown> } }

const errorEvent = (sessionID: string, message = "429 Too Many Requests"): Event => ({
  event: { id: "1", type: "session.error", properties: { sessionID, error: { type: "unknown", message } } },
})

// Evento terminal (límite gratuito diario agotado) con retry-after-ms explícito,
// para poder probar el timer de revert sin esperar 24h.
const terminalEvent = (sessionID: string, retryAfterMs: number): Event => ({
  event: {
    id: "4",
    type: "session.error",
    properties: {
      sessionID,
      error: {
        type: "unknown",
        message: "free usage exceeded",
        data: { responseHeaders: { "retry-after-ms": String(retryAfterMs) } },
      },
    },
  },
})

const idleEvent = (sessionID: string): Event => ({
  event: { id: "2", type: "session.status", properties: { sessionID, status: { type: "idle" } } },
})

// oxlint-disable-next-line typescript-eslint/no-explicit-any
function mockClient() {
  // Los métodos solo necesitan exponer `data`; el resto de la forma del SDK no se usa.
  const app = { log: async () => ({ data: undefined }) }
  const session = {
    messages: async () => ({ data: [] }),
    prompt: async () => ({ data: {} }),
  }
  // oxlint-disable-next-line typescript-eslint/no-unsafe-type-assertion
  return { app, session } as unknown as Parameters<typeof server>[0]["client"]
}

function countingRotator() {
  let rotations = 0
  return {
    rotator: {
      currentIp: async () => "1.2.3.4",
      rotate: async () => {
        rotations++
        await new Promise((resolve) => setTimeout(resolve, 50))
        return "5.6.7.8"
      },
    },
    count: () => rotations,
  }
}

describe("ip-rotate event flow", () => {
  test("rotates once for concurrent rate limits across sessions (global cooldown)", async () => {
    const { rotator, count } = countingRotator()
    const hooks = await server(mockClient(), { cooldownMs: 15000, rotator })

    // Both events fire while the first rotation is still in flight.
    const first = hooks.event!(errorEvent("s1"))
    await hooks.event!(errorEvent("s2"))
    await first

    expect(count()).toBe(1)
  })

  test("rotates again after cooldown expires", async () => {
    const { rotator, count } = countingRotator()
    const hooks = await server(mockClient(), { cooldownMs: 1, rotator })

    await hooks.event!(errorEvent("s1"))
    await new Promise((resolve) => setTimeout(resolve, 10))
    await hooks.event!(errorEvent("s1"))

    expect(count()).toBe(2)
  })

  test("resets per-session rotation counter on idle", async () => {
    let rotations = 0
    const rotator = {
      currentIp: async () => "1.2.3.4",
      rotate: async () => {
        rotations++
        return "5.6.7.8"
      },
    }
    const hooks = await server(mockClient(), { cooldownMs: 0, maxRotationsPerSession: 2, rotator })

    await hooks.event!(errorEvent("s1"))
    await hooks.event!(errorEvent("s1"))
    await hooks.event!(errorEvent("s1"))
    expect(rotations).toBe(2)

    await hooks.event!(idleEvent("s1"))
    await hooks.event!(errorEvent("s1"))
    expect(rotations).toBe(3)
  })

  test("per-session counters are independent", async () => {
    let rotations = 0
    const rotator = {
      currentIp: async () => "1.2.3.4",
      rotate: async () => {
        rotations++
        return "5.6.7.8"
      },
    }
    const hooks = await server(mockClient(), { cooldownMs: 0, maxRotationsPerSession: 1, rotator })

    await hooks.event!(errorEvent("a"))
    await hooks.event!(errorEvent("a"))
    await hooks.event!(errorEvent("b"))
    await hooks.event!(errorEvent("b"))

    expect(rotations).toBe(2)
  })

  test("401 does not rotate and session continues with original error", async () => {
    let rotations = 0
    const rotator = {
      currentIp: async () => "1.2.3.4",
      rotate: async () => {
        rotations++
        return "5.6.7.8"
      },
    }
    const hooks = await server(mockClient(), { cooldownMs: 0, rotator })

    await hooks.event!(errorEvent("s1", "401 Unauthorized: invalid api key"))
    expect(rotations).toBe(0)
  })
})

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
  // A diferencia de mockClient(), aquí sí se envuelve en { client } porque estos tests
  // ejercitan la cadena completa event -> resumer.resume -> client.session.prompt.
  return { client: { app, session } } as unknown as Parameters<typeof server>[0]
}

describe("ip-rotate local fallback", () => {
  test("cae a local tras agotar rotaciones, sin IP viable (error terminal)", async () => {
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

    await hooks.event!(errorEvent("s1", "free usage exceeded"))

    expect(prompts).toHaveLength(1)
    expect(prompts[0].body).toEqual({
      parts: [{ type: "text", text: "hola" }],
      model: { providerID: "local", modelID: "qwen36" },
    })
  })

  test("NO cae a local para errores transitorios (429/overloaded) aunque se agoten las rotaciones", async () => {
    const prompts: Array<Record<string, unknown>> = []
    const client = mockClientWithPrompts(prompts)
    const rotator = { currentIp: async () => "1.2.3.4", rotateUntilClean: async () => undefined }
    const hooks = await server(client, {
      cooldownMs: 0,
      maxRotationsPerSession: 1,
      resume: "reprompt",
      localModel: { providerID: "local", modelID: "qwen36" },
      zenBlockPath: `/tmp/ip-rotate-test-zen-block-${Date.now()}-transient.json`,
      rotator,
    })

    await hooks.event!(errorEvent("s1", "429 Too Many Requests"))
    expect(prompts).toHaveLength(0)

    await hooks.event!(errorEvent("s1", "servidor overloaded, reintenta"))
    expect(prompts).toHaveLength(0)
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

    await hooks.event!(errorEvent("s1", "free usage exceeded"))

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

    await hooks.event!(errorEvent("s1", "free usage exceeded"))
    await hooks.event!(errorEvent("s2", "free usage exceeded"))

    expect(rotations).toBe(1) // solo la primera sesión intentó rotar
    expect(prompts).toHaveLength(2) // ambas cayeron a local
  })

  test("con zenBlockPath ya bloqueado pero sin localModel, la sesión rota normalmente (no se descarta en silencio)", async () => {
    let rotations = 0
    const prompts: Array<Record<string, unknown>> = []
    const client = mockClientWithPrompts(prompts)
    const rotator = {
      currentIp: async () => "1.2.3.4",
      rotateUntilClean: async () => {
        rotations++
        return "5.6.7.8"
      },
    }
    const zenBlockPath = `/tmp/ip-rotate-test-zen-block-${Date.now()}-nolocal-blocked.json`
    writeFileSync(zenBlockPath, JSON.stringify({ until: Date.now() + 60000 }))

    // Sin localModel: el bloqueo global no debe silenciar la rotación normal.
    const hooks = await server(client, { cooldownMs: 0, maxRotationsPerSession: 1, zenBlockPath, rotator })

    await hooks.event!(errorEvent("s1", "429 Too Many Requests"))

    expect(rotations).toBe(1)
    expect(prompts).toHaveLength(1)
    expect(prompts[0].body).toEqual({ parts: [{ type: "text", text: "hola" }] })
  })

  test("no repite el fallback si la sesión ya está en local (evita loop)", async () => {
    const prompts: Array<Record<string, unknown>> = []
    const client = mockClientWithPrompts(prompts)
    const rotator = { currentIp: async () => "1.2.3.4", rotateUntilClean: async () => undefined }
    const zenBlockPath = `/tmp/ip-rotate-test-zen-block-${Date.now()}-dedup.json`
    const hooks = await server(client, {
      cooldownMs: 0,
      maxRotationsPerSession: 0,
      localModel: { providerID: "local", modelID: "qwen36" },
      zenBlockPath,
      rotator,
    })

    await hooks.event!(errorEvent("s1", "free usage exceeded"))
    expect(prompts).toHaveLength(1)

    await hooks.event!(errorEvent("s1", "free usage exceeded"))
    expect(prompts).toHaveLength(1) // segundo intento ignorado: ya está en fallback local
  })

  test("el timer de revert devuelve la sesión a Zen y limpia el bloqueo global", async () => {
    const prompts: Array<Record<string, unknown>> = []
    const client = mockClientWithPrompts(prompts)
    let rotationCalls = 0
    const rotator = {
      currentIp: async () => "1.2.3.4",
      rotateUntilClean: async () => {
        rotationCalls++
        // La primera llamada (s1) falla -> dispara fallback. La segunda (s2,
        // tras el revert) tiene éxito -> rotación normal, prueba de que el
        // bloqueo global ya no aplica.
        return rotationCalls === 1 ? undefined : "5.6.7.8"
      },
    }
    const zenBlockPath = `/tmp/ip-rotate-test-zen-block-${Date.now()}-revert.json`
    const hooks = await server(client, {
      cooldownMs: 0,
      maxRotationsPerSession: 1,
      resume: "reprompt",
      localModel: { providerID: "local", modelID: "qwen36" },
      zenBlockPath,
      rotator,
    })

    await hooks.event!(terminalEvent("s1", 30))
    expect(prompts).toHaveLength(1)
    expect(prompts[0].body).toEqual({
      parts: [{ type: "text", text: "hola" }],
      model: { providerID: "local", modelID: "qwen36" },
    })

    await new Promise((resolve) => setTimeout(resolve, 200))

    expect(prompts).toHaveLength(2)
    expect(prompts[1].body).toEqual({
      parts: [{ type: "text", text: "hola" }],
      model: { providerID: "opencode", modelID: "big-pickle" },
    })

    await hooks.event!(errorEvent("s2", "429 Too Many Requests"))

    expect(rotationCalls).toBe(2) // s2 pasó por rotación normal, no por fallback directo
    expect(prompts).toHaveLength(3)
    expect(prompts[2].body).toEqual({ parts: [{ type: "text", text: "hola" }] })
  })

  test("rehidrata el timer de revert al arrancar si el bloqueo seguía vigente en disco", async () => {
    const zenBlockPath = `/tmp/ip-rotate-test-zen-block-${Date.now()}-startup.json`
    writeFileSync(zenBlockPath, JSON.stringify({ until: Date.now() + 30 }))

    const prompts: Array<Record<string, unknown>> = []
    const client = mockClientWithPrompts(prompts)
    const rotator = { currentIp: async () => "1.2.3.4", rotateUntilClean: async () => "5.6.7.8" }

    // No se dispara ningún evento: el timer debe armarse solo al construir el
    // plugin (rehidratación desde zen-block.json).
    await server(client, {
      cooldownMs: 0,
      localModel: { providerID: "local", modelID: "qwen36" },
      zenBlockPath,
      rotator,
    })

    await new Promise((resolve) => setTimeout(resolve, 200))

    const raw = JSON.parse(readFileSync(zenBlockPath, "utf8")) as { until?: number }
    expect(raw.until).toBeUndefined()
  })
})
