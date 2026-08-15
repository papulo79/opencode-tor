/** @jsxImportSource @opentui/solid */
import { TextAttributes } from "@opentui/core"
import type { TuiPlugin, TuiPluginModule } from "@opencode-ai/plugin/tui"

const art = [
  "█▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█    ▀▀▀▀ █▀▀█ █▀▀█",
  "█  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀    ██   █  █ █  █ █▀▀▄",
  "▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀  ▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀    ██   ▀▀▀▄ ▀▀▀▀ █▀▀▄",
]

const tui: TuiPlugin = async (api) => {
  api.slots.register({
    slots: {
      home_logo(ctx) {
        const { text, textMuted } = ctx.theme.current
        return (
          <box flexDirection="column">
            <text fg={textMuted}>{art[0]}</text>
            <text fg={text} attributes={TextAttributes.BOLD}>
              {art[1]}
            </text>
            <text fg={textMuted}>{art[2]}</text>
          </box>
        )
      },
    },
  })
}

const plugin: TuiPluginModule & { id: string } = {
  id: "opencode-tor.logo",
  tui,
}

export default plugin
