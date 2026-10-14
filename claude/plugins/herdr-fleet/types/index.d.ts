export type FleetTab = 'tasks' | 'prs' | 'done'
export type FleetTaskRow = {
  id: string
  status: string
  agent: string
  phase: string
  head: string
  pr: string
  prNumber: number | null
  branch: string | null
  verdict: string
  isDirty: boolean
  isTerminal: boolean
}
export type FleetPrRow = {
  number: number
  title: string
  isDraft: boolean
  head: string
  ci: 'pass' | 'fail' | 'pending' | 'none'
  review: string
  task: string | null
}
export type FleetLease =
  | { kind: 'none' }
  | { kind: 'ambiguous'; slugs: string[] }
  | { kind: 'held'; slug: string }
export type FleetPart<T> = { slug: string | null; rows: T[] }
export type FleetSnapshot = {
  lease: FleetLease
  repoRoot: string | null
  live: FleetPart<FleetTaskRow>
  archived: FleetPart<FleetTaskRow>
  prs: FleetPart<FleetPrRow> | null
  ghError: string | null
  prsAt: number | null
  readAt: number | null
}

declare module 'claude-code' {
  interface PluginState {
    'herdr-fleet': {
      tab: FleetTab
      snapshot: FleetSnapshot
      generation: number
    }
  }
}
