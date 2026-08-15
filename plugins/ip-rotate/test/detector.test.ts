import { describe, expect, test } from "bun:test"
import { isIpBlocked } from "../src/detector"

const PATTERNS = ["429", "rate limit", "too many requests", "free limit reached", "overloaded"]

function errorEvent(message: string) {
  return { type: "session.error", properties: { sessionID: "s1", error: { type: "unknown", message } } }
}

// Forma real que publica opencode: NamedError { name, data: { message, responseBody? } }
function namedErrorEvent(message: string, responseBody?: string) {
  return {
    type: "session.error",
    properties: { sessionID: "s1", error: { name: "APIError", data: { message, responseBody } } },
  }
}

function retryEvent(message: string) {
  return { type: "session.status", properties: { sessionID: "s1", status: { type: "retry", attempt: 1, message, next: 30000 } } }
}

describe("isIpBlocked", () => {
  test("matches a 429 session.error", () => {
    expect(isIpBlocked(errorEvent("provider returned 429 Too Many Requests"), PATTERNS)).toBe(true)
  })

  test("matches 'free limit reached' case-insensitive", () => {
    expect(isIpBlocked(errorEvent("Free limit reached. Upgrade to continue."), PATTERNS)).toBe(true)
  })

  test("matches a retry event with 'rate limit'", () => {
    expect(isIpBlocked(retryEvent("Rate limit exceeded for IP"), PATTERNS)).toBe(true)
  })

  test("does NOT match a 401 auth error", () => {
    expect(isIpBlocked(errorEvent("401 Unauthorized: invalid api key"), PATTERNS)).toBe(false)
  })

  test("does NOT match non-error events", () => {
    expect(isIpBlocked({ type: "session.status", properties: { sessionID: "s1", status: { type: "busy" } } }, PATTERNS)).toBe(false)
  })

  test("does NOT match idle status", () => {
    expect(isIpBlocked({ type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } }, PATTERNS)).toBe(false)
  })

  test("matches a NamedError session.error (forma real de opencode)", () => {
    expect(isIpBlocked(namedErrorEvent("AI_APICallError: Rate limit exceeded. Please try again later."), PATTERNS)).toBe(true)
  })

  test("matches a 429 inside the NamedError responseBody", () => {
    expect(isIpBlocked(namedErrorEvent("Internal Server Error", '{"error":"429 Too Many Requests"}'), PATTERNS)).toBe(true)
  })

  test("does NOT match a NamedError 401 auth error", () => {
    expect(isIpBlocked(namedErrorEvent("AI_APICallError: 401 Unauthorized"), PATTERNS)).toBe(false)
  })

  test("is case-insensitive", () => {
    expect(isIpBlocked(errorEvent("RATE LIMIT"), PATTERNS)).toBe(true)
  })

  test("handles malformed input without throwing", () => {
    expect(isIpBlocked(null, PATTERNS)).toBe(false)
    expect(isIpBlocked(undefined, PATTERNS)).toBe(false)
    expect(isIpBlocked("nope", PATTERNS)).toBe(false)
    expect(isIpBlocked({ type: "session.error" }, PATTERNS)).toBe(false)
  })
})
