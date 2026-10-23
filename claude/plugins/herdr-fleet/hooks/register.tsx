import { atom, read, update } from 'claude-code'
import type { Hook, Register } from 'claude-code'

import type {
  FleetLease,
  FleetPrRow,
  FleetAskRow,
  FleetQueueRow,
  FleetSnapshot,
  FleetTab,
  FleetTaskRow,
} from '../types'
import {
  GH_ARGV,
  GH_LIMIT,
  GROUP_ICONS,
  findPr,
  accountId,
  activeRows,
  age,
  boardHref,
  clip,
  jiraHref,
  parseAsks,
  parseQueue,
  plain,
  queueTitle,
  visibleQueue,
  doneRows,
  eventsWorkspace,
  fitTitle,
  ghReason,
  groupRows,
  hasEvidence,
  headerLine,
  isRecordName,
  liveCell,
  parseDeadlines,
  parseEvents,
  parseJson,
  prRows,
  prStacks,
  stackCell,
  repoName,
  statusCell,
  summaryLine,
  taskRow,
} from './fleet'
import type { FleetStack } from './fleet'

type Dollar = Parameters<Hook<'session.start'>>[0]
type Kind = 'tasks' | 'prs' | 'archive' | 'deadlines' | 'board'

const PANE = 'herdr-fleet'
const TASK_TICK_MS = 15000
const SLOW_TICK_MS = 300000
const GH_TIMEOUT_MS = 20000
const NO_LEASE = 'no herdr lease held by this session yet'

const EMPTY: FleetSnapshot = {
  lease: { kind: 'none' },
  repoRoot: null,
  live: { slug: null, rows: [] },
  archived: { slug: null, rows: [] },
  prs: null,
  ghError: null,
  deadlines: null,
  queue: null,
  board: null,
  jiraUrl: null,
  readError: null,
  readAt: null,
}

const tabAtom = atom({ plugin: 'herdr-fleet', key: 'tab' } as const, 'tasks' as FleetTab)
const snapAtom = atom({ plugin: 'herdr-fleet', key: 'snapshot' } as const, EMPTY)
const genAtom = atom({ plugin: 'herdr-fleet', key: 'generation' } as const, 0)
const openedAtom = atom({ plugin: 'herdr-fleet', key: 'opened' } as const, false)

function heldSlug(lease: FleetLease): string | null {
  return lease.kind === 'held' ? lease.slug : null
}

// Rows that belong to the lease held now; the render and /fleet share it.
function view(snap: FleetSnapshot) {
  const slug = heldSlug(snap.lease)
  const live = snap.live.slug === slug ? snap.live.rows : []
  const archived = snap.archived.slug === slug ? snap.archived.rows : []
  const prs = snap.prs && snap.prs.slug === slug ? snap.prs : null
  const ghError = snap.ghError && snap.ghError.slug === slug ? snap.ghError : null
  const deadlines = snap.deadlines && snap.deadlines.slug === slug ? snap.deadlines : null
  const queue = snap.queue && snap.queue.slug === slug ? snap.queue : null
  const board = snap.board && snap.board.slug === slug ? snap.board.path : null
  return { slug, live, archived, prs, ghError, deadlines, queue, board }
}

function clock(ms: number): string {
  const d = new Date(ms)
  const two = (n: number) => String(n).padStart(2, '0')
  return `${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`
}

