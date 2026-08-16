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
