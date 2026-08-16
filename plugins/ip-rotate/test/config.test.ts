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

describe("parseConfig terminalErrorPatterns", () => {
  test("default: solo los patrones terminales del límite gratuito", () => {
    expect(parseConfig({}).terminalErrorPatterns).toEqual(["free limit reached", "free usage exceeded"])
  })

  test("override por opciones", () => {
    const config = parseConfig({ terminalErrorPatterns: ["custom terminal"] })
    expect(config.terminalErrorPatterns).toEqual(["custom terminal"])
  })

  test("cae al default si el override viene vacío", () => {
    expect(parseConfig({ terminalErrorPatterns: [] }).terminalErrorPatterns).toEqual([
      "free limit reached",
      "free usage exceeded",
    ])
  })
})