function createFleet($: Dollar, generation: number) {
  const inflight: Record<Kind, Promise<void> | null> = {
    tasks: null,
    prs: null,
    archive: null,
    deadlines: null,
    board: null,
  }
  const triggered = new Map<Kind, Promise<void>>()

  async function configDir(): Promise<string> {
    const config = await $.env.get('CLAUDE_CONFIG_DIR')
    const home = (await $.env.get('HOME')) ?? ''
    return config ?? `${home}/.claude`
  }

  async function stateRoot(): Promise<string> {
    return `${await configDir()}/herdr-orch`
  }

  async function readText(path: string): Promise<string | null> {
    try {
      return await $.fs.read(path)
    } catch {
      return null
    }
  }

  async function resolveLease(root: string): Promise<FleetLease> {
    const sessionId = await $.session.id()
    const slugs: string[] = []
    const fences: Record<string, number | null> = {}
    let entries: Awaited<ReturnType<typeof $.fs.list>> = []
    try {
      entries = await $.fs.list(root)
    } catch {
      entries = []
    }
    for (const entry of entries) {
      if (entry.kind !== 'dir') continue
      const text = await readText(`${root}/${entry.name}/owner.json`)
      const owner = text === null ? null : parseJson(text)
      if (owner && owner.session_id === sessionId) {
        slugs.push(entry.name)
        fences[entry.name] = Number.isInteger(owner.fence) ? (owner.fence as number) : null
      }
    }
    if (slugs.length === 1) return { kind: 'held', slug: slugs[0], fence: fences[slugs[0]] }
    return slugs.length === 0
      ? { kind: 'none' }
      : { kind: 'ambiguous', slugs: slugs.sort() }
  }

  // Publishes only for this module load; `change` re-checks the lease slug
  // against the state it is applied to, so a lost race is dropped, not merged.
  async function publish(
    slug: string | null,
    change: (s: FleetSnapshot) => FleetSnapshot,
  ): Promise<void> {
    if ((await read($, genAtom)) !== generation) return
    await update($, snapAtom, s =>
      slug !== null && heldSlug(s.lease) !== slug ? s : change(s),
    )
  }

  async function refreshTasks(): Promise<void> {
    const root = await stateRoot()
    const lease = await resolveLease(root)
    const repo = await $.session.repo()
    const now = await $.clock.now()
    const slug = heldSlug(lease)
    const prev = await read($, snapAtom)
    const before = heldSlug(prev.lease)
    const jiraUrl = (await $.env.get('JIRA_URL')) ?? null
    const rows: FleetTaskRow[] = []
    let queue: FleetSnapshot['queue'] = null
    if (slug !== null) {
      const dir = `${root}/${slug}`
      let entries: Awaited<ReturnType<typeof $.fs.list>> = []
      try {
        entries = await $.fs.list(`${dir}/tasks`)
      } catch {
        entries = []
      }
      for (const entry of entries.filter(e => isRecordName(e.name))) {
        const text = await readText(`${dir}/tasks/${entry.name}`)
        const record = text === null ? null : parseJson(text)
        if (text === null) continue
        if (!record) {
          rows.push(taskRow(entry.name, null, null, null))
          continue
        }
        const id = entry.name.slice(0, -5)
        const doneText = await readText(`${dir}/tasks/${id}.done.json`)
        const launch = record.ship_launch_id
        const shipText =
          typeof launch === 'string' && launch
            ? await readText(`${dir}/artifacts/${id}/ship-${launch}/ship.json`)
            : null
        const reviewText = await readText(`${dir}/tasks/${id}.review.json`)
        const workspace = eventsWorkspace(record)
        const eventText =
          workspace === null
            ? null
            : await readText(`${dir}/workspaces/${workspace}.events.jsonl`)
        rows.push(
          taskRow(
            entry.name,
            record,
            doneText === null ? null : parseJson(doneText),
            shipText === null ? null : parseJson(shipText),
            eventText === null ? null : parseEvents(eventText),
            reviewText === null ? null : parseJson(reviewText),
          ),
        )
      }
    }
    if (slug !== null) queue = await readQueue(`${root}/${slug}`, slug, repo ? repo.root : null)
    if ((await read($, genAtom)) !== generation) return
    await update($, snapAtom, s => ({
      ...s,
      lease,
      repoRoot: repo ? repo.root : null,
      live: { slug, rows },
      queue,
      jiraUrl,
      readError: null,
      readAt: now,
    }))
    // gh and the archive run once per lease change, not on the task tick.
    if (slug !== null && slug !== before) {
      triggered.set('prs', forced('prs'))
      triggered.set('archive', forced('archive'))
      triggered.set('deadlines', forced('deadlines'))
      triggered.set('board', forced('board'))
    } else if (slug !== null) {
      // A record that left tasks/ was archived; load it so its queued todo stays hidden.
      const current = new Set(rows.map(r => r.id))
      if (prev.live.slug === slug && prev.live.rows.some(r => !current.has(r.id))) {
        triggered.set('archive', forced('archive'))
      }
    }
  }

  // Queued todo ids that still have a pending file; null for an unreadable record.
  async function readQueue(
    dir: string,
    slug: string,
    repoRoot: string | null,
  ): Promise<FleetSnapshot['queue']> {
    const ids = parseQueue(await readText(`${dir}/queue.json`))
    if (ids === null) return { slug, state: 'unreadable' }
    const rows: FleetQueueRow[] = []
    for (const id of repoRoot === null ? [] : ids) {
      const text = await readText(`${repoRoot}/.todos/pending/${id}.md`)
      if (text !== null) rows.push({ id, title: queueTitle(id, text) })
    }
    const asks = parseAsks(await readText(`${dir}/asks.jsonl`), await readText(`${dir}/decisions.jsonl`))
    return { slug, state: 'ok', rows, asks }
  }

  async function refreshArchive(): Promise<void> {
    const root = await stateRoot()
    const slug = heldSlug((await read($, snapAtom)).lease)
    if (slug === null) return
    const rows: FleetTaskRow[] = []
    let months: Awaited<ReturnType<typeof $.fs.list>> = []
    try {
      months = await $.fs.list(`${root}/${slug}/archive`)
    } catch {
      months = []
    }
    for (const month of months.filter(m => m.kind === 'dir')) {
      const dir = `${root}/${slug}/archive/${month.name}/tasks`
      let entries: Awaited<ReturnType<typeof $.fs.list>> = []
      try {
        entries = await $.fs.list(dir)
      } catch {
        entries = []
      }
      for (const entry of entries.filter(e => isRecordName(e.name))) {
        const text = await readText(`${dir}/${entry.name}`)
        if (text === null) continue
        const reviewText = await readText(`${dir}/${entry.name.slice(0, -5)}.review.json`)
        rows.push(
          taskRow(
            entry.name,
            parseJson(text),
            null,
            null,
            null,
            reviewText === null ? null : parseJson(reviewText),
          ),
        )
      }
    }
    await publish(slug, s => ({ ...s, archived: { slug, rows } }))
  }

  async function refreshPrs(): Promise<void> {
    const snap = await read($, snapAtom)
    const slug = heldSlug(snap.lease)
    if (slug === null) return
    const now = await $.clock.now()
    let failure: string | null = null
    let text = ''
    try {
      if (!snap.repoRoot) throw new Error('not in a git repository')
      const ran = await $.process.run([...GH_ARGV], {
        cwd: snap.repoRoot,
        timeoutMs: GH_TIMEOUT_MS,
      })
      if (ran.exitCode !== 0) {
        throw new Error(ran.stderr || `gh exited ${ran.exitCode}`)
      }
      text = ran.stdout
    } catch (error) {
      failure = ghReason(error)
    }
    await publish(slug, s => {
      if (failure === null) {
        try {
          const known = [...s.live.rows, ...s.archived.rows]
          return {
            ...s,
            prs: { slug, rows: prRows(text, known), at: now },
            ghError: null,
          }
        } catch (error) {
          return { ...s, ghError: { slug, reason: ghReason(error) } }
        }
      }
      return { ...s, ghError: { slug, reason: failure } }
    })
  }

  // Read-only core verb; a failed run keeps the previous part so the countdown keeps stepping.
  async function refreshDeadlines(): Promise<void> {
    const slug = heldSlug((await read($, snapAtom)).lease)
    if (slug === null) return
    const at = await $.clock.now()
    let text: string
    try {
      const core = `${await configDir()}/hooks/herdr_orch_core.py`
      const ran = await $.process.run(
        ['python3', core, 'review-deadlines', '--repo-slug', slug],
        { timeoutMs: GH_TIMEOUT_MS },
      )
      if (ran.exitCode !== 0) return
      text = ran.stdout
    } catch {
      return
    }
    await publish(slug, s => ({ ...s, deadlines: { slug, at, rows: parseDeadlines(text) } }))
  }

  // The board file sits under a per-account directory; ask the account-scope CLI which one.
  async function refreshBoard(): Promise<void> {
    const snap = await read($, snapAtom)
    const slug = heldSlug(snap.lease)
    if (slug === null) return
    let candidate: string | null = null
    const override = await $.env.get('TODOS_DASHBOARD_DIR')
    if (override) {
      candidate = `${override.replace(/\/+$/, '')}/${slug}.html`
    } else if (snap.repoRoot) {
      try {
        const script = `${await configDir()}/skills/lib/workflow_context.py`
        const argv = ['python3', script, 'account-scope', '--cwd', snap.repoRoot, '--runtime', 'claude']
        if ((await $.env.get('HERDR_PERSONAL')) === '1') argv.push('--personal')
        const ran = await $.process.run(argv, { timeoutMs: GH_TIMEOUT_MS })
        const account = ran.exitCode === 0 ? accountId(ran.stdout) : null
        if (account !== null) {
          const home = (await $.env.get('HOME')) ?? ''
          const state = (await $.env.get('XDG_STATE_HOME')) || `${home}/.local/state`
          candidate = `${state}/dotfiles/dashboard/${account}/${slug}.html`
        }
      } catch {
        candidate = null
      }
    }
    let path: string | null = null
    if (candidate !== null) {
      const at = candidate.lastIndexOf('/')
      try {
        const entries = await $.fs.list(candidate.slice(0, at))
        const name = candidate.slice(at + 1)
        if (entries.some(e => e.kind === 'file' && e.name === name)) path = candidate
      } catch {
        path = null
      }
    }
    await publish(slug, s => ({ ...s, board: { slug, path } }))
  }

  const runners: Record<Kind, () => Promise<void>> = {
    tasks: refreshTasks,
    prs: refreshPrs,
    archive: refreshArchive,
    deadlines: refreshDeadlines,
    board: refreshBoard,
  }

  function start(kind: Kind): Promise<void> {
    const running = inflight[kind]
    if (running) return running
    const next = runners[kind]()
      .catch(error =>
        kind === 'tasks'
          ? publish(null, s => ({ ...s, readError: ghReason(error) })).catch(() => {})
          : undefined,
      )
      .finally(() => {
        inflight[kind] = null
      })
    inflight[kind] = next
    return next
  }

  async function forced(kind: Kind): Promise<void> {
    const running = inflight[kind]
    if (running) await running
    await start(kind)
  }

  async function refreshAll(): Promise<void> {
    triggered.clear()
    await forced('tasks')
    await Promise.all([
      triggered.get('prs') ?? forced('prs'),
      triggered.get('archive') ?? forced('archive'),
      triggered.get('deadlines') ?? forced('deadlines'),
      triggered.get('board') ?? forced('board'),
    ])
  }

  return {
    refreshAll,
    startTasks: () => void start('tasks'),
    startSlow: () => {
      void start('prs')
      void start('archive')
      void start('deadlines')
      void start('board')
    },
  }
}

