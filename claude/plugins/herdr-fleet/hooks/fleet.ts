import type {
  FleetPrRow,
  FleetTaskRow,
} from '../types'

export const GH_ARGV = [
  'gh',
  'pr',
  'list',
  '--state',
  'open',
  '--json',
  'number,title,isDraft,headRefName,headRefOid,statusCheckRollup,reviewDecision',
  '--limit',
  '100',
] as const

const TERMINAL = new Set(['merged', 'abandoned', 'failed'])
const CI_IGNORED = new Set(['SKIPPED', 'NEUTRAL'])

type Json = Record<string, unknown>

export type ShipHandoff = { head_sha?: unknown; verdict?: unknown } | null
export type DoneRecord = { head_sha?: unknown; dirty?: unknown } | null

/** Task records are `*.json` with no dot in the stem; dotted stems are sidecars. */
export function isRecordName(name: string): boolean {
  return name.endsWith('.json') && !name.slice(0, -5).includes('.')
}

export function sha7(value: unknown): string {
  return typeof value === 'string' && value ? value.slice(0, 7) : '-'
}

function str(value: unknown): string | null {
  return typeof value === 'string' && value ? value : null
}

export function parseJson(text: string): Json | null {
  try {
    const value: unknown = JSON.parse(text)
    return value && typeof value === 'object' && !Array.isArray(value)
      ? (value as Json)
      : null
  } catch {
    return null
  }
}

export function shipVerdict(
  record: Json,
  ship: ShipHandoff,
): string {
  const verdict = ship ? str(ship.verdict) : null
  if (verdict) {
    const shipHead = str(ship?.head_sha)
    const head = str(record.head_sha)
    return shipHead && shipHead === head
      ? `ship:${verdict}`
      : `ship:${verdict}@${sha7(shipHead)}`
  }
  const review = str(record.review_outcome)
  return review ? `review:${review}` : '-'
}

/** Builds one row from a parsed record; `ship` and `done` are sidecars or null. */
export function taskRow(
  name: string,
  record: Json | null,
  done: DoneRecord,
  ship: ShipHandoff,
): FleetTaskRow {
  const id = name.slice(0, -5)
  if (!record) {
    return {
      id: name,
      status: 'unreadable',
      agent: '-',
      phase: '-',
      head: '-',
      pr: '-',
      prNumber: null,
      branch: null,
      verdict: '-',
      isDirty: false,
      isTerminal: false,
    }
  }
  const status = str(record.status) ?? '-'
  const workers = Array.isArray(record.workers) ? record.workers : []
  const last = (workers[workers.length - 1] ?? {}) as Json
  const prNumber = typeof record.pr_number === 'number' ? record.pr_number : null
  const head = str(record.head_sha)
  const isDirty =
    done !== null && done.dirty === true && str(done.head_sha) === head
  return {
    id: str(record.task_id) ?? id,
    status,
    agent: str(last.agent) ?? '-',
    phase: str(last.phase) ?? '-',
    head: sha7(head),
    pr: prNumber === null ? '-' : `#${prNumber}`,
    prNumber,
    branch: str(record.branch),
    verdict: shipVerdict(record, ship),
    isDirty,
    isTerminal: TERMINAL.has(status),
  }
}

/** Live rows win over archived rows with the same id. */
export function doneRows(
  live: FleetTaskRow[],
  archived: FleetTaskRow[],
): FleetTaskRow[] {
  const rows = live.filter(row => row.isTerminal)
  const seen = new Set(live.map(row => row.id))
  for (const row of archived) {
    if (!seen.has(row.id)) rows.push(row)
  }
  return rows.sort((a, b) => (a.id < b.id ? 1 : -1))
}

export function activeRows(live: FleetTaskRow[]): FleetTaskRow[] {
  return live
    .filter(row => !row.isTerminal)
    .sort((a, b) => (a.id < b.id ? 1 : -1))
}

type Check = Json

/** TypeScript copy of pr_status.py ci_state/ci_cell; keep the two in step. */
export function ciCell(rollup: unknown): FleetPrRow['ci'] {
  const checks = Array.isArray(rollup) ? (rollup as Check[]) : []
  let failing = false
  let pending = false
  let counted = false
  for (const check of checks) {
    if (check.__typename === 'StatusContext') {
      counted = true
      const state = String(check.state ?? '')
      if (state === 'SUCCESS') continue
      if (state === 'FAILURE' || state === 'ERROR') failing = true
      else pending = true
      continue
    }
    if (check.status !== 'COMPLETED') {
      counted = true
      pending = true
      continue
    }
    const conclusion = String(check.conclusion ?? '')
    if (CI_IGNORED.has(conclusion)) continue
    counted = true
    if (conclusion !== 'SUCCESS') failing = true
  }
  if (failing) return 'fail'
  if (pending) return 'pending'
  return counted ? 'pass' : 'none'
}

/** Throws when `text` is not a JSON array. */
export function prRows(text: string, tasks: FleetTaskRow[]): FleetPrRow[] {
  const list: unknown = JSON.parse(text)
  if (!Array.isArray(list)) throw new Error('output is not a JSON array')
  return (list as Json[]).map(pr => {
    const number = Number(pr.number)
    const branch = str(pr.headRefName)
    const linked =
      tasks.find(task => task.prNumber === number) ??
      tasks.find(task => branch !== null && task.branch === branch)
    return {
      number,
      title: String(pr.title ?? ''),
      isDraft: pr.isDraft === true,
      head: sha7(pr.headRefOid),
      ci: ciCell(pr.statusCheckRollup),
      review: String(pr.reviewDecision ?? '').toLowerCase() || '-',
      task: linked ? linked.id : null,
    }
  })
}

export function ghReason(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error)
  const first = text.split('\n').find(line => line.trim()) ?? 'failed'
  return first.trim().slice(0, 120)
}

export function summaryLine(
  active: number,
  done: number,
  prs: FleetPrRow[],
  ghError: string | null,
): string {
  const drafts = prs.filter(pr => pr.isDraft).length
  return (
    `fleet: ${active} active, ${done} done, ${prs.length} PRs (${drafts} draft)` +
    (ghError ? '; gh unavailable' : '')
  )
}

export function clip(text: string, width: number): string {
  return text.length <= width ? text.padEnd(width) : text.slice(0, width)
}
