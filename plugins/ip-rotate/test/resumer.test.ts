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