// One drawn span; a span with an href draws as a Link.
type Cell = { text: string; href?: string | null }
type Line = { key?: string; cells: Cell[]; color?: 'red' | 'yellow' }
type Col = [text: string, width: number, href?: string | null]

// Columns joined by a space. A link covers the clipped text only, not its padding.
function row(cols: Col[]): Cell[] {
  const cells: Cell[] = []
  cols.forEach(([text, width, href], i) => {
    const shown = clip(text, width)
    const body = shown.trimEnd()
    const sep = i < cols.length - 1 ? ' ' : ''
    if (href && body) cells.push({ text: body, href }, { text: shown.slice(body.length) + sep })
    else cells.push({ text: shown + sep })
  })
  return cells
}

const say = (text: string): Line => ({ cells: [{ text }] })

const STACK_WIDTH = 20

type Links = {
  board: string | null
  jiraUrl: string | null
  prs: FleetPrRow[]
  stacks: Map<number, FleetStack>
}

// The PR URL for a record: the matched open PR's, else the record's own.
function prHref(r: FleetTaskRow, prs: FleetPrRow[]): string | null {
  const open = prs.find(pr => r.prNumber !== null && pr.number === r.prNumber)
  return open?.url ?? r.prUrl
}

function taskLine(
  r: FleetTaskRow,
  width: number,
  readAt: number | null,
  evidence: boolean,
  deadlines: FleetSnapshot['deadlines'],
  links: Links,
): Line {
  const status = statusCell(r, deadlines, readAt)
  const cols: Col[] = [
    [status.text, 14],
    [liveCell(r, readAt, 26), 26],
  ]
  if (evidence) {
    const shown = hasEvidence(r)
    cols.push(
      [shown ? r.head : '', 7],
      [shown ? r.pr : '', 5, shown ? prHref(r, links.prs) : null],
      [shown ? r.verdict + (r.isDirty ? ' dirty' : '') : '', 24],
    )
  }
  const rest = cols.reduce((n, [, w]) => n + w + 1, 0)
  const titleWidth = Math.max(16, width - rest)
  return {
    cells: row([[fitTitle(plain(r.title), titleWidth), titleWidth], ...cols]),
    color: status.isLate ? 'red' : undefined,
  }
}

