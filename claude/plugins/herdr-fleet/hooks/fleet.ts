import type {
  FleetDeadline,
  FleetGroup,
  FleetPrRow,
  FleetAskRow,
  FleetQueueRow,
  FleetSnapshot,
  FleetTaskRow,
} from '../types'

export const GH_LIMIT = 100

export const GH_ARGV = [
  'gh',
  'pr',
  'list',
  '--state',
  'open',
  '--author', '@me',
  '--json',
  'number,title,isDraft,headRefName,headRefOid,statusCheckRollup,reviewDecision,reviews,url,baseRefName,isCrossRepository',
  '--limit',
  String(GH_LIMIT),
] as const

const TERMINAL = new Set(['merged', 'abandoned', 'failed'])
const CI_IGNORED = new Set(['SKIPPED', 'NEUTRAL'])

type Json = Record<string, unknown>

export type ShipHandoff = {
  head_sha?: unknown
  verdict?: unknown
  launch_id?: unknown
  written_at?: unknown
} | null
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

/** The sidecar's outcome when it is the current review of this record; else null (partial port of is_reviewed). */
export function currentReview(record: Json, sidecar: Json | null): string | null {
  if (!sidecar) return null
  const launch = str(sidecar.launch_id)
  if (!launch || launch !== str(lastWorker(record, 'review')?.launch_id)) return null
  const head = str(sidecar.reviewed_head_sha)
  if (!head || head !== str(record.review_head_sha)) return null
  if ('retired_review_launch_ids' in record) {
    const retired = record.retired_review_launch_ids
    if (!Array.isArray(retired) || retired.includes(launch)) return null
  }
  const blocking = sidecar.blocking_count
  if (!Number.isInteger(blocking) || blocking !== 0) return 'changes-requested'
  return str(sidecar.outcome)
}

