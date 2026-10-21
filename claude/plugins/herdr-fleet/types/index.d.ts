export type FleetTab = 'tasks' | 'prs' | 'done'
export type FleetTaskRow = {
  id: string
  status: string
  title: string
  live: { agent: string; state: string; since: number | null }
  head: string
  pr: string
  prNumber: number | null
  branch: string | null
  verdict: string
  isDirty: boolean
  isTerminal: boolean
  owner: string | null
  gateSince: number | null
  reviewLaunch: string | null
  since: number | null
  reviewHead: string | null
  review: string | null
  phase: string | null
  ship: { verdict: string | null; head: string | null } | null
}
export type FleetGroup =
  | 'Your call'
  | 'Needs director'
  | 'Waiting on reviewers'
  | 'Agents working'
  | 'Parked'
export type FleetDeadline = {
  launch: string
  state: 'running' | 'overdue' | 'expired' | 'unknown'
  remaining: number | null
  deadlineSecs: number
  hardSecs: number
}
export type FleetPrRow = {
  number: number
  title: string
  isDraft: boolean
  head: string
  ci: 'pass' | 'fail' | 'pending' | 'none'
  review: string
  task: string | null
  branch: string | null
  headOid: string | null
  reviewAt: number | null
  human: 'none' | 'changes' | 'required' | 'approved' | 'approved-old'
}
export type FleetLease =
  | { kind: 'none' }
  | { kind: 'ambiguous'; slugs: string[] }
  | { kind: 'held'; slug: string; fence: number | null }
export type FleetPart<T> = { slug: string | null; rows: T[] }
export type FleetSnapshot = {
  lease: FleetLease
  repoRoot: string | null
  live: FleetPart<FleetTaskRow>
  archived: FleetPart<FleetTaskRow>
  prs: (FleetPart<FleetPrRow> & { at: number }) | null
  ghError: { slug: string; reason: string } | null
  deadlines: { slug: string; at: number; rows: Record<string, FleetDeadline> } | null
  readError: string | null
  readAt: number | null
}

declare module 'claude-code' {
  interface PluginState {
    'herdr-fleet': {
      tab: FleetTab
      snapshot: FleetSnapshot
      generation: number
      opened: boolean
    }
  }
}