// `#pr`, optional Jira key, title, what the row waits on, time in that state.
function groupLines(
  grouped: ReturnType<typeof groupRows>,
  width: number,
  readAt: number,
  links: Links,
): Line[] {
  const hasKey = grouped.groups.some(g => g.items.some(i => i.row.jiraKey !== null))
  const minTitle = hasKey ? 12 : 16
  const baseWidth = width - 6 - 24 - 4 - 3 - (hasKey ? 11 : 0)
  const stackOf = (r: FleetTaskRow) => {
    const pr = findPr(r, links.prs)
    return pr ? links.stacks.get(pr.number) : undefined
  }
  const hasStack =
    baseWidth - STACK_WIDTH - 1 >= minTitle &&
    grouped.groups.some(g => g.items.some(i => stackOf(i.row)))
  const titleWidth = Math.max(minTitle, baseWidth - (hasStack ? STACK_WIDTH + 1 : 0))
  const lines: Line[] = []
  for (const { group, items } of grouped.groups) {
    lines.push(say(`${GROUP_ICONS[group]} ${group} (${items.length})`))
    for (const { row: r, waits, since, isLate } of items) {
      const keyCols: Col[] = hasKey
        ? [[r.jiraKey ?? '', 10, jiraHref(links.jiraUrl, r.jiraKey)]]
        : []
      const stackCols: Col[] = hasStack ? [[stackCell(stackOf(r)), STACK_WIDTH]] : []
      lines.push({
        cells: row([
          [r.prNumber === null ? '' : `#${r.prNumber}`, 6, prHref(r, links.prs)],
          ...stackCols,
          ...keyCols,
          [fitTitle(plain(r.title), titleWidth), titleWidth, boardHref(links.board, r.todoId)],
          [waits, 24],
          [since === null ? '' : age(readAt - since), 4],
        ]),
        color: isLate ? 'red' : group === 'Your call' ? 'yellow' : undefined,
      })
    }
  }
  if (grouped.parked) lines.push(say(`Parked: ${grouped.parked} idle over 3 days`))
  return lines
}