export function shipVerdict(
  record: Json,
  ship: ShipHandoff,
  sidecar: Json | null = null,
): string {
  const verdict = ship ? str(ship.verdict) : null
  if (verdict) {
    const shipHead = str(ship?.head_sha)
    const head = str(record.head_sha)
    return shipHead && shipHead === head
      ? `ship:${verdict}`
      : `ship:${verdict}@${sha7(shipHead)}`
  }
  const review = currentReview(record, sidecar) ?? str(record.review_outcome)
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

function latest(values: Array<number | null>): number | null {
  const known = values.filter((v): v is number => v !== null)
  return known.length ? Math.max(...known) : null
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

const JIRA_KEY = /^[A-Z][A-Z0-9]+-\d+$/
const TODO_ID = /^[A-Za-z0-9][A-Za-z0-9_-]*$/
const UNSAFE_URL = '[^\\s\\u0000-\\u001f\\u007f-\\u009f]+'
const HTTPS_URL = new RegExp(`^https://${UNSAFE_URL}$`)
const HTTP_URL = new RegExp(`^https?://${UNSAFE_URL}$`)

/** The URL when it is a safe https link of at most 2048 characters; else null. */
export function safeHttps(value: unknown): string | null {
  return typeof value === 'string' && value.length <= 2048 && HTTPS_URL.test(value) ? value : null
}

function todoIdOf(value: unknown): string | null {
  return typeof value === 'string' && TODO_ID.test(value) && !value.includes('..') ? value : null
}

function jiraKeyOf(record: Json, taskId: string): string | null {
  const key = str(record.jira_key)
  if (key !== null && JIRA_KEY.test(key)) return key
  return record.kind === 'jira' && JIRA_KEY.test(taskId) ? taskId : null
}

/** `<base>/browse/<key>` for a Jira base that is http(s); else null. */
export function jiraHref(base: string | null | undefined, key: string | null): string | null {
  if (!base || !key || !HTTP_URL.test(base)) return null
  return `${base.replace(/\/+$/, '')}/browse/${key}`
}

/** Builds one row from a parsed record; `ship`, `done`, `events` and `sidecar` are sidecars or null. */
export function taskRow(
  name: string,
  record: Json | null,
  done: DoneRecord,
  ship: ShipHandoff,
  events: EventLines = null,
  sidecar: Json | null = null,
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
      prUrl: null,
      todoId: null,
      jiraKey: null,
      branch: null,
      verdict: '-',
      isDirty: false,
      isTerminal: false,
      owner: null,
      gateSince: null,
      reviewLaunch: null,
      since: null,
      reviewHead: null,
      review: null,
      phase: null,
      ship: null,
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
  const prNumber = prNumberOf(record)
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
  const review = currentReview(record, sidecar)
  const since = latest([
    live.since,
    last && typeof last === 'object' ? nsToMs(last.started_ns) : null,
    done ? isoMs(done.ts) : null,
    review !== null && sidecar ? isoMs(sidecar.ts) : null,
    pinnedShip ? isoMs(pinnedShip.written_at) : null,
    isoMs(record.updated),
  ])
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
    prUrl: safeHttps(record.pr_url),
    todoId: todoIdOf(record.todo_id),
    jiraKey: jiraKeyOf(record, taskId),
    branch: str(record.branch),
    verdict: shipVerdict(record, ship, sidecar),
    isDirty,
    isTerminal,
    owner,
    gateSince,
    reviewLaunch,
    since,
    reviewHead: str(record.review_head_sha) ?? head,
    review,
    phase: last && typeof last === 'object' ? str(last.phase) : null,
    ship: pinnedShip ? { verdict: str(pinnedShip.verdict), head: str(pinnedShip.head_sha) } : null,
  }
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

/** `<repo> | read <clock>`, clipping the repo name so the clock fits. */
export function headerLine(name: string, read: string, width: number): string {
  const tail = ` | read ${read}`
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

export const PARKED_MS = 3 * 24 * 3600 * 1000
export const GROUPS: FleetGroup[] = ['Your call', 'Needs director', 'Waiting on reviewers', 'Agents working']
export const GROUP_ICONS: Record<string, string> = {
  'Your call': '\u{1F514}',
  'Needs director': '\u{1F9ED}',
  'Waiting on reviewers': '\u{1F440}',
  'Agents working': '\u{1F916}',
}

export type Classified = { group: FleetGroup; waits: string; since: number | null; isLate: boolean }
type Placed = Omit<Classified, 'since'>

const PHASE_WORDS: Record<string, string> = { ship: 'co-review', mechanical: 'implement' }
const phaseWord = (phase: string | null) => (phase ? (PHASE_WORDS[phase] ?? phase) : 'worker')
const HUMAN_WAITS = {
  changes: 'changes requested',
  required: 'needs a human review',
  'approved-old': 'approval on older head',
}

function place(group: FleetGroup, waits: string, isLate = false): Placed {
  return { group, waits, isLate }
}

export function findPr(row: FleetTaskRow, prs: FleetPrRow[]): FleetPrRow | null {
  return (
    prs.find(pr => row.prNumber !== null && pr.number === row.prNumber) ??
    prs.find(pr => row.branch !== null && pr.branch === row.branch) ??
    null
  )
}

/** What a reviewed row waits on once the herdr gate is read (R5.7). */
function gateWaits(row: FleetTaskRow, human: FleetPrRow['human'] | null): Placed {
  if (row.status === 'pr-open-pending-merge' || row.owner === 'merge?') {
    return place('Your call', 'ready to merge')
  }
  if (row.ship) {
    const verdict = (row.ship.verdict ?? 'no verdict').toLowerCase()
    return place(
      'Needs director',
      row.ship.head !== row.reviewHead ? 'co-review on old head' : `co-review: ${verdict}`,
    )
  }
  return place('Needs director', human === 'approved' ? 'approved; no co-review' : 'co-review not run')
}

function prStage(row: FleetTaskRow, pr: FleetPrRow | null, complete: boolean): Placed {
  if (!pr) {
    if (!complete) {
      if (row.owner === 'merge?') return place('Your call', 'merge? review unknown')
      if (row.owner === 'open-pr?') return place('Your call', 'open the PR')
      return gateWaits(row, null)
    }
    return row.prNumber === null
      ? place('Your call', 'open the PR')
      : place('Needs director', 'PR is not open')
  }
  if (row.prNumber === null) return place('Needs director', `record lacks PR #${pr.number}`)
  if (row.reviewHead && pr.headOid && row.reviewHead !== pr.headOid) {
    return place('Needs director', 'PR head moved')
  }
  if (pr.human === 'changes') return place('Your call', HUMAN_WAITS.changes)
  if (pr.human in HUMAN_WAITS) {
    return place('Waiting on reviewers', HUMAN_WAITS[pr.human as keyof typeof HUMAN_WAITS])
  }
  return gateWaits(row, pr.human)
}

function placeRow(
  row: FleetTaskRow,
  pr: FleetPrRow | null,
  complete: boolean,
  readAt: number,
  deadlines: FleetSnapshot['deadlines'],
): Placed {
  if (row.status === 'blocked' || row.live.state === 'blocked') return place('Your call', 'blocked')
  const finished = row.phase === 'review' && row.review !== null
  const d = deadlines?.rows[row.id]
  const shown =
    deadlines && d && row.status === 'review-dispatched' && row.reviewLaunch !== null && d.launch === row.reviewLaunch
      ? countdown(d, (readAt - deadlines.at) / 1000)
      : null
  if (shown?.text === 'expired' && !finished) return place('Needs director', 'review expired', true)

  const fresh = (at: number | null) => at !== null && readAt - at <= PARKED_MS
  const working = row.live.state === 'working' || row.live.state === 'unknown'
  // A ship worker whose handoff is pinned has finished, whatever its event log says.
  const isLive =
    working && fresh(row.live.since) && !finished && !(row.phase === 'ship' && row.ship !== null)
  const word = phaseWord(row.phase)
  if (fresh(row.gateSince)) return place('Agents working', 'co-review running')
  if (isLive) {
    if (shown) return place('Agents working', `review ${shown.text}`, shown.isLate)
    return place('Agents working', `${word} ${row.live.state === 'unknown' ? 'state unknown' : 'running'}`)
  }
  if (row.status === 'reviewed' || row.status === 'pr-open-pending-merge') {
    return prStage(row, pr, complete)
  }
  const worker = row.live.state
    ? `${word} ${working && !finished ? 'no signal' : row.live.state}`
    : 'no worker'
  const waits: Record<string, string> = {
    completed: 'review not sent',
    'changes-requested': 'repair not started',
    'review-dispatched': row.review ? `review ${row.review}` : worker,
    'in-progress': worker,
    unreadable: 'record unreadable',
  }
  return place('Needs director', waits[row.status] ?? row.status)
}

/** Group, wait phrase, activity time and lateness of one active row (R4 to R6). */
export function classify(
  row: FleetTaskRow,
  prs: FleetPrRow[],
  complete: boolean,
  readAt: number,
  deadlines: FleetSnapshot['deadlines'] = null,
): Classified {
  const pr = findPr(row, prs)
  const since = latest([row.since, pr?.reviewAt ?? null])
  const placed = placeRow(row, pr, complete, readAt, deadlines)
  const isIdle = since !== null && readAt - since > PARKED_MS
  const parks = placed.group === 'Needs director' || placed.group === 'Waiting on reviewers'
  return { ...placed, group: isIdle && parks ? 'Parked' : placed.group, since }
}

export type GroupedRows = {
  groups: Array<{ group: FleetGroup; items: Array<{ row: FleetTaskRow } & Classified> }>
  parked: number
}

/** Non-empty groups in who-acts-next order, oldest activity first; parked rows only counted. */
export function groupRows(
  rows: FleetTaskRow[],
  prs: FleetPrRow[],
  complete: boolean,
  readAt: number,
  deadlines: FleetSnapshot['deadlines'] = null,
): GroupedRows {
  const items = rows
    .filter(row => !row.isTerminal)
    .map(row => ({ row, ...classify(row, prs, complete, readAt, deadlines) }))
  const oldest = (a: number | null, b: number | null) =>
    a === b ? 0 : a === null ? 1 : b === null ? -1 : a - b
  const groups = GROUPS.map(group => ({
    group,
    items: items
      .filter(item => item.group === group)
      .sort((a, b) => oldest(a.since, b.since) || (a.row.id < b.row.id ? -1 : 1)),
  })).filter(g => g.items.length)
  return { groups, parked: items.filter(item => item.group === 'Parked').length }
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

/** Summarises the human review state; an empty decision means no review rule applies. */
function humanState(pr: Json): FleetPrRow['human'] {
  const decision = str(pr.reviewDecision)
  if (!decision) return 'none'
  if (decision === 'CHANGES_REQUESTED') return 'changes'
  if (decision !== 'APPROVED') return 'required'
  let approval: Json | null = null
  let approvedAt = -Infinity
  for (const review of Array.isArray(pr.reviews) ? (pr.reviews as Json[]) : []) {
    if (review?.state !== 'APPROVED') continue
    const at = isoMs(review.submittedAt) ?? -Infinity
    if (at >= approvedAt) {
      approval = review
      approvedAt = at
    }
  }
  const commit = approval?.commit as Json | null | undefined
  const head = str(pr.headRefOid)
  return head !== null && str(commit?.oid) === head ? 'approved' : 'approved-old'
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
    const reviews = Array.isArray(pr.reviews) ? (pr.reviews as Json[]) : []
    return {
      number,
      title: String(pr.title ?? ''),
      isDraft: pr.isDraft === true,
      head: sha7(pr.headRefOid),
      ci: ciCell(pr.statusCheckRollup),
      review: String(pr.reviewDecision ?? '').toLowerCase() || '-',
      task: linked ? linked.id : null,
      branch,
      headOid: str(pr.headRefOid),
      reviewAt: latest(reviews.map(review => isoMs(review?.submittedAt))),
      url: safeHttps(pr.url),
      human: humanState(pr),
      base: str(pr.baseRefName),
      isFork: pr.isCrossRepository === true,
    }
  })
}

export type FleetStack = {
  pos: number
  height: number
  root: number
  blockedBy: number | null
  /** PRs above this one when it is a blocker, else 0. */
  blocks: number
}

/**
 * Stacks among the listed PRs: a PR whose base is the head of exactly one other
 * non-fork listed PR sits above it. Rows from an older module (no `base` or
 * `isFork`) build no stack.
 */
export function prStacks(prs: FleetPrRow[]): Map<number, FleetStack> {
  const byHead = new Map<string, FleetPrRow[]>()
  for (const pr of prs) {
    if (pr.isFork !== false || pr.branch === null) continue
    byHead.set(pr.branch, [...(byHead.get(pr.branch) ?? []), pr])
  }
  const parentOf = (pr: FleetPrRow): FleetPrRow | null => {
    const found = (pr.base ? (byHead.get(pr.base) ?? []) : []).filter(q => q !== pr)
    return found.length === 1 ? found[0] : null
  }

  // Ancestors nearest first; a PR whose walk revisits a PR is unstacked.
  const ancestors = new Map<FleetPrRow, FleetPrRow[]>()
  for (const pr of prs) {
    const chain: FleetPrRow[] = []
    const seen = new Set<FleetPrRow>([pr])
    let cyclic = false
    for (let up = parentOf(pr); up; up = parentOf(up)) {
      if (seen.has(up)) {
        cyclic = true
        break
      }
      seen.add(up)
      chain.push(up)
    }
    if (!cyclic) ancestors.set(pr, chain)
  }

  const members = new Map<FleetPrRow, FleetPrRow[]>()
  for (const [pr, chain] of ancestors) {
    const root = chain.length ? chain[chain.length - 1] : pr
    members.set(root, [...(members.get(root) ?? []), pr])
  }
  const descendants = new Map<FleetPrRow, number>()
  for (const chain of ancestors.values()) {
    for (const up of chain) descendants.set(up, (descendants.get(up) ?? 0) + 1)
  }
  const isBlocker = (pr: FleetPrRow) =>
    (descendants.get(pr) ?? 0) > 0 && (pr.ci === 'fail' || pr.human === 'changes')

  const stacks = new Map<number, FleetStack>()
  for (const [root, group] of members) {
    if (group.length < 2) continue
    const height = Math.max(...group.map(pr => ancestors.get(pr)!.length + 1))
    for (const pr of group) {
      const chain = ancestors.get(pr)!
      const blocker = [...chain].reverse().find(isBlocker)
      stacks.set(pr.number, {
        pos: chain.length + 1,
        height,
        root: root.number,
        blockedBy: blocker ? blocker.number : null,
        blocks: isBlocker(pr) ? (descendants.get(pr) ?? 0) : 0,
      })
    }
  }
  return stacks
}

/** The stack cell text for one PR; empty when it is in no stack. */
export function stackCell(stack: FleetStack | undefined): string {
  if (!stack) return ''
  const place = `${stack.pos}/${stack.height}`
  if (stack.blockedBy !== null) return `${place} blocked by #${stack.blockedBy}`
  if (stack.blocks > 0) return `${place} blocks ${stack.blocks}`
  return `${place} #${stack.root}`
}

export function ghReason(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error)
  const first = text.split('\n').find(line => line.trim()) ?? 'failed'
  return first.trim().slice(0, 120)
}

export function summaryLine(
  active: number,
  done: number,
  prs: FleetPrRow[] | null,
  ghError: boolean,
): string {
  const drafts = prs ? prs.filter(pr => pr.isDraft).length : 0
  const prText = prs ? `${prs.length} PRs (${drafts} draft)` : 'PR list unknown'
  return (
    `fleet: ${active} active, ${done} done, ${prText}` +
    (ghError ? '; gh unavailable' : '')
  )
}

export const QUEUE_MAX = 10

/** Ids from `queue.json`: [] when the file is missing, null when it is unreadable. */
export function parseQueue(text: string | null): string[] | null {
  if (text === null) return []
  const queue = parseJson(text)
  if (!queue || queue.v !== 1 || !Array.isArray(queue.todos) || queue.todos.length > QUEUE_MAX) {
    return null
  }
  const ids = queue.todos as unknown[]
  return ids.every(id => todoIdOf(id) !== null) ? (ids as string[]) : null
}

/** Live owner asks from `asks.jsonl`: no drop names one and no decision (`decisions.jsonl`) answers it. */
export function parseAsks(asksText: string | null, decisionsText: string | null): FleetAskRow[] {
  const records = (text: string | null) =>
    (text ?? '').split('\n').map(line => parseJson(line)).filter(rec => rec && rec.v === 1)
  const closed = new Set<unknown>([
    ...records(asksText).filter(r => r.event === 'drop').map(r => r.drops),
    ...records(decisionsText).map(r => r.ask),
  ])
  return records(asksText)
    .filter(r => r.event === 'ask' && typeof r.id === 'string' && typeof r.question === 'string')
    .filter(r => !closed.has(r.id))
    .map(r => ({ id: r.id as string, task: typeof r.task === 'string' ? r.task : null, question: r.question as string }))
}

/** A queued todo's title: its frontmatter `title:` through labelTitle, else the id. */
export function queueTitle(id: string, text: string): string {
  let title: string | undefined
  if (text.startsWith('---\n')) {
    const end = text.indexOf('\n---', 4)
    const head = end === -1 ? text.slice(4) : text.slice(4, end)
    const match = /^title:[ \t]*(.*)$/m.exec(head)
    title = match ? match[1].trim().replace(/^(["'])(.*)\1$/, '$2') : undefined
  }
  return labelTitle({ title, task_id: id }) || id
}

/** Queue rows left once any task record naming the todo hides it (D4). */
export function visibleQueue(rows: FleetQueueRow[], tasks: FleetTaskRow[]): FleetQueueRow[] {
  const named = new Set(tasks.map(task => task.todoId))
  return rows.filter(row => !named.has(row.id))
}

/** `account_id` from `workflow_context.py account-scope`: 64 lowercase hex, else null. */
export function accountId(stdout: string): string | null {
  const id = parseJson(stdout)?.account_id
  return typeof id === 'string' && /^[0-9a-f]{64}$/.test(id) ? id : null
}

export function boardHref(path: string | null | undefined, todoId: string | null): string | null {
  return path && todoId ? `file://${encodeURI(path)}#todo-${todoId}` : null
}

/** Replaces control characters so record or PR text cannot drive the terminal. */
export function plain(text: string): string {
  return text.replace(/[\u0000-\u001f\u007f-\u009f]/g, '?')
}

export function clip(raw: string, width: number): string {
  const text = plain(raw)
  return text.length <= width ? text.padEnd(width) : text.slice(0, width)
}
