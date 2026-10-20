import type {
  FleetDeadline,
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

export type ShipHandoff = { head_sha?: unknown; verdict?: unknown; launch_id?: unknown } | null
export type DoneRecord = Json | null
export type EventLines = Json[] | null

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

const LABEL_IDS = /\b[A-Z][A-Z0-9]+-\d+\b|#\d+/g
const LABEL_TRIM = /^[ \-:|,;.]+|[ \-:|,;.]+$/g

/** TypeScript port of herdr_orch_core._label_title; label-cases.ts keeps the two in step. */
export function labelTitle(record: Json): string {
  const raw = record.title
  const fallback = typeof raw !== 'string' || !raw.trim()
  let title = fallback
    ? String(record.task_id ?? '').replace(/^\d{4}-\d{2}-\d{2}-/, '')
    : (raw as string)
  title = title.replace(LABEL_IDS, ' ')
  if (fallback) title = title.replace(/[-_]+/g, ' ')
  title = title.replace(/[\u0000-\u001f\u007f]/g, ' ')
  return title.split(/\s+/).filter(Boolean).join(' ').replace(LABEL_TRIM, '')
}

/** The cut core.task_label applies: last space if it keeps half the width, else hard. */
export function fitTitle(title: string, width: number): string {
  if (title.length <= width) return title
  const cut = title.lastIndexOf(' ', width)
  const head = 2 * cut >= width ? title.slice(0, cut) : title.slice(0, width)
  return head.replace(/[ \-:|,;.]+$/, '')
}

export function repoName(root: string | null, slug: string): string {
  const base = root ? root.replace(/\/+$/, '').split('/').pop() : ''
  return base || slug.replace(/-[0-9a-f]{8}$/, '')
}

export function age(ms: number | null): string {
  if (ms === null || ms < 0) return ''
  const sec = Math.floor(ms / 1000)
  if (sec < 60) return `${sec}s`
  if (sec < 3600) return `${Math.floor(sec / 60)}m`
  if (sec < 48 * 3600) return `${Math.floor(sec / 3600)}h`
  return `${Math.floor(sec / 86400)}d`
}

/** The workspace whose event log tells whether the last worker is moving; null when unsafe. */
export function eventsWorkspace(record: Json): string | null {
  const workers = Array.isArray(record.workers) ? record.workers : []
  const id = str(((workers[workers.length - 1] ?? {}) as Json).workspace_id)
  return id !== null && /^[A-Za-z0-9]+$/.test(id) ? id : null
}

export function parseEvents(text: string): Json[] {
  return text.split('\n').flatMap(line => {
    const event = parseJson(line)
    return event ? [event] : []
  })
}

const noWorker = { agent: '-', state: '', since: null }

const PARKED_ORDER = ['merge?', 'gate?', 'open-pr?']

function prNumberOf(record: Json): number | null {
  for (const key of ['pr_number', 'pr']) {
    const value = record[key]
    if (typeof value === 'number' && Number.isInteger(value) && value > 0) return value
  }
  return null
}

/** Port of the `?` branch of herdr_orch_core.task_state_token; state-cases.ts keeps the two in step. */
export function ownerToken(record: Json, ship: ShipHandoff): string | null {
  const status = record.status
  if (status === 'pr-open-pending-merge') return 'merge?'
  if (status !== 'reviewed') return null
  if (prNumberOf(record) === null) return 'open-pr?'
  if (!ship) return null
  const head = str(record.review_head_sha)
  return ship.verdict === 'APPROVE' && head && ship.head_sha === head ? 'merge?' : 'gate?'
}

function lastWorker(record: Json, phase: string, launch?: string): Json | null {
  const workers = Array.isArray(record.workers) ? (record.workers as Json[]) : []
  for (let i = workers.length - 1; i >= 0; i--) {
    const w = workers[i]
    if (w && typeof w === 'object' && w.phase === phase && (launch === undefined || w.launch_id === launch)) {
      return w
    }
  }
  return null
}

function nsToMs(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value / 1e6 : null
}

function isoMs(value: unknown): number | null {
  const ms = typeof value === 'string' ? Date.parse(value) : NaN
  return Number.isNaN(ms) ? null : ms
}

const sec = (ms: number) => Math.floor(ms / 1000)

/** Worker state from the record, its done record and its event log (R6). */
function liveState(
  id: string,
  last: Json,
  done: DoneRecord,
  events: EventLines,
): FleetTaskRow['live'] {
  const agent = str(last.agent) ?? '-'
  const rowStart = nsToMs(last.started_ns)
  if (str(last.status) !== 'launched' && str(last.status) !== null) {
    return { agent, state: String(last.status), since: rowStart }
  }
  let start = rowStart
  let unresolved = false
  const reprompts = Array.isArray(last.reprompts) ? (last.reprompts as Json[]) : []
  for (const entry of reprompts) {
    const at = nsToMs(entry?.started_ns)
    if (at === null || entry.status === 'failed') continue
    if (start === null || at >= start) {
      start = at
      unresolved = entry.status === 'starting' || entry.status === 'uncertain'
    }
  }
  if (start === null) return { agent, state: 'working', since: null }
  const startSec = sec(start)
  const doneAt = done ? isoMs(done.ts) : null
  if (done && doneAt !== null && done.launch_id === last.launch_id && sec(doneAt) > startSec) {
    const outcome = str(done.outcome)
    return { agent, state: !outcome || outcome === 'completed' ? 'done' : outcome, since: doneAt }
  }
  for (let i = (events?.length ?? 0) - 1; i >= 0; i--) {
    const event = (events as Json[])[i]
    const at = isoMs(event.ts)
    if (event.task_id !== id || at === null || sec(at) <= startSec) continue
    if (event.event === 'blocked') return { agent, state: 'blocked', since: at }
    if (event.event === 'stopped' || event.event === 'review-stopped') {
      return { agent, state: 'idle', since: at }
    }
  }
  return { agent, state: unresolved ? 'unknown' : 'working', since: start }
}

/** Builds one row from a parsed record; `ship`, `done` and `events` are sidecars or null. */
export function taskRow(
  name: string,
  record: Json | null,
  done: DoneRecord,
  ship: ShipHandoff,
  events: EventLines = null,
): FleetTaskRow {
  const id = name.slice(0, -5)
  if (!record) {
    return {
      id: name,
      title: name,
      status: 'unreadable',
      live: noWorker,
      head: '-',
      pr: '-',
      prNumber: null,
      branch: null,
      verdict: '-',
      isDirty: false,
      isTerminal: false,
      owner: null,
      gateSince: null,
      reviewLaunch: null,
    }
  }
  const status = str(record.status) ?? '-'
  const taskId = str(record.task_id) ?? id
  const workers = Array.isArray(record.workers) ? record.workers : []
  const last = workers[workers.length - 1] as Json | undefined
  const isTerminal = TERMINAL.has(status)
  let live = noWorker
  if (last && typeof last === 'object') {
    live = isTerminal
      ? { agent: str(last.agent) ?? '-', state: '', since: null }
      : liveState(taskId, last, done, events)
  }
  const prNumber = typeof record.pr_number === 'number' ? record.pr_number : null
  const head = str(record.head_sha)
  const isDirty =
    done !== null && done.dirty === true && str(done.head_sha) === head
  // The core accepts a ship handoff only for the launch the record pins.
  const pinned = str(record.ship_launch_id)
  const pinnedShip = ship && pinned && ship.launch_id === pinned ? ship : null
  const owner = ownerToken(record, pinnedShip)
  let gateSince: number | null = null
  if (status === 'reviewed' && owner === null && pinned && !pinnedShip) {
    const row = lastWorker(record, 'ship', pinned)
    if (row && row.status === 'launched') gateSince = nsToMs(row.started_ns)
  }
  const reviewLaunch =
    status === 'review-dispatched' ? str(lastWorker(record, 'review')?.launch_id) : null
  return {
    id: taskId,
    title:
      labelTitle({ ...record, task_id: taskId }) ||
      taskId.replace(/^\d{4}-\d{2}-\d{2}-/, '') ||
      taskId,
    status,
    live,
    head: sha7(head),
    pr: prNumber === null ? '-' : `#${prNumber}`,
    prNumber,
    branch: str(record.branch),
    verdict: shipVerdict(record, ship),
    isDirty,
    isTerminal,
    owner,
    gateSince,
    reviewLaunch,
  }
}

/** Waiting tasks for the owner band: blocked first, then parked by token; each task once. */
export function ownerBand(rows: FleetTaskRow[]): Array<{ row: FleetTaskRow; token: string }> {
  const live = rows.filter(r => !r.isTerminal)
  const blocked = live.filter(r => r.status === 'blocked' || r.live.state === 'blocked')
  const parked = live.filter(r => !blocked.includes(r) && r.owner !== null)
  parked.sort((a, b) => PARKED_ORDER.indexOf(a.owner!) - PARKED_ORDER.indexOf(b.owner!))
  return [
    ...blocked.map(row => ({ row, token: 'blocked' })),
    ...parked.map(row => ({ row, token: row.owner! })),
  ]
}

const DEADLINE_STATES = new Set(['running', 'overdue', 'expired', 'unknown'])
const wholeSecs = (v: string | undefined) => (v !== undefined && /^\d+$/.test(v) ? Number(v) : null)

/** Parses `review-deadline` lines from the core; malformed lines are skipped. */
export function parseDeadlines(text: string): Record<string, FleetDeadline> {
  const out: Record<string, FleetDeadline> = {}
  for (const line of text.split('\n')) {
    const [head, ...parts] = line.trim().split(/\s+/)
    if (head !== 'review-deadline') continue
    const kv: Record<string, string> = {}
    for (const part of parts) {
      const at = part.indexOf('=')
      if (at > 0) kv[part.slice(0, at)] = part.slice(at + 1)
    }
    const deadlineSecs = wholeSecs(kv.deadline_secs)
    const hardSecs = wholeSecs(kv.hard_secs)
    const remaining = kv.remaining === 'unknown' ? null : wholeSecs(kv.remaining)
    if (!kv.task || !kv.launch || !DEADLINE_STATES.has(kv.state)) continue
    if (deadlineSecs === null || hardSecs === null) continue
    if (remaining === null && kv.remaining !== 'unknown') continue
    out[kv.task] = {
      launch: kv.launch,
      state: kv.state as FleetDeadline['state'],
      remaining,
      deadlineSecs,
      hardSecs,
    }
  }
  return out
}

/** Countdown text for a verb read `elapsedSecs` ago; null when the verb has no time to show. */
export function countdown(
  d: FleetDeadline,
  elapsedSecs: number,
): { text: string; isLate: boolean } | null {
  if (d.state === 'unknown') return null
  const expired = { text: 'expired', isLate: true }
  if (d.state === 'expired') return expired
  if (d.remaining === null) return null
  const e = Math.max(0, elapsedSecs)
  const left = d.remaining - e
  const mins = (secs: number) => age(secs * 1000)
  if (d.state === 'running' && left > 0) return { text: `running ${mins(left)}`, isLate: false }
  if (d.state === 'running') {
    const hard = left + (d.hardSecs - d.deadlineSecs)
    return hard > 0 ? { text: `overdue ${mins(hard)}`, isLate: true } : expired
  }
  return left > 0 ? { text: `overdue ${mins(left)}`, isLate: true } : expired
}

/** Status cell: review countdown, else ship gate elapsed, else the record status. */
export function statusCell(
  r: FleetTaskRow,
  deadlines: { at: number; rows: Record<string, FleetDeadline> } | null,
  readAt: number | null,
): { text: string; isLate: boolean } {
  const d = deadlines?.rows[r.id]
  if (r.status === 'review-dispatched' && d && r.reviewLaunch !== null && d.launch === r.reviewLaunch) {
    const shown = countdown(d, readAt === null || deadlines === null ? 0 : (readAt - deadlines.at) / 1000)
    if (shown) return shown
  }
  if (r.gateSince !== null && readAt !== null) {
    return { text: `co-review ${age(readAt - r.gateSince)}`, isLate: false }
  }
  return { text: r.status, isLate: false }
}

export function hasEvidence(row: FleetTaskRow): boolean {
  return row.head !== '-' || row.pr !== '-' || row.verdict !== '-'
}

/** `<agent> <state> <age>`, with the agent clipped so the state and age survive. */
export function liveCell(row: FleetTaskRow, readAt: number | null, width: number): string {
  const { agent, state, since } = row.live
  const ago = readAt === null || since === null ? '' : age(readAt - since)
  const tail = [state, ago].filter(Boolean).join(' ')
  if (!tail) return agent
  const room = Math.max(1, width - tail.length - 1)
  return `${plain(agent).slice(0, room)} ${tail}`
}

/** `<repo> | fence <n> | read <clock>`, clipping the repo name so the clock fits. */
export function headerLine(name: string, fence: number | null, read: string, width: number): string {
  const tail = ` | fence ${fence ?? '-'} | read ${read}`
  return `${plain(name).slice(0, Math.max(1, width - tail.length))}${tail}`
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
  ghError: boolean,
): string {
  const drafts = prs.filter(pr => pr.isDraft).length
  return (
    `fleet: ${active} active, ${done} done, ${prs.length} PRs (${drafts} draft)` +
    (ghError ? '; gh unavailable' : '')
  )
}

/** Replaces control characters so record or PR text cannot drive the terminal. */
export function plain(text: string): string {
  return text.replace(/[\u0000-\u001f\u007f-\u009f]/g, '?')
}

export function clip(raw: string, width: number): string {
  const text = plain(raw)
  return text.length <= width ? text.padEnd(width) : text.slice(0, width)
}