function queueLines(
  asks: FleetAskRow[],
  rows: FleetQueueRow[],
  width: number,
  board: string | null,
): Line[] {
  const titleWidth = Math.max(12, width - 4)
  const askWidth = Math.max(12, width - 2)
  return [
    ...asks.map(a => ({
      cells: row([[fitTitle(plain(`? ${a.task ?? 'repo'}: ${a.question}`), askWidth), askWidth]]),
      color: 'yellow' as const,
    })),
    ...rows.map((r, i) => ({
      cells: row([
        [`${i + 1}.`, 3],
        [fitTitle(plain(r.title), titleWidth), titleWidth, boardHref(board, r.id)],
      ]),
    })),
  ]
}

// Head, PR and verdict show only when some row has one and the title keeps 24 columns.
function showEvidence(rows: FleetTaskRow[], width: number): boolean {
  return width >= 105 && rows.some(hasEvidence)
}

function prLine(
  r: FleetPrRow,
  width: number,
  tasks: FleetTaskRow[],
  jiraUrl: string | null,
  stacks: Map<number, FleetStack>,
): Line {
  const linked = tasks.find(t => t.id === r.task)
  const fixed: Col[] = [
    [r.isDraft ? 'draft' : 'open', 5],
    [r.head, 7],
    [r.ci, 7],
    [r.review, 18],
    [r.task ?? 'no task', 30, jiraHref(jiraUrl, linked?.jiraKey ?? null)],
  ]
  const stack = stacks.get(r.number)
  const stackCols: Col[] = stacks.size ? [[stackCell(stack), STACK_WIDTH]] : []
  const rest = fixed.reduce((n, [, w]) => n + w + 1, 0) + 6 + (stacks.size ? STACK_WIDTH + 1 : 0)
  return {
    cells: row([
      [`#${r.number}`, 5, r.url],
      ...stackCols,
      [r.title, Math.max(12, width - rest)],
      ...fixed,
    ]),
    color: stack && stack.blockedBy === null && stack.blocks > 0 ? 'yellow' : undefined,
  }
}

