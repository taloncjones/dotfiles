import { atom, read, update } from 'claude-code'
import type { Hook, Register } from 'claude-code'

import type {
  FleetLease,
  FleetPrRow,
  FleetSnapshot,
  FleetTab,
  FleetTaskRow,
} from '../types'
import {
  GH_ARGV,
  activeRows,
  clip,
  plain,
  doneRows,
  ghReason,
  isRecordName,
  parseJson,
  prRows,
  summaryLine,
  taskRow,
} from './fleet'

type Dollar = Parameters<Hook<'session.start'>>[0]
type Kind = 'tasks' | 'prs' | 'archive'

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
  prsAt: null,
  readAt: null,
}

const tabAtom = atom({ plugin: 'herdr-fleet', key: 'tab' } as const, 'tasks' as FleetTab)
const snapAtom = atom({ plugin: 'herdr-fleet', key: 'snapshot' } as const, EMPTY)
const genAtom = atom({ plugin: 'herdr-fleet', key: 'generation' } as const, 0)

function heldSlug(lease: FleetLease): string | null {
  return lease.kind === 'held' ? lease.slug : null
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
  }

  async function stateRoot(): Promise<string> {
    const config = await $.env.get('CLAUDE_CONFIG_DIR')
    const home = (await $.env.get('HOME')) ?? ''
    return `${config ?? `${home}/.claude`}/herdr-orch`
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
      if (owner && owner.session_id === sessionId) slugs.push(entry.name)
    }
    if (slugs.length === 1) return { kind: 'held', slug: slugs[0] }
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
    const rows: FleetTaskRow[] = []
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
        rows.push(
          taskRow(
            entry.name,
            record,
            doneText === null ? null : parseJson(doneText),
            shipText === null ? null : parseJson(shipText),
          ),
        )
      }
    }
    if ((await read($, genAtom)) !== generation) return
    await update($, snapAtom, s => ({
      ...s,
      lease,
      repoRoot: repo ? repo.root : null,
      live: { slug, rows },
      readAt: now,
    }))
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
        rows.push(taskRow(entry.name, parseJson(text), null, null))
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
            prs: { slug, rows: prRows(text, known) },
            prsAt: now,
            ghError: null,
          }
        } catch (error) {
          return { ...s, ghError: ghReason(error) }
        }
      }
      return { ...s, ghError: failure }
    })
  }

  const runners: Record<Kind, () => Promise<void>> = {
    tasks: refreshTasks,
    prs: refreshPrs,
    archive: refreshArchive,
  }

  function start(kind: Kind): Promise<void> {
    const running = inflight[kind]
    if (running) return running
    const next = runners[kind]()
      .catch(() => {})
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
    await forced('tasks')
    await Promise.all([forced('prs'), forced('archive')])
  }

  return {
    refreshAll,
    startTasks: () => void start('tasks'),
    startSlow: () => {
      void start('prs')
      void start('archive')
    },
  }
}

function row(cols: Array<[string, number]>): string {
  return cols.map(([text, width]) => clip(text, width)).join(' ')
}

function taskLine(r: FleetTaskRow, width: number): string {
  const fixed: Array<[string, number]> = [
    [r.status, 18],
    [r.agent, 16],
    [r.phase, 10],
    [r.head, 7],
    [r.pr, 5],
    [r.verdict + (r.isDirty ? ' dirty' : ''), 24],
  ]
  const rest = fixed.reduce((n, [, w]) => n + w + 1, 0)
  return row([[r.id, Math.max(12, width - rest)], ...fixed])
}

function prLine(r: FleetPrRow, width: number): string {
  const fixed: Array<[string, number]> = [
    [r.isDraft ? 'draft' : 'open', 5],
    [r.head, 7],
    [r.ci, 7],
    [r.review, 18],
    [r.task ?? 'no task', 30],
  ]
  const rest = fixed.reduce((n, [, w]) => n + w + 1, 0) + 6
  return row([
    [`#${r.number}`, 5],
    [r.title, Math.max(12, width - rest)],
    ...fixed,
  ])
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
    const live = snap.live.rows
    const done = doneRows(live, snap.archived.rows)

    return {
      text: summaryLine(
        activeRows(live).length,
        done.length,
        snap.prs?.rows ?? [],
        snap.ghError,
      ),
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!hasOpened) {
      if (e.viewport?.isFullscreen === true) {
        hasOpened = true
        void $.ui.open({ id: PANE, title: 'Fleet' })
      } else if (e.viewport?.isFullscreen === false) {
        hasOpened = true
        $.ui.log('herdr-fleet: run /fleet to show the fleet pane')
      }
    }

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const snap = await read($, snapAtom)
    const tab = await read($, tabAtom)
    const width = Math.max(40, e.props.bodyColumns)
    const slug = heldSlug(snap.lease)
    const live = snap.live.slug === slug ? snap.live.rows : []
    const archived = snap.archived.slug === slug ? snap.archived.rows : []
    const prs = snap.prs && snap.prs.slug === slug ? snap.prs.rows : []
    const active = activeRows(live)
    const done = doneRows(live, archived)
    const tabs: Array<[FleetTab, string, string]> = [
      ['tasks', '1', `tasks (${active.length})`],
      ['prs', '2', `PRs (${prs.length})`],
      ['done', '3', `done (${done.length})`],
    ]
    let header = NO_LEASE
    if (snap.lease.kind === 'ambiguous') {
      header = `ambiguous: this session holds leases for ${snap.lease.slugs.join(', ')}`
    } else if (slug !== null) {
      header = `lease ${slug} | gh ${snap.repoRoot ?? '-'} | read ${
        snap.readAt === null ? '-' : clock(snap.readAt)
      }`
    }
    const lines: string[] = []
    if (snap.readAt === null) lines.push('reading...')
    else if (slug !== null) {
      if (tab === 'tasks') {
        lines.push(...(active.length ? active.map(r => taskLine(r, width)) : ['no tasks']))
      } else if (tab === 'done') {
        lines.push(...(done.length ? done.map(r => taskLine(r, width)) : ['no finished tasks']))
      } else {
        if (snap.ghError) {
          lines.push(
            `gh unavailable: ${snap.ghError}${
              snap.prsAt === null ? '' : ` (as of ${clock(snap.prsAt)})`
            }`,
          )
        }
        lines.push(...(prs.length ? prs.map(r => prLine(r, width)) : ['no open PRs']))
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
        {lines.map(line => (
          <Text wrap="truncate-end">{plain(line)}</Text>
        ))}
      </Box>
    )
  })
}
