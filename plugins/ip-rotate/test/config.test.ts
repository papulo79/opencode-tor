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