export const register: Register = on => {
  let fleet: ReturnType<typeof createFleet> | null = null
  let hasOpened = false

  on('session.start', async ($, e, next) => {
    const generation = await update($, genAtom, n => n + 1)
    fleet = createFleet($, generation)
    await $.command.register({
      name: 'fleet',
      description: 'Show the herdr fleet pane and refresh it',
    })
    const active = fleet
    $.clock.every(TASK_TICK_MS, active.startTasks)
    $.clock.every(SLOW_TICK_MS, active.startSlow)
    void active.refreshAll()

    return next(e)
  })

  on('command.run', { command: 'fleet' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Fleet' })
    if (fleet) await fleet.refreshAll()
    const snap = await read($, snapAtom)
    const { slug, live, archived, prs, ghError } = view(snap)
    const done = doneRows(live, archived)
    const active = activeRows(live)
    const summary = summaryLine(active.length, done.length, prs ? prs.rows : null, ghError !== null)
    const detail =
      slug === null
        ? []
        : [
            `lease ${slug} | gh ${snap.repoRoot ?? '-'}`,
            ...active.map(r => `${r.id}  ${r.title}`),
          ]

    return { text: [summary, ...detail].join('\n') }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!hasOpened && !(await read($, openedAtom))) {
      // Render hooks cannot write state, so the host flag is set after the open.
      if (e.viewport?.isFullscreen === true) {
        hasOpened = true
        $.ui
          .open({ id: PANE, title: 'Fleet' })
          .then(() => update($, openedAtom, () => true))
          .catch(() => $.ui.log('herdr-fleet: could not open the pane; run /fleet'))
      } else if (e.viewport?.isFullscreen === false) {
        hasOpened = true
        $.ui.log('herdr-fleet: run /fleet to show the fleet pane')
      }
    }

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Link } = $.ui.resolve(e)
    const snap = await read($, snapAtom)
    const tab = await read($, tabAtom)
    const width = Math.max(40, e.props.bodyColumns)
    const { slug, live, archived, prs: prPart, ghError, deadlines, queue, board } = view(snap)
    const prs = prPart ? prPart.rows : []
    const active = activeRows(live)
    const done = doneRows(live, archived)
    const queued = queue && queue.state === 'ok' ? visibleQueue(queue.rows, [...live, ...archived]) : []
    const asks = queue && queue.state === 'ok' ? queue.asks : []
    const stacks = prStacks(prs)
    const links: Links = { board, jiraUrl: snap.jiraUrl, prs, stacks }
    const tabs: Array<[FleetTab, string, string]> = [
      ['tasks', '1', `tasks (${active.length})`],
      ['prs', '2', `PRs (${prPart ? prs.length : '?'})`],
      ['done', '3', `done (${done.length})`],
      ['queue', '4', `queue (${asks.length + queued.length})`],
    ]
    let header = NO_LEASE
    if (snap.lease.kind === 'ambiguous') {
      header = `ambiguous: this session holds leases for ${snap.lease.slugs.join(', ')}`
    } else if (slug !== null) {
      header = headerLine(
        repoName(snap.repoRoot, slug),
        snap.readAt === null ? '-' : clock(snap.readAt),
        width,
      )
    }
    const lines: Line[] = []
    const add = (text: string) => lines.push(say(text))
    if (snap.readError) add(`read failed: ${snap.readError}`)
    if (snap.readAt === null) {
      if (!snap.readError) add('reading...')
    } else if (slug !== null) {
      if (tab === 'tasks') {
        const complete = prPart !== null && prs.length < GH_LIMIT
        if (active.length) {
          lines.push(
            ...groupLines(
              groupRows(active, prs, complete, snap.readAt, deadlines),
              width,
              snap.readAt,
              links,
            ),
          )
        } else add('no tasks')
      } else if (tab === 'done') {
        if (snap.archived.slug !== slug) add('reading...')
        else {
          const evidence = showEvidence(done, width)
          if (done.length) {
            lines.push(...done.map(r => taskLine(r, width, snap.readAt, evidence, deadlines, links)))
          } else add('no finished tasks')
        }
      } else if (tab === 'queue') {
        if (queue === null) add('reading...')
        else if (queue.state === 'unreadable') add('queue unreadable')
        else if (asks.length + queued.length === 0) add('nothing queued')
        else lines.push(...queueLines(asks, queued, width, board))
      } else {
        if (ghError) {
          add(
            `gh unavailable: ${ghError.reason}${
              prPart ? ` (as of ${clock(prPart.at)})` : ''
            }`,
          )
        }
        if (!prPart) add(ghError ? 'PR list unknown' : 'reading...')
        else if (prs.length) {
          if (prs.length >= GH_LIMIT) add(`showing ${prs.length} (limit reached)`)
          prs.forEach(r => lines.push(prLine(r, width, [...live, ...archived], snap.jiraUrl, stacks)))
        } else add('no open PRs')
      }
    }

    return (
      <Box flexDirection="column">
        <Text dimColor wrap="truncate-end">{plain(header)}</Text>
        <Box flexDirection="row">
          {tabs.map(([name, hotkey, label]) => (
            <Button
              key={`tab-${name}`}
              hotkey={hotkey}
              label={label}
              onPress={() => update($, tabAtom, () => name)}
            />
          ))}
        </Box>
        {lines.map((line, i) => (
          <Text key={line.key ?? `line-${i}`} color={line.color} wrap="truncate-end">
            {line.cells.map((cell, j) =>
              cell.href ? (
                <Link key={j} href={cell.href}>
                  {plain(cell.text)}
                </Link>
              ) : (
                plain(cell.text)
              ),
            )}
          </Text>
        ))}
      </Box>
    )
  })
}
