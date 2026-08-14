export type State = {
  lastRotationAt: number
  rotationsBySession: Map<string, number>
  lastKnownIp: string | undefined
}

export function createState(): State {
  return {
    lastRotationAt: 0,
    rotationsBySession: new Map(),
    lastKnownIp: undefined,
  }
}
