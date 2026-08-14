import { describe, expect, test } from "bun:test"
import { server } from "../index"

type Event = { event: { id: string; type: string; properties: Record<string, unknown> } }

const errorEvent = (sessionID: string, message = "429 Too Many Requests"): Event => ({
  event: { id: "1", type: "session.error", properties: { sessionID, error: { type: "unknown", message } } },
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
