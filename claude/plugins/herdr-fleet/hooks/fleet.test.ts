import { expect, mock, test } from 'claude-code/testing'

import {
  age, ciCell, classify, fitTitle, labelTitle, ownerToken, prRows, repoName, shipVerdict, summaryLine, taskRow,
} from './fleet'
import { LABEL_CASES } from './label-cases'
import { STATE_CASES } from './state-cases'

const ROOT = '/h/.claude/herdr-orch'
const GH = ['gh', 'pr', 'list', '--state', 'open', '--author', '@me', '--json',
  'number,title,isDraft,headRefName,headRefOid,statusCheckRollup,reviewDecision,reviews,url',
  '--limit', '100']
const OK = { exitCode: 0, stdout: '[]', stderr: '' }
const OK_VERB = { exitCode: 0, stdout: '', stderr: '' }

type GhAnswer = { exitCode: number; stdout: string; stderr: string } | 'reject'

type World = {
  files: Record<string, string>
  ghosts: string[]
  gh: GhAnswer
  ghGate: Promise<void> | null
  readGate: { path: string; gate: Promise<void>; used: boolean } | null
  runs: string[][]
  running: number
  maxRunning: number
  opened: string[]
  logs: string[]
  repoFails: boolean
  root: string
  reads: string[]
  openFails: boolean
  verb: GhAnswer
  verbGate: Promise<void> | null
  verbRuns: string[][]
  verbRunning: number
  verbMax: number
  env: Record<string, string>
  scope: GhAnswer
  scopeEvents: any[]
}

function newWorld(files: Record<string, string> = {}): World {
  return {
    files, ghosts: [], gh: OK, ghGate: null, readGate: null,
    runs: [], running: 0, maxRunning: 0, opened: [], logs: [], repoFails: false, openFails: false,
    root: '/repo', reads: [],
    verb: OK_VERB, verbGate: null, verbRuns: [], verbRunning: 0, verbMax: 0,
    env: { HOME: '/h' }, scope: { exitCode: 1, stdout: '', stderr: 'no scope' }, scopeEvents: [],
  }
}

function owner(slug: string, fence?: number): Record<string, string> {
  return { [`${ROOT}/${slug}/owner.json`]: JSON.stringify({ session_id: 'sess', fence }) }
}

function task(slug: string, id: string, over: object = {}, sidecars: Record<string, object> = {}) {
  const files: Record<string, string> = {
    [`${ROOT}/${slug}/tasks/${id}.json`]: JSON.stringify({
      task_id: id, status: 'in-progress', head_sha: 'abcdef0123', ...over,
    }),
  }
  for (const [name, body] of Object.entries(sidecars)) {
    files[`${ROOT}/${slug}/${name}`] = JSON.stringify(body)
  }
  return files
}

// Stubs the engine beneath the plugin: env, session, fs, process and ui.
function stub(on: any, w: World) {
  const clock = mock.clock(on)
  on('env.get', (_$: any, e: any) => ({ value: w.env[e.name] }))
  on('command.register', () => ({ value: undefined }))
  on('session.start', (_$: any, e: any) => ({ cwd: e.cwd }))
  on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => (globalThis as any).h($.ui.resolve(e).Box, {}))
  on('session.id', () => ({ value: 'sess' }))
  on('session.repo', (_$: any, e: any, next: any) => {
    if (w.repoFails) return next(e)
    return { value: { root: w.root, remote: null } }
  })
  on('ui.open', (_$: any, e: any) => {
    w.opened.push(e.id)
    if (w.openFails) throw new Error('no dock')
    return { value: { isPlaced: true } }
  })
  on('ui.log', (_$: any, e: any) => {
    w.logs.push(e.text)
    return { value: undefined }
  })
  on('fs.list', async (_$: any, e: any) => {
    const prefix = `${e.path.replace(/\/$/, '')}/`
    const kinds = new Map<string, string>()
    for (const key of [...Object.keys(w.files), ...w.ghosts]) {
      if (!key.startsWith(prefix)) continue
      const [head, ...tail] = key.slice(prefix.length).split('/')
      kinds.set(head, tail.length ? 'dir' : 'file')
    }
    return {
      value: [...kinds].map(([name, kind]) => ({
        name, kind, size: 0, mtimeMs: 0, isLink: false,
      })),
    }
  })
  on('fs.read', async (_$: any, e: any, next: any) => {
    w.reads.push(e.path)
    if (!(e.path in w.files)) return next(e)
    const text = w.files[e.path]
    const g = w.readGate
    if (g && !g.used && e.path === g.path) {
      g.used = true
      await g.gate
    }
    return { value: text }
  })
  on('process.run', async (_$: any, e: any, next: any) => {
    if (e.argv[0] === 'python3' && String(e.argv[1]).endsWith('workflow_context.py')) {
      w.scopeEvents.push(e)
      if (w.scope === 'reject') return next(e)
      return { value: w.scope }
    }
    if (e.argv[0] === 'python3') {
      w.verbRuns.push([...e.argv])
      w.verbRunning += 1
      w.verbMax = Math.max(w.verbMax, w.verbRunning)
      try {
        if (w.verbGate) await w.verbGate
        if (w.verb === 'reject') return next(e)
        return { value: w.verb }
      } finally {
        w.verbRunning -= 1
      }
    }
    w.runs.push([...e.argv])
    w.running += 1
    w.maxRunning = Math.max(w.maxRunning, w.running)
    try {
      if (w.ghGate) await w.ghGate
      if (w.gh === 'reject') return next(e)
      return { value: w.gh }
    } finally {
      w.running -= 1
    }
  })
  return clock
}

async function boot($: any, clock: any) {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await clock.settle()
}

async function pane($: any, cols = 160) {
  return $.ui.mount({
    plugin: 'herdr-fleet', surface: 'terminal', component: 'Pane',
    requestId: 'herdr-fleet',
    props: {
      title: 'Fleet', isFocused: false, bodyColumns: cols, placement: 'dock',
      scroll: { offset: 0, bodyRows: 30 }, view: {},
    },
    viewport: { columns: cols, rows: 40, isFullscreen: true },
  })
}

// The harness shows a Link as its href then its label; a terminal with OSC 8 shows the label only.
const hrefOf = (l: any): string => l.props.href
const labelOf = (l: any): string => l.text.slice(hrefOf(l).length)

async function lines(ui: any): Promise<string[]> {
  const hrefs = (await ui.findAll({ type: 'Link' })).map(hrefOf)
  return (await ui.findAll({ type: 'Text' })).map((t: any) =>
    hrefs.reduce((text: string, href: string) => text.split(href).join(''), t.text))
}

const prJson = (list: object[]) => JSON.stringify(list)

test('task row shows every field with matching evidence', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', {
      status: 'merged',
      workers: [{ agent: 'impl-x', phase: 'implement', status: 'launched', started_ns: 1e15 }],
      pr_number: 12, ship_launch_id: 'L1',
    }, {
      'tasks/t1.done.json': { head_sha: 'abcdef0123', dirty: true },
      'artifacts/t1/ship-L1/ship.json': { head_sha: 'abcdef0123', verdict: 'APPROVE' },
    }),
  })
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  await ui.press({ key: 'tab-done' })
  const text = (await lines(ui)).join('\n')
  for (const part of ['t1', 'merged', 'impl-x', 'abcdef0', '#12', 'ship:APPROVE', 'dirty']) {
    expect(text).toContain(part)
  }
})

test('bare record shows dash defaults', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...task('a', 't1', { status: 'merged', head_sha: null }) })
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  await ui.press({ key: 'tab-done' })
  const text = (await lines(ui)).join('\n')
  expect(text).toMatch(/t1\s+merged\s+-\s*$/)
})

test('older-head evidence is marked and dirty is hidden', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { status: 'merged', ship_launch_id: 'L1' }, {
      'tasks/t1.done.json': { head_sha: '1111111999', dirty: true },
      'artifacts/t1/ship-L1/ship.json': { head_sha: '2222222999', verdict: 'APPROVE' },
    }),
  })
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  await ui.press({ key: 'tab-done' })
  const text = (await lines(ui)).join('\n')
  expect(text).toContain('ship:APPROVE@2222222')
  expect(text).not.toContain('dirty')
})

test('PR rows link tasks, mark drafts, and run one constant argv', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { pr_number: 7, branch: 'x/$(rm -rf);`id`' }),
    ...task('a', 't2', { branch: 'topic/b' }),
  })
  w.gh = { exitCode: 0, stderr: '', stdout: prJson([
    { number: 7, title: 'Linked', isDraft: false, headRefName: 'x', headRefOid: 'aaaaaaa111', statusCheckRollup: [], reviewDecision: 'APPROVED' },
    { number: 8, title: 'By branch', isDraft: false, headRefName: 'topic/b', headRefOid: 'bbbbbbb111', statusCheckRollup: [], reviewDecision: '' },
    { number: 9, title: 'Hand opened', isDraft: true, headRefName: 'lessons', headRefOid: 'ccccccc111', statusCheckRollup: [], reviewDecision: '' },
  ]) }
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  await ui.press({ key: 'tab-prs' })
  const [l7, l8, l9] = (await lines(ui)).filter(t => t.startsWith('#'))
  expect(l7).toMatch(/#7\s+Linked\s+open\s+aaaaaaa\s+none\s+approved\s+t1/)
  expect(l8).toContain('t2')
  expect(l9).toMatch(/draft.*no task/)
  expect(w.runs).toEqual([GH])
})

test('CI cell follows the pr-status rules', () => {
  const run = (status: string, conclusion: string | null) => ({ __typename: 'CheckRun', status, conclusion })
  const ctx = (state: string) => ({ __typename: 'StatusContext', state })
  expect(ciCell([run('COMPLETED', 'FAILURE'), run('IN_PROGRESS', null), ctx('ERROR')])).toBe('fail')
  expect(ciCell([run('QUEUED', null), ctx('PENDING'), ctx('EXPECTED')])).toBe('pending')
  expect(ciCell([run('COMPLETED', 'CANCELLED')])).toBe('fail')
  expect(ciCell([run('COMPLETED', 'TIMED_OUT')])).toBe('fail')
  expect(ciCell([])).toBe('none')
  expect(ciCell([ctx('SUCCESS')])).toBe('pass')
  expect(ciCell([run('COMPLETED', 'SKIPPED'), run('COMPLETED', 'NEUTRAL')])).toBe('none')
  expect(ciCell([run('COMPLETED', 'SUCCESS'), run('COMPLETED', 'SKIPPED')])).toBe('pass')
})

test('gh runs at start and every 300 s, not on the 15 s tick', async ($, on) => {
  const w = newWorld(owner('a'))
  const clock = stub(on, w)
  await boot($, clock)
  expect(w.runs.length).toBe(1)
  await clock.advance(299000)
  expect(w.runs.length).toBe(1)
  await clock.advance(1000)
  expect(w.runs.length).toBe(2)
})

async function prsText(ui: any): Promise<string> {
  await ui.press({ key: 'tab-prs' })
  return (await lines(ui)).join('\n')
}

test('gh rejection shows an unavailable line', async ($, on) => {
  const w = newWorld(owner('a'))
  w.gh = 'reject'
  const clock = stub(on, w)
  await boot($, clock)
  expect(await prsText(await pane($))).toContain('gh unavailable:')
})

test('a gh error before any read says the PR list is unknown', async ($, on) => {
  const w = newWorld(owner('a'))
  w.gh = 'reject'
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  const text = await prsText(ui)
  expect(text).toContain('gh unavailable:')
  expect(text).toContain('PR list unknown')
  expect(text).not.toContain('no open PRs')
  expect((await ui.find({ key: 'tab-prs' })).props.label).toBe('PRs (?)')
})

test('a full page of PRs says the limit is reached', async ($, on) => {
  const w = newWorld(owner('a'))
  const many = (n: number) => prJson(Array.from({ length: n }, (_, i) => ({
    number: i + 1, title: `p${i + 1}`, isDraft: false, headRefName: `b${i + 1}`,
    headRefOid: 'fffffff111', statusCheckRollup: [], reviewDecision: '',
  })))
  w.gh = { exitCode: 0, stderr: '', stdout: many(100) }
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  expect(await prsText(ui)).toContain('showing 100 (limit reached)')
  w.gh = { exitCode: 0, stderr: '', stdout: many(99) }
  await clock.advance(300000)
  expect(await prsText(ui)).not.toContain('limit reached')
})

test('gh non-zero exit keeps the last good list', async ($, on) => {
  const w = newWorld(owner('a'))
  w.gh = { exitCode: 0, stderr: '', stdout: prJson([
    { number: 3, title: 'Kept', isDraft: false, headRefName: 'k', headRefOid: 'ddddddd111', statusCheckRollup: [], reviewDecision: '' },
  ]) }
  const clock = stub(on, w)
  await boot($, clock)
  w.gh = { exitCode: 1, stderr: 'boom\nsecond line', stdout: '' }
  await clock.advance(300000)
  const ui = await pane($)
  const text = await prsText(ui)
  expect(text).toContain('gh unavailable: boom')
  expect(text).not.toContain('second line')
  expect(text).toContain('(as of ')
  expect(text).toContain('#3')
  expect((await ui.find({ key: 'tab-prs' })).props.label).toBe('PRs (1)')
})

test('gh output that is not an array shows an unavailable line', async ($, on) => {
  const w = newWorld(owner('a'))
  w.gh = { exitCode: 0, stderr: '', stdout: '{"a":1}' }
  const clock = stub(on, w)
  await boot($, clock)
  expect(await prsText(await pane($))).toContain('gh unavailable: output is not a JSON array')
})

const archived = (month: string, id: string, status = 'merged') => ({
  [`${ROOT}/a/archive/${month}/tasks/${id}.json`]: JSON.stringify({ task_id: id, status }),
})

test('done tab: initial tab, count, rows, survives a tick', async ($, on) => {
  const w = newWorld({
    ...owner('a'), ...task('a', 'live', { status: 'merged' }), ...archived('2026-09', 'old'),
  })
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  expect((await ui.find({ key: 'tab-done' })).props.label).toBe('done (2)')
  expect((await lines(ui)).join('\n')).not.toContain('old')
  await ui.press({ key: 'tab-done' })
  let text = (await lines(ui)).join('\n')
  expect(text).toContain('live')
  expect(text).toContain('old')
  await clock.advance(15000)
  text = (await lines(ui)).join('\n')
  expect(text).toContain('old')
})

test('done tab: live wins duplicates and a vanished archive file is skipped', async ($, on) => {
  const w = newWorld({
    ...owner('a'), ...task('a', 'dup', { status: 'merged' }), ...archived('2026-09', 'dup'),
  })
  w.ghosts = [`${ROOT}/a/archive/2026-09/tasks/gone.json`]
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  await ui.press({ key: 'tab-done' })
  const rows = (await lines(ui)).filter(t => /merged/.test(t))
  expect(rows.length).toBe(1)
  expect((await lines(ui)).join('\n')).not.toContain('unreadable')
})

test('no lease shows the waiting line', async ($, on) => {
  const w = newWorld({})
  const clock = stub(on, w)
  await boot($, clock)
  expect((await lines(await pane($))).join('\n')).toContain('no herdr lease held by this session yet')
})

test('two leases show ambiguous and no rows', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...owner('b'), ...task('a', 't1') })
  const clock = stub(on, w)
  await boot($, clock)
  const text = (await lines(await pane($))).join('\n')
  expect(text).toContain('ambiguous: this session holds leases for a, b')
  expect(text).not.toContain('t1')
})

test('a lease with no records says no tasks', async ($, on) => {
  const w = newWorld(owner('a'))
  const clock = stub(on, w)
  await boot($, clock)
  expect((await lines(await pane($))).join('\n')).toContain('no tasks')
})

test('a malformed record shows an unreadable row', async ($, on) => {
  const w = newWorld({ ...owner('a'), [`${ROOT}/a/tasks/bad.json`]: '{' })
  const clock = stub(on, w)
  await boot($, clock)
  expect((await lines(await pane($))).join('\n')).toMatch(/bad\.json\s+record unreadable/)
})

const command = ($: any) =>
  $.command.run({ command: 'fleet', args: '', origin: { kind: 'user' }, presentation: { isFullscreen: true } })

test('/fleet opens the pane and summarises', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...task('a', 't1'), ...task('a', 't2', { status: 'merged' }) })
  w.gh = { exitCode: 0, stderr: '', stdout: prJson([
    { number: 1, title: 'a', isDraft: true, headRefName: 'a', headRefOid: 'eeeeeee111', statusCheckRollup: [], reviewDecision: '' },
  ]) }
  const clock = stub(on, w)
  await boot($, clock)
  const result = await command($)
  const [first, ...detail] = result.text.split('\n')
  expect(first).toBe('fleet: 1 active, 1 done, 1 PRs (1 draft)')
  expect(detail.join('\n')).toContain('lease a | gh /repo')
  expect(detail.join('\n')).toContain('t1')
  expect(w.opened).toContain('herdr-fleet')
})

test('/fleet says the PR list is unknown before any read', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...task('a', 't1') })
  w.gh = 'reject'
  const clock = stub(on, w)
  await boot($, clock)
  const result = await command($)
  expect(result.text.split('\n')[0]).toBe('fleet: 1 active, 0 done, PR list unknown; gh unavailable')
  expect(summaryLine(0, 0, null, false)).toBe('fleet: 0 active, 0 done, PR list unknown')
})

test('/fleet during an in-flight gh runs exactly one more, never concurrently', async ($, on) => {
  let release = () => {}
  const w = newWorld(owner('a'))
  w.ghGate = new Promise<void>(resolve => { release = resolve })
  const clock = stub(on, w)
  await boot($, clock)
  expect(w.runs.length).toBe(1)
  const pending = command($)
  await clock.settle()
  w.ghGate = null
  release()
  await pending
  expect(w.runs.length).toBe(2)
  expect(w.maxRunning).toBe(1)
})

const bandProps = {
  hasSurvey: false, isWorking: false, maxRows: 5, bodyColumns: 100,
  scroll: { offset: 0, bodyRows: 5 }, view: {},
}
const band = ($: any, isFullscreen: boolean) =>
  $.ui.mount({
    plugin: 'herdr-fleet', surface: 'terminal', component: 'AbovePrompt',
    props: bandProps, viewport: { columns: 160, rows: 40, isFullscreen },
  })

test('fullscreen auto-opens the pane', async ($, on) => {
  const w = newWorld(owner('a'))
  const clock = stub(on, w)
  await boot($, clock)
  await band($, true)
  expect(w.opened).toContain('herdr-fleet')
})

test('main screen does not open and logs one line', async ($, on) => {
  const w = newWorld(owner('a'))
  const clock = stub(on, w)
  await boot($, clock)
  await band($, false)
  await band($, false)
  expect(w.opened).toEqual([])
  expect(w.logs).toEqual(['herdr-fleet: run /fleet to show the fleet pane'])
})

test('a lease change never draws the old lease archive under the new one', async ($, on) => {
  let release = () => {}
  const w = newWorld({ ...owner('a'), ...archived('2026-09', 'from-a') })
  const clock = stub(on, w)
  await boot($, clock)
  w.readGate = {
    path: `${ROOT}/a/archive/2026-09/tasks/from-a.json`, used: false,
    gate: new Promise<void>(resolve => { release = resolve }),
  }
  await clock.advance(300000)
  delete w.files[`${ROOT}/a/owner.json`]
  await clock.advance(15000)
  Object.assign(w.files, owner('b', 2))
  await clock.advance(15000)
  release()
  await clock.settle()
  const ui = await pane($)
  await ui.press({ key: 'tab-done' })
  const text = (await lines(ui)).join('\n')
  expect(text).toContain(' | read ')
  expect(text).not.toContain('fence')
  expect(text).not.toContain('from-a')
})

test('reload fence: an older read finishing later does not publish', async ($, on) => {
  let release = () => {}
  const w = newWorld({ ...owner('a'), ...archived('2026-09', 'item') })
  const clock = stub(on, w)
  w.readGate = {
    path: `${ROOT}/a/archive/2026-09/tasks/item.json`, used: false,
    gate: new Promise<void>(resolve => { release = resolve }),
  }
  await boot($, clock)
  w.files[`${ROOT}/a/archive/2026-09/tasks/item.json`] = JSON.stringify({ task_id: 'new-item', status: 'merged' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await clock.settle()
  release()
  await clock.settle()
  const ui = await pane($)
  await ui.press({ key: 'tab-done' })
  const rows = await lines(ui)
  expect(rows.some(line => line.startsWith('new item'))).toBe(true)
  expect(rows.some(line => line.startsWith('item '))).toBe(false)
})

test('control characters in PR titles never reach the drawing', async ($, on) => {
  const w = newWorld(owner('a'))
  w.gh = { exitCode: 0, stderr: '', stdout: prJson([
    { number: 5, title: 'evil\u001b[2Jtitle\u0007', isDraft: false, headRefName: 'e', headRefOid: 'fffffff111', statusCheckRollup: [], reviewDecision: '' },
  ]) }
  const clock = stub(on, w)
  await boot($, clock)
  const text = await prsText(await pane($))
  expect(text).toContain('evil?[2Jtitle?')
  expect(text).not.toContain('\u001b')
})

const onePr = (number: number, title: string) => prJson([
  { number, title, isDraft: true, headRefName: `b${number}`, headRefOid: 'aaaaaaa111', statusCheckRollup: [], reviewDecision: '' },
])

test('a lease that appears after boot runs gh once and shows the rows', async ($, on) => {
  const w = newWorld({})
  w.gh = { exitCode: 0, stderr: '', stdout: onePr(3, 'Late') }
  const clock = stub(on, w)
  await boot($, clock)
  expect(w.runs.length).toBe(0)
  Object.assign(w.files, owner('a'), archived('2026-09', 'old'))
  await clock.advance(15000)
  expect(w.runs.length).toBe(1)
  const ui = await pane($)
  expect(await prsText(ui)).toContain('#3')
  await ui.press({ key: 'tab-done' })
  expect((await lines(ui)).join('\n')).toContain('old')
  await clock.advance(15000)
  expect(w.runs.length).toBe(1)
})

test('a gh error stays with its own lease', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...task('a', 'ta') })
  w.gh = 'reject'
  const clock = stub(on, w)
  await boot($, clock)
  delete w.files[`${ROOT}/a/owner.json`]
  Object.assign(w.files, owner('b'))
  w.ghGate = new Promise<void>(() => {})
  await clock.advance(15000)
  const ui = await pane($)
  const text = await prsText(ui)
  expect(text).not.toContain('gh unavailable')
  expect(text).toContain('reading...')
  expect((await ui.find({ key: 'tab-prs' })).props.label).toBe('PRs (?)')
})

test('a failing task refresh shows a message instead of reading', async ($, on) => {
  const w = newWorld(owner('a'))
  w.repoFails = true
  const clock = stub(on, w)
  await boot($, clock)
  const text = (await lines(await pane($))).join('\n')
  expect(text).toContain('read failed: no implementation')
  expect(text).not.toContain('reading...')
})

test('a rejected auto-open is logged once', async ($, on) => {
  const w = newWorld(owner('a'))
  w.openFails = true
  const clock = stub(on, w)
  await boot($, clock)
  await band($, true)
  await band($, true)
  await clock.settle()
  expect(w.opened).toEqual(['herdr-fleet'])
  expect(w.logs).toEqual(['herdr-fleet: could not open the pane; run /fleet'])
})

// The mock clock starts at 0; tests advance it so records can sit in the past.
const NOW = 3600000
const ns = (secAgo: number) => (NOW - secAgo * 1000) * 1e6
const iso = (secAgo: number) => new Date(NOW - secAgo * 1000).toISOString().replace('.000Z', 'Z')
const worker = (over: object = {}) => ({
  agent: 'impl-x',
  phase: 'plan',
  status: 'launched',
  launch_id: 'L1',
  workspace_id: 'w1',
  started_ns: ns(100),
  ...over,
})
const evt = (secAgo: number, event: string, taskId = 't1') => ({
  v: 1,
  ts: iso(secAgo),
  workspace_id: 'w1',
  event,
  task_id: taskId,
  role: 'plan',
})
const events = (...list: object[]) => ({
  [`${ROOT}/a/workspaces/w1.events.jsonl`]: list.map((item) => JSON.stringify(item)).join('\n'),
})
const doneFile = (body: object) => ({
  [`${ROOT}/a/tasks/t1.done.json`]: JSON.stringify(body),
})

async function bootAt($: any, clock: any) {
  await clock.advance(NOW)
  await boot($, clock)
}

test('a date-prefixed task id shows its title', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', '2026-10-19-herdr-fleet-rows', {
      title: 'herdr fleet: Make rows readable',
    }),
    ...task('a', '2026-10-18-old-merged', {
      status: 'merged',
      title: 'Retire the old thing',
    }),
  })
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  let rows = await lines(ui)
  expect(rows.some((line) => line.slice(7).startsWith('herdr fleet: Make rows readable'))).toBe(true)
  expect(rows.join('\n')).not.toContain('2026-10-19-herdr')
  await ui.press({ key: 'tab-done' })
  rows = await lines(ui)
  expect(rows.some((line) => line.startsWith('Retire the old thing'))).toBe(true)
  expect(rows.join('\n')).not.toContain('2026-10-18')
})

test('a record without a title shows its id without the date', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', '2026-10-19-zsh-fix'),
    ...task('a', '2026-10-19-only-ids', { title: 'PROJ-1 #4' }),
    [`${ROOT}/a/tasks/bad.json`]: '{',
  })
  const clock = stub(on, w)
  await boot($, clock)
  const rows = await lines(await pane($))
  expect(rows.some((line) => line.slice(7).startsWith('zsh fix'))).toBe(true)
  expect(rows.some((line) => line.slice(7).startsWith('only-ids'))).toBe(true)
  expect(rows.some((line) => /^\s+bad\.json\s+record unreadable/.test(line))).toBe(true)
})

test('titles match the shared core label cases', () => {
  expect(LABEL_CASES.length).toBeGreaterThan(0)
  for (const { task: record, title } of LABEL_CASES) {
    expect(labelTitle(record)).toBe(title)
  }
})

test('a long title is cut at a word boundary', () => {
  expect(fitTitle('alpha beta gamma delta', 12)).toBe('alpha beta')
  expect(fitTitle('abcdefghijklmnop', 10)).toBe('abcdefghij')
  expect(fitTitle('aaaaaaaa: bbbbbbbbbb', 10)).toBe('aaaaaaaa')
  expect(fitTitle('short', 10)).toBe('short')
})

test('the header keeps the read clock at 60 columns', async ($, on) => {
  const slug = 'github-com-x-dotfiles-63a65e11'
  const w = newWorld({ ...owner(slug, 7), ...task(slug, 't1') })
  w.root = `/a/b/${'r'.repeat(80)}`
  const clock = stub(on, w)
  await boot($, clock)
  const header = (await lines(await pane($, 60)))[0]
  expect(header.length).toBeLessThanOrEqual(60)
  expect(header).toContain('rrrr')
  expect(header).toContain(' | read ')
  expect(header).not.toContain('fence')
  expect(header).toMatch(/read \d\d:\d\d:\d\d$/)
  expect(header).not.toContain(slug)
  expect(header).not.toContain('gh ')
  expect(repoName('/x/dotfiles', slug)).toBe('dotfiles')
  expect(repoName(null, slug)).toBe('github-com-x-dotfiles')
})

test('a plan row shows a live worker cell and no evidence cells', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', {
      head_sha: null,
      workers: [worker({ started_ns: ns(30) })],
    }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const row = (await lines(await pane($))).find((line) => line.slice(7).startsWith('t1'))!
  expect(row).toMatch(/^\s+t1\s+plan running\s+30s\s*$/)
  expect(w.runs).toEqual([GH])
})

test('a stop after launch shows idle and a later reprompt shows working', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { workers: [worker()] }),
    ...events(evt(80, 'stopped')),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  const cell = async () => (await lines(ui)).find((line) => line.slice(7).startsWith('t1'))!
  expect(await cell()).toMatch(/plan idle\s+1m/)

  Object.assign(
    w.files,
    task('a', 't1', {
      workers: [worker({ reprompts: [{ started_ns: ns(60), status: 'delivered' }] })],
    }),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan running/)

  Object.assign(w.files, events(evt(80, 'stopped'), evt(60, 'stopped')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan running/)

  Object.assign(
    w.files,
    task('a', 't1', {
      workers: [
        worker({
          reprompts: [
            { started_ns: ns(60), status: 'delivered' },
            { started_ns: ns(40), status: 'uncertain' },
          ],
        }),
      ],
    }),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan state unknown/)

  Object.assign(w.files, events(evt(60, 'stopped'), evt(30, 'stopped')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan idle/)

  Object.assign(
    w.files,
    task('a', 't1', {
      workers: [worker({ reprompts: [{ started_ns: ns(20), status: 'starting' }] })],
    }),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan state unknown/)

  Object.assign(w.files, events(evt(30, 'stopped'), evt(10, 'review-stopped')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan idle/)
})

test('a blocked event shows blocked', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { workers: [worker()] }),
    ...events(evt(50, 'blocked')),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  const cell = async () => (await lines(ui)).find((line) => line.slice(7).startsWith('t1'))!
  expect(await cell()).toMatch(/blocked\s+50s/)

  Object.assign(w.files, events(evt(50, 'blocked'), evt(40, 'stopped', 'other')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/blocked/)

  Object.assign(w.files, events(evt(50, 'blocked'), evt(50, 'stopped')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan idle/)
})

test('a done record shows done only for the current launch', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { workers: [worker()] }),
    ...doneFile({ launch_id: 'L1', outcome: 'completed', ts: iso(30) }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  const cell = async () => (await lines(ui)).find((line) => line.slice(7).startsWith('t1'))!
  expect(await cell()).toMatch(/plan done\s+30s/)

  Object.assign(w.files, doneFile({ launch_id: 'L1', outcome: 'paused', ts: iso(30) }))
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan paused/)

  Object.assign(w.files, doneFile({ launch_id: 'L0', outcome: 'completed', ts: iso(30) }))
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan running/)

  Object.assign(
    w.files,
    doneFile({ launch_id: 'L1', outcome: 'completed', ts: iso(30) }),
    task('a', 't1', {
      workers: [worker({ reprompts: [{ started_ns: ns(20), status: 'delivered' }] })],
    }),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan running/)

  Object.assign(
    w.files,
    doneFile({ launch_id: 'L1', outcome: 'completed', ts: iso(80) }),
    task('a', 't1', {
      workers: [worker({ reprompts: [{ started_ns: ns(70), status: 'uncertain' }] })],
    }),
    events(evt(69, 'stopped')),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan idle/)
})

test('rows at 60 columns keep the title, status and live cell', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task(
      'a',
      't1',
      {
        pr_number: 12,
        ship_launch_id: 'L1',
        workers: [worker({ phase: 'implement', started_ns: ns(60) })],
      },
      {
        'artifacts/t1/ship-L1/ship.json': {
          head_sha: 'abcdef0123',
          verdict: 'APPROVE',
        },
      },
    ),
    ...task('a', 't2', {
      head_sha: null,
      workers: [worker({ started_ns: ns(60) })],
    }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const rows = (await lines(await pane($, 60))).filter((line) => /^(#12)?\s+t[12]\s/.test(line))
  expect(rows.length).toBe(2)
  expect(rows[0]).toMatch(/^#12\s+t1\s+implement running\s+1m/)
  expect(rows[1]).toMatch(/^\s+t2\s+plan running\s+1m/)
  for (const row of rows) {
    expect(row.length).toBeLessThanOrEqual(60)
    expect(row).not.toContain('abcdef0')
    expect(row).not.toContain('ship:')
  }
})

test('ages format at unit boundaries', () => {
  expect(age(59000)).toBe('59s')
  expect(age(60000)).toBe('1m')
  expect(age(3599000)).toBe('59m')
  expect(age(3600000)).toBe('1h')
  expect(age((47 * 60 + 59) * 60000)).toBe('47h')
  expect(age(48 * 3600000)).toBe('2d')
  expect(age(-1000)).toBe('')
})

test('an unsafe workspace id or a malformed log line reads no state', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { workers: [worker({ workspace_id: '../x' })] }),
    [`${ROOT}/a/archive/2026-09/tasks/old.json`]: JSON.stringify({
      task_id: 'old',
      status: 'merged',
      workers: [worker({ workspace_id: 'w9' })],
    }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  const cell = async () => (await lines(ui)).find((line) => line.slice(7).startsWith('t1'))!
  expect(w.reads.some((path) => path.includes('events.jsonl'))).toBe(false)
  expect(await cell()).toMatch(/plan running/)

  Object.assign(w.files, task('a', 't1', { workers: [worker()] }))
  w.files[`${ROOT}/a/workspaces/w1.events.jsonl`] = [
    '{"v":1,"ts":',
    'not json',
    JSON.stringify(evt(50, 'stopped')),
    '{"v":1,"ts"',
  ].join('\n')
  await clock.advance(15000)
  expect(await cell()).toMatch(/plan idle/)
  expect(w.reads.some((path) => path.endsWith('/workspaces/w1.events.jsonl'))).toBe(true)
  expect(w.reads.some((path) => path.includes('w9'))).toBe(false)
})

test('terminal and non-launched rows show the agent alone or the row status', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 'merged1', { status: 'merged', head_sha: null, workers: [worker()] }),
    ...task('a', 'failed1', {
      workers: [worker({ status: 'launch_failed', started_ns: ns(120) })],
    }),
    ...task('a', 'bare1', { head_sha: null }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  const rows = await lines(ui)
  expect(rows.find((line) => line.slice(7).startsWith('failed1'))).toMatch(/plan launch_failed\s+2m/)
  expect(rows.find((line) => line.slice(7).startsWith('bare1'))).toMatch(/no worker/)
  await ui.press({ key: 'tab-done' })
  const merged = (await lines(ui)).find((line) => line.startsWith('merged1'))!
  expect(merged).toMatch(/merged\s+impl-x\s*$/)
})

test('a mixed list blanks the evidence cells of a plan row', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', {
      status: 'merged',
      pr_number: 12,
      workers: [worker({ phase: 'implement', started_ns: ns(60) })],
    }),
    ...task('a', 't2', {
      status: 'merged',
      head_sha: null,
      workers: [worker({ started_ns: ns(60) })],
    }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($, 160)
  await ui.press({ key: 'tab-done' })
  const rows = await lines(ui)
  const t1 = rows.find((line) => line.startsWith('t1'))!
  const t2 = rows.find((line) => line.startsWith('t2'))!
  expect(t1).toContain('abcdef0')
  expect(t1).toContain('#12')
  expect(t2.trimEnd().endsWith('impl-x')).toBe(true)
})

const VERB = ['python3', '/h/.claude/hooks/herdr_orch_core.py', 'review-deadlines', '--repo-slug', 'a']
const dl = (id: string, launch: string, state: string, remaining: string, deadline = 900, hard = 1500) =>
  `review-deadline task=${id} launch=${launch} remaining=${remaining} state=${state} ` +
  `deadline_secs=${deadline} hard_secs=${hard} basis=contract:c,files:f`
const verbOut = (...list: string[]) => ({ exitCode: 0, stdout: list.join('\n') + '\n', stderr: '' })
const reviewer = (launch = 'R1') => worker({ phase: 'review', launch_id: launch, agent: 'rev-x' })
const rowOf = async (ui: any, id: string) => (await lines(ui)).find(line => line.slice(7).startsWith(id))!
const textOf = async (ui: any, id: string) =>
  (await ui.findAll({ type: 'Text' })).find((t: any) => t.text.slice(7).startsWith(id))

const shipFile = (id: string, launch: string, body: object) => ({
  [`${ROOT}/a/artifacts/${id}/ship-${launch}/ship.json`]: JSON.stringify(body),
})

test('a review row shows running and overdue countdowns from the deadline verb', async ($, on) => {
  const rev = (id: string) => task('a', id, { status: 'review-dispatched', workers: [reviewer()] })
  const w = newWorld({ ...owner('a'), ...rev('t1'), ...rev('t2'), ...rev('t3'), ...rev('t4') })
  w.verb = verbOut(
    dl('t1', 'R1', 'running', '600'),
    dl('t2', 'R1', 'overdue', '120'),
    dl('t3', 'R9', 'running', '600'),
    dl('t4', 'R1', 'unknown', 'unknown'),
    'review-deadline task=t5 launch=R1 remaining=oops state=running deadline_secs=9 hard_secs=9',
  )
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($, 100)
  expect(await rowOf(ui, 't1')).toMatch(/running 10m/)
  expect((await textOf(ui, 't1')).props.color).toBeUndefined()
  expect(await rowOf(ui, 't2')).toMatch(/overdue 2m/)
  expect((await textOf(ui, 't2')).props.color).toBe('red')
  expect(await rowOf(ui, 't3')).toMatch(/review running\s/)
  expect((await textOf(ui, 't3')).props.color).toBeUndefined()
  expect(await rowOf(ui, 't4')).toMatch(/review running\s/)
  expect((await textOf(ui, 't4')).props.color).toBeUndefined()
})

test('a countdown steps to overdue and expired between verb reads', async ($, on) => {
  const rev = (id: string) => task('a', id, { status: 'review-dispatched', workers: [reviewer()] })
  const w = newWorld({ ...owner('a'), ...rev('t1'), ...rev('t2') })
  w.verb = verbOut(dl('t1', 'R1', 'running', '30'), dl('t2', 'R1', 'overdue', '10'))
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($, 100)
  expect(await rowOf(ui, 't1')).toMatch(/running 30s/)
  await clock.advance(45000)
  expect(await rowOf(ui, 't1')).toMatch(/overdue 9m/)
  expect((await textOf(ui, 't1')).props.color).toBe('red')
  expect(await rowOf(ui, 't2')).toMatch(/expired/)
  expect((await textOf(ui, 't2')).props.color).toBe('red')
})

test('the deadline verb runs at start and every 300 s, not on the 15 s tick', async ($, on) => {
  let release = () => {}
  const w = newWorld(owner('a'))
  const clock = stub(on, w)
  await boot($, clock)
  expect(w.verbRuns).toEqual([VERB])
  await clock.advance(299000)
  expect(w.verbRuns.length).toBe(1)
  await clock.advance(1000)
  expect(w.verbRuns.length).toBe(2)

  w.verbGate = new Promise<void>(resolve => { release = resolve })
  await clock.advance(300000)
  expect(w.verbRuns.length).toBe(3)
  const pending = command($)
  await clock.settle()
  w.verbGate = null
  release()
  await pending
  expect(w.verbRuns.length).toBe(4)
  expect(w.verbMax).toBe(1)
})

test('a ship gate row shows co-review and the time since its launch', async ($, on) => {
  const gate = (id: string, status: string) => task('a', id, {
    status: 'reviewed', pr_number: 5, ship_launch_id: 'L1',
    workers: [worker({ phase: 'ship', status, started_ns: ns(720) })],
  })
  const w = newWorld({
    ...owner('a'), ...gate('ta', 'launched'), ...gate('tb', 'failed'), ...gate('tc', 'launched'),
    ...shipFile('tc', 'L1', { launch_id: 'L0', verdict: 'APPROVE', head_sha: 'x' }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($, 100)
  expect(await rowOf(ui, 'ta')).toMatch(/co-review running\s+12m/)
  expect(await rowOf(ui, 'tb')).not.toMatch(/co-review running/)
  expect(await rowOf(ui, 'tc')).toMatch(/co-review running\s+12m/)
  const yellow = (await ui.findAll({ type: 'Text' })).filter((t: any) => t.props.color === 'yellow')
  expect(yellow.length).toBe(0)
})

test('owner tokens match the shared core state cases', () => {
  expect(STATE_CASES.length).toBeGreaterThan(0)
  for (const c of STATE_CASES) {
    const parked = ['merge?', 'gate?', 'open-pr?'].includes(c.token)
    expect(ownerToken(c.task, c.ship)).toBe(parked ? c.token : null)
  }
})

test('a worker blocked event puts the task under your call', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { workers: [worker()] }),
    ...events(evt(50, 'blocked')),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await headers(ui)).toEqual(['Your call (1)'])
  const yellow = (await ui.findAll({ type: 'Text' })).filter((t: any) => t.props.color === 'yellow')
  expect(yellow.length).toBe(1)
  expect(yellow[0].text).toMatch(/^\s+t1\s+blocked\s+50s/)
})

test('a failed deadline read keeps the last countdown', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { status: 'review-dispatched', workers: [reviewer()] }),
  })
  w.verb = verbOut(dl('t1', 'R1', 'running', '600'))
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($, 100)
  expect(await rowOf(ui, 't1')).toMatch(/running 10m/)
  w.verb = { exitCode: 1, stdout: '', stderr: 'boom' }
  await clock.advance(300000)
  expect(w.verbRuns.length).toBe(2)
  expect(await rowOf(ui, 't1')).toMatch(/running 5m/)
})

test('a deadline result for an old lease is never drawn under the new one', async ($, on) => {
  let release = () => {}
  const rev = (slug: string) => task(slug, 'r1', { status: 'review-dispatched', workers: [reviewer()] })
  const w = newWorld({ ...owner('a'), ...rev('a'), ...rev('b') })
  w.verbGate = new Promise<void>(resolve => { release = resolve })
  w.verb = verbOut(dl('r1', 'R1', 'running', '600'))
  const clock = stub(on, w)
  await bootAt($, clock)
  expect(w.verbRuns.length).toBe(1)
  Object.assign(w.files, {
    [`${ROOT}/a/owner.json`]: JSON.stringify({ session_id: 'other' }),
    ...owner('b'),
  })
  await clock.advance(15000)
  w.verbGate = null
  w.verb = OK_VERB
  release()
  await clock.settle()
  await clock.advance(15000)
  const ui = await pane($, 100)
  expect(await rowOf(ui, 'r1')).toMatch(/review running\s/)
})

const HEAD = 'a'.repeat(40)
const OLD = 'b'.repeat(40)
const ghPr = (number: number, over: object = {}) => ({
  number, title: `PR ${number}`, isDraft: false, headRefName: `br${number}`, headRefOid: HEAD,
  statusCheckRollup: [], reviewDecision: '', reviews: [], ...over,
})
const approval = (oid: string | null, secAgo = 60) => ({
  author: { login: 'human' }, state: 'APPROVED', submittedAt: iso(secAgo),
  commit: oid === null ? null : { oid },
})
const withPrs = (w: World, list: object[]) => {
  w.gh = { exitCode: 0, stderr: '', stdout: prJson(list) }
}
// A reviewed task on branch br<n> whose pinned ship gate approved HEAD.
const reviewed = (id: string, n: number, over: object = {}) => ({
  ...task('a', id, {
    status: 'reviewed', pr_number: n, branch: `br${n}`, head_sha: HEAD, review_head_sha: HEAD,
    ship_launch_id: 'S1', title: id, ...over,
  }),
  ...shipFile(id, 'S1', { launch_id: 'S1', verdict: 'APPROVE', head_sha: HEAD }),
})
const ICONS = ['\u{1F514}', '\u{1F9ED}', '\u{1F440}', '\u{1F916}']
const headers = async (ui: any) =>
  (await lines(ui)).filter(t => /^[A-Z][A-Za-z ]+ \(\d+\)$/.test(t.slice(3)) && ICONS.includes(t.slice(0, 2)))
    .map(t => t.slice(3))

test('tasks group under fixed headers in who-acts-next order', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 'ya', { status: 'blocked', title: 'Blocked thing', updated: iso(3000) }),
    ...task('a', 'yb', {
      status: 'pr-open-pending-merge', pr_number: 291, branch: 'br291', head_sha: HEAD,
      title: 'Merge now', updated: iso(7200),
    }),
    ...task('a', 'nd', { status: 'completed', title: 'Review not sent task', updated: iso(100) }),
    ...reviewed('wr', 5, { title: 'Waits on human', updated: iso(600) }),
    ...task('a', 'aw', { title: 'Doing work', workers: [worker({ started_ns: ns(30) })] }),
  })
  withPrs(w, [ghPr(291), ghPr(5, { reviewDecision: 'REVIEW_REQUIRED' })])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await headers(ui)).toEqual([
    'Your call (2)', 'Needs director (1)', 'Waiting on reviewers (1)', 'Agents working (1)',
  ])
  const all = await lines(ui)
  const at = (title: string) => all.findIndex(t => t.slice(7).startsWith(title))
  expect(at('Merge now')).toBeLessThan(at('Blocked thing'))
  expect(all[at('Merge now')]).toMatch(/^#291\s+Merge now\s+ready to merge\s+2h\s*$/)
  expect(all[at('Blocked thing')]).toMatch(/^\s+Blocked thing\s+blocked\s+50m\s*$/)
  expect(all[at('Review not sent task')]).toMatch(/^\s+Review not sent task\s+review not sent\s+1m\s*$/)
  expect(all[at('Waits on human')]).toMatch(/^#5\s+Waits on human\s+needs a human review\s+10m\s*$/)
  expect(all[at('Doing work')]).toMatch(/^\s+Doing work\s+plan running\s+30s\s*$/)
  const yellow = (await ui.findAll({ type: 'Text' })).filter((t: any) => t.props.color === 'yellow')
  expect(yellow.map((t: any) => t.text.slice(7, 20).trim())).toEqual(['Merge now', 'Blocked thing'])

  // An empty group draws no header.
  for (const id of ['ya', 'yb', 'nd', 'wr']) delete w.files[`${ROOT}/a/tasks/${id}.json`]
  await clock.advance(15000)
  expect(await headers(ui)).toEqual(['Agents working (1)'])
})

test('a human change request outranks a ship approve', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...reviewed('t1', 5) })
  withPrs(w, [ghPr(5, { reviewDecision: 'CHANGES_REQUESTED' })])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await headers(ui)).toEqual(['Your call (1)'])
  expect(await rowOf(ui, 't1')).toMatch(/changes requested/)
  expect((await textOf(ui, 't1')).props.color).toBe('yellow')
  expect((await lines(ui)).join('\n')).not.toContain('ready to merge')
  // The ship verdict is APPROVE at head; only the human review blocks.
  expect(shipVerdict({ head_sha: HEAD }, { verdict: 'APPROVE', head_sha: HEAD })).toBe('ship:APPROVE')
})

test('a required review waits on reviewers', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...reviewed('t1', 5) })
  withPrs(w, [ghPr(5, { reviewDecision: 'REVIEW_REQUIRED' })])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await headers(ui)).toEqual(['Waiting on reviewers (1)'])
  expect(await rowOf(ui, 't1')).toMatch(/needs a human review/)
})

test('an approval on an older commit waits on reviewers', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...reviewed('t1', 5), ...reviewed('t2', 6) })
  withPrs(w, [
    ghPr(5, {
      reviewDecision: 'APPROVED', reviews: [approval(OLD)],
      latestReviews: [{ author: { login: 'human' }, state: 'APPROVED', commit: { oid: '' } }],
    }),
    ghPr(6, { reviewDecision: 'APPROVED', reviews: [approval(OLD, 200), approval(HEAD, 100)] }),
  ])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await rowOf(ui, 't1')).toMatch(/approval on older head/)
  expect(await rowOf(ui, 't2')).toMatch(/ready to merge/)
  expect(await headers(ui)).toEqual(['Your call (1)', 'Waiting on reviewers (1)'])
})

test('an empty review decision with a ship approve is ready to merge', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...reviewed('t1', 5) })
  withPrs(w, [ghPr(5, { reviewDecision: '' })])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await headers(ui)).toEqual(['Your call (1)'])
  expect(await rowOf(ui, 't1')).toMatch(/ready to merge/)
})

test('a record without a PR number names the open PR on its branch', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { status: 'reviewed', pr_number: null, branch: 'br8', title: 't1' }),
    ...task('a', 't2', { status: 'reviewed', pr_number: null, branch: 'nowhere', title: 't2' }),
  })
  withPrs(w, [ghPr(8)])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await headers(ui)).toEqual(['Your call (1)', 'Needs director (1)'])
  expect(await rowOf(ui, 't1')).toMatch(/record lacks PR #8/)
  expect(await rowOf(ui, 't2')).toMatch(/open the PR/)
  expect((await textOf(ui, 't2')).props.color).toBe('yellow')
})

test('a moved PR head or a missing gate needs the director', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...reviewed('t1', 5),
    ...task('a', 't2', {
      status: 'reviewed', pr_number: 6, branch: 'br6', head_sha: HEAD, review_head_sha: HEAD, title: 't2',
    }),
  })
  withPrs(w, [
    ghPr(5, { headRefOid: OLD }),
    ghPr(6, { reviewDecision: 'APPROVED', reviews: [approval(HEAD)] }),
  ])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await headers(ui)).toEqual(['Needs director (2)'])
  expect(await rowOf(ui, 't1')).toMatch(/PR head moved/)
  expect(await rowOf(ui, 't2')).toMatch(/approved; no co-review/)
})

test('a task idle over 3 days folds into the parked count', async ($, on) => {
  const day = 86400
  const w = newWorld({
    ...owner('a'),
    ...task('a', 'p1', { status: 'completed', title: 'Idle director', updated: iso(4 * day) }),
    ...task('a', 'c1', { status: 'blocked', title: 'Old question', updated: iso(4 * day) }),
    ...task('a', 'r1', { status: 'completed', title: 'Recent director', updated: iso(2 * day) }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  let all = await lines(ui)
  expect(all).toContain('Parked: 1 idle over 3 days')
  expect(all.some(t => t.includes('Idle director'))).toBe(false)
  expect(all.some(t => t.includes('Old question'))).toBe(true)
  expect(all.some(t => t.includes('Recent director'))).toBe(true)

  // A worker launched 4 days ago with no stop or done record is stale, not working.
  delete w.files[`${ROOT}/a/tasks/p1.json`]
  Object.assign(w.files, task('a', 'p2', { title: 'Silent worker', workers: [worker({ started_ns: ns(4 * day) })] }))
  await clock.advance(15000)
  all = await lines(ui)
  expect(all).toContain('Parked: 1 idle over 3 days')
  expect(all.some(t => t.includes('Silent worker'))).toBe(false)
  expect(await headers(ui)).not.toContain('Agents working (1)')
})

test('without a PR list a merge row never says ready to merge', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { status: 'pr-open-pending-merge', pr_number: 5, title: 't1' }),
  })
  w.gh = 'reject'
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await rowOf(ui, 't1')).toContain('merge? review unknown')
  expect((await lines(ui)).join('\n')).not.toContain('ready to merge')
})

test('a review record outranks a stale review outcome', () => {
  const record = (over: object = {}) => ({
    task_id: 't1', review_head_sha: HEAD, review_outcome: 'changes-requested',
    workers: [{ phase: 'review', launch_id: 'R1' }], ...over,
  })
  const sidecar = (over: object = {}) => ({
    launch_id: 'R1', reviewed_head_sha: HEAD, outcome: 'approved', blocking_count: 0, ts: iso(5), ...over,
  })
  expect(shipVerdict(record(), null, sidecar())).toBe('review:approved')
  expect(shipVerdict(record({ retired_review_launch_ids: ['R0'] }), null, sidecar())).toBe('review:approved')
  expect(shipVerdict(record(), null, null)).toBe('review:changes-requested')
  const stale = [
    shipVerdict(record({ retired_review_launch_ids: ['R1'] }), null, sidecar()),
    shipVerdict(record({ retired_review_launch_ids: 'R1' }), null, sidecar()),
    shipVerdict(record({ workers: [{ phase: 'review', launch_id: 'R2' }] }), null, sidecar()),
    shipVerdict(record(), null, sidecar({ reviewed_head_sha: OLD })),
  ]
  for (const verdict of stale) expect(verdict).toBe('review:changes-requested')
  expect(shipVerdict(record({ review_outcome: undefined }), null, sidecar({ blocking_count: 1 })))
    .toBe('review:changes-requested')
})

test('task rows fit the pane and drop internal detail', async ($, on) => {
  const w = newWorld({
    ...owner('a', 7),
    ...task('a', 'w1', {
      title: 'A long working title that must be clipped to fit the narrow pane', pr_number: 12,
      workers: [worker({ agent: 'impl-secret-launch', phase: 'implement', started_ns: ns(60) })],
    }),
    ...reviewed('w2', 5, { title: 'A long ready to merge title that must be clipped to fit the narrow pane' }),
    ...task('a', 'w3', { status: 'blocked', title: 'Blocked' }),
  })
  w.root = `/a/b/${'r'.repeat(80)}`
  withPrs(w, [ghPr(5)])
  const clock = stub(on, w)
  await bootAt($, clock)
  for (const cols of [60, 109]) {
    const ui = await pane($, cols)
    const all = await lines(ui)
    await ui.unmount()
    expect(all.length).toBeGreaterThan(4)
    for (const line of all) {
      expect(line.length).toBeLessThanOrEqual(cols)
      expect(line).not.toMatch(/\b[0-9a-f]{7}\b/)
      for (const hidden of ['@', 'impl-secret-launch', 'fence']) expect(line).not.toContain(hidden)
    }
    expect(all[0]).toContain('rrrr')
    expect(all[0]).toMatch(/ \| read \d\d:\d\d:\d\d$/)
  }
})

test('pr rows summarise the human review state', () => {
  const list = [
    ghPr(1, { reviewDecision: '' }),
    ghPr(2, { reviewDecision: 'CHANGES_REQUESTED' }),
    ghPr(3, { reviewDecision: 'REVIEW_REQUIRED' }),
    ghPr(4, { reviewDecision: 'APPROVED', reviews: [approval(OLD, 200), approval(HEAD, 100)] }),
    ghPr(5, { reviewDecision: 'APPROVED', reviews: [approval(HEAD, 200), approval(OLD, 100)] }),
    ghPr(6, { reviewDecision: 'APPROVED', reviews: [approval(null)] }),
    ghPr(7, { reviewDecision: 'APPROVED', reviews: [] }),
    ghPr(8, { reviewDecision: 'SOMETHING_NEW' }),
    ghPr(9, { reviewDecision: 'APPROVED', reviews: [approval(HEAD, 100), approval(OLD, 100)] }),
    ghPr(10, { reviewDecision: 'APPROVED', reviews: [approval(OLD, 100), approval(HEAD, 100)] }),
    ghPr(11, { reviews: [{ state: 'COMMENTED', submittedAt: iso(30), commit: { oid: HEAD } }] }),
  ]
  const rows = prRows(prJson(list), [])
  expect(rows.map(r => r.human)).toEqual([
    'none', 'changes', 'required', 'approved', 'approved-old', 'approved-old', 'approved-old',
    'required', 'approved-old', 'approved', 'none',
  ])
  expect(rows[0]).toMatchObject({ branch: 'br1', headOid: HEAD, reviewAt: null })
  expect(rows[3].reviewAt).toBe(NOW - 100000)
  expect(rows[10].reviewAt).toBe(NOW - 30000)
})

const deadline = (launch: string, state: 'running' | 'expired', remaining: number | null) =>
  ({ at: NOW, rows: { t1: { launch, state, remaining, deadlineSecs: 900, hardSecs: 1500 } } })
const pinnedShip = (over: object = {}) => ({ launch_id: 'S1', verdict: 'APPROVE', head_sha: HEAD, ...over })
const shipRecord = (over: object = {}) => ({
  status: 'reviewed', pr_number: 5, branch: 'br5', head_sha: HEAD, review_head_sha: HEAD,
  ship_launch_id: 'S1', ...over,
})
const finishedReview = { launch_id: 'R1', reviewed_head_sha: HEAD, outcome: 'approved', blocking_count: 0, ts: iso(5) }

test('classify gives each wait phrase its group', () => {
  type Opts = { ship?: object | null; sidecar?: object; done?: object; prs?: object[]; complete?: boolean; deadlines?: any }
  const run = (record: object, o: Opts = {}) => classify(
    taskRow('t1.json', { task_id: 't1', status: 'in-progress', ...record }, o.done ?? null,
      (o.ship ?? null) as any, null, o.sidecar ?? null),
    prRows(prJson(o.prs ?? []), []), o.complete ?? true, NOW, o.deadlines ?? null,
  )
  const dispatched = { status: 'review-dispatched', review_head_sha: HEAD, workers: [reviewer()] }
  const cases: Array<[string, ReturnType<typeof run>, string, string]> = [
    ['blocked', run({ status: 'blocked' }), 'Your call', 'blocked'],
    ['review expired', run(dispatched, { deadlines: deadline('R1', 'expired', null) }), 'Needs director', 'review expired'],
    ['review running 10m', run(dispatched, { deadlines: deadline('R1', 'running', 600) }), 'Agents working', 'review running 10m'],
    ['co-review running', run(shipRecord({ workers: [worker({ phase: 'ship', launch_id: 'S1' })] })), 'Agents working', 'co-review running'],
    ['plan running', run({ workers: [worker()] }), 'Agents working', 'plan running'],
    ['implement state unknown', run({
      workers: [worker({ phase: 'implement', reprompts: [{ started_ns: ns(50), status: 'uncertain' }] })],
    }), 'Agents working', 'implement state unknown'],
    ['review not sent', run({ status: 'completed' }), 'Needs director', 'review not sent'],
    ['repair not started', run({ status: 'changes-requested' }), 'Needs director', 'repair not started'],
    ['review approved', run(dispatched, { sidecar: finishedReview }), 'Needs director', 'review approved'],
    ['implement done', run({ workers: [worker({ phase: 'implement' })] }, {
      done: { launch_id: 'L1', outcome: 'completed', ts: iso(30) },
    }), 'Needs director', 'implement done'],
    ['no worker', run({}), 'Needs director', 'no worker'],
    ['implement no signal', run({ workers: [worker({ phase: 'implement', started_ns: ns(4 * 86400) })] }), 'Parked', 'implement no signal'],
    ['plan no signal', run({ workers: [worker({ started_ns: null })] }), 'Needs director', 'plan no signal'],
    ['record unreadable', classify(taskRow('bad.json', null, null, null), [], true, NOW), 'Needs director', 'record unreadable'],
    ['paused', run({ status: 'paused' }), 'Needs director', 'paused'],
    ['merge? review unknown', run({ status: 'pr-open-pending-merge', pr_number: 5 }, { complete: false }), 'Your call', 'merge? review unknown'],
    ['open the PR (incomplete list)', run({ status: 'reviewed' }, { complete: false }), 'Your call', 'open the PR'],
    ['record lacks PR #8', run({ status: 'reviewed', branch: 'br8' }, { prs: [ghPr(8)] }), 'Needs director', 'record lacks PR #8'],
    ['PR is not open', run(shipRecord({ pr_number: 9 })), 'Needs director', 'PR is not open'],
    ['PR head moved', run(shipRecord(), { ship: pinnedShip(), prs: [ghPr(5, { headRefOid: OLD })] }), 'Needs director', 'PR head moved'],
    ['changes requested', run(shipRecord(), { ship: pinnedShip(), prs: [ghPr(5, { reviewDecision: 'CHANGES_REQUESTED' })] }), 'Your call', 'changes requested'],
    ['needs a human review', run(shipRecord(), { ship: pinnedShip(), prs: [ghPr(5, { reviewDecision: 'REVIEW_REQUIRED' })] }), 'Waiting on reviewers', 'needs a human review'],
    ['approval on older head', run(shipRecord(), { ship: pinnedShip(), prs: [ghPr(5, { reviewDecision: 'APPROVED', reviews: [approval(OLD)] })] }), 'Waiting on reviewers', 'approval on older head'],
    ['ready to merge', run(shipRecord(), { ship: pinnedShip(), prs: [ghPr(5)] }), 'Your call', 'ready to merge'],
    ['co-review on old head', run(shipRecord(), { ship: pinnedShip({ head_sha: OLD }), prs: [ghPr(5)] }), 'Needs director', 'co-review on old head'],
    ['co-review: changes', run(shipRecord(), { ship: pinnedShip({ verdict: 'CHANGES' }), prs: [ghPr(5)] }), 'Needs director', 'co-review: changes'],
    ['approved; no co-review', run(shipRecord(), { prs: [ghPr(5, { reviewDecision: 'APPROVED', reviews: [approval(HEAD)] })] }), 'Needs director', 'approved; no co-review'],
    ['co-review not run', run(shipRecord(), { prs: [ghPr(5)] }), 'Needs director', 'co-review not run'],
  ]
  for (const [name, got, group, waits] of cases) {
    expect({ name, group: got.group, waits: got.waits }).toEqual({ name, group, waits })
  }
  expect(cases[1][1].isLate).toBe(true)
  expect(cases[8][1].group).not.toBe('Agents working')
  // A finished review outranks an expired deadline, and is not drawn red.
  const finished = run(dispatched, { sidecar: finishedReview, deadlines: deadline('R1', 'expired', null) })
  expect({ group: finished.group, waits: finished.waits, isLate: finished.isLate })
    .toEqual({ group: 'Needs director', waits: 'review approved', isLate: false })
})

test('the age is the latest activity the panel reads', () => {
  const sidecar = (over: object = {}) => ({ ...finishedReview, ts: iso(300), ...over })
  const build = (record: object = {}, o: { sidecar?: object; ship?: object; done?: object } = {}) =>
    taskRow('t1.json', {
      task_id: 't1', status: 'review-dispatched', review_head_sha: HEAD,
      workers: [reviewer()], ship_launch_id: 'S1', ...record,
    }, o.done ?? null, (o.ship ?? null) as any, null, o.sidecar ?? null)
  const ago = (secs: number) => NOW - secs * 1000
  const start = { workers: [{ ...reviewer(), started_ns: ns(1000) }] }
  expect(build(start).since).toBe(ago(1000))
  const reprompted = { workers: [{ ...start.workers[0], reprompts: [{ started_ns: ns(600), status: 'delivered' }] }] }
  expect(build(reprompted).since).toBe(ago(600))
  const done = { launch_id: 'L0', outcome: 'completed', ts: iso(400) }
  expect(build(reprompted, { done }).since).toBe(ago(400))
  expect(build(reprompted, { done, sidecar: sidecar() }).since).toBe(ago(300))
  // A sidecar that is not current is ignored.
  expect(build(reprompted, { done, sidecar: sidecar({ launch_id: 'R9', ts: iso(10) }) }).since).toBe(ago(400))
  const ship = { launch_id: 'S1', verdict: 'APPROVE', head_sha: HEAD, written_at: iso(200) }
  expect(build(reprompted, { done, sidecar: sidecar(), ship }).since).toBe(ago(200))
  const all = { done, sidecar: sidecar(), ship }
  expect(build({ ...reprompted, updated: iso(100) }, all).since).toBe(ago(100))
  // Unparseable values are skipped.
  expect(build({ ...reprompted, updated: 'not a date' }, { ...all, ship: { ...ship, written_at: 'x' } }).since)
    .toBe(ago(300))
  expect(build({ workers: [], updated: 'x' }).since).toBeNull()
  // A PR review counts when the row matches a PR.
  const row = build({ ...reprompted, updated: iso(100) }, all)
  const prs = prRows(prJson([ghPr(5, { reviews: [{ state: 'COMMENTED', submittedAt: iso(50) }] })]), [])
  expect(classify(row, prs, true, NOW).since).toBe(ago(100))
  const matched = { ...row, branch: 'br5' }
  expect(classify(matched, prs, true, NOW).since).toBe(ago(50))
})

// Queue tab, board links and row links.
const ACCOUNT_A = 'a'.repeat(64)
const ACCOUNT_B = 'b'.repeat(64)
const DASH = '/h/.local/state/dotfiles/dashboard'
const BOARD = `${DASH}/${ACCOUNT_A}/a.html`
const scopeOf = (id: string) => ({ exitCode: 0, stdout: JSON.stringify({ account_id: id }), stderr: '' })
const todoFile = (id: string, title: string) => ({
  [`/repo/.todos/pending/${id}.md`]: `---\ntitle: ${title}\n---\nbody\n`,
})
const queueFile = (ids: unknown[], over: object = {}) => ({
  [`${ROOT}/a/queue.json`]: JSON.stringify({ v: 1, todos: ids, ts: 'x', session: 'sess', fence: 1, ...over }),
})
const boardFiles = () => ({ [BOARD]: '<html>', [`${DASH}/${ACCOUNT_B}/a.html`]: '<html>' })
const hrefs = async (ui: any) => (await ui.findAll({ type: 'Link' })).map(hrefOf)
const tabLines = async (ui: any, key: string) => {
  await ui.press({ key })
  return lines(ui)
}

test('the queue tab lists queued todos with board links', async ($, on) => {
  const w = newWorld({
    ...owner('a'), ...queueFile(['q1', 'q2', 'q3']), ...boardFiles(),
    ...todoFile('q1', 'First thing'), ...todoFile('q2', 'Second thing'),
    ...todoFile('q3', 'Third thing'), ...todoFile('q4', 'Backlog only'),
  })
  w.scope = scopeOf(ACCOUNT_A)
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  const tab = await ui.find({ key: 'tab-queue' })
  expect(tab.props.label).toBe('queue (3)')
  expect(tab.props.hotkey).toBe('4')
  const all = await tabLines(ui, 'tab-queue')
  const rows = all.filter(t => /^\d\./.test(t))
  expect(rows.map(t => t.slice(0, 2))).toEqual(['1.', '2.', '3.'])
  expect(rows[0]).toContain('First thing')
  expect(rows[1]).toContain('Second thing')
  expect(rows[2]).toContain('Third thing')
  expect(await hrefs(ui)).toEqual([
    `file://${BOARD}#todo-q1`, `file://${BOARD}#todo-q2`, `file://${BOARD}#todo-q3`,
  ])
  expect(all.join('\n')).not.toContain('Backlog only')
})

test('an empty or missing queue draws no queue rows', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...todoFile('q1', 'Backlog only') })
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  for (const file of [null, queueFile([])]) {
    delete w.files[`${ROOT}/a/queue.json`]
    if (file) Object.assign(w.files, file)
    await clock.advance(15000)
    const all = await tabLines(ui, 'tab-queue')
    expect(all.join('\n')).toContain('nothing queued')
    expect((await ui.find({ key: 'tab-queue' })).props.label).toBe('queue (0)')
    expect(all.filter(t => /^\d\./.test(t))).toEqual([])
    expect(all.join('\n')).not.toContain('Backlog only')
  }
})

test('a queued todo that started or left pending leaves the queue', async ($, on) => {
  const ids = ['q1', 'q2', 'q3', 'q4', 'q5']
  const w = newWorld({
    ...owner('a'), ...queueFile(ids), ...boardFiles(),
    ...Object.assign({}, ...ids.filter(id => id !== 'q2').map(id => todoFile(id, `Todo ${id}`))),
    ...task('a', 'k1', { status: 'in-progress', todo_id: 'q1' }),
    ...task('a', 'k3', { status: 'merged', todo_id: 'q3' }),
    [`${ROOT}/a/archive/2026-09/tasks/k4.json`]: JSON.stringify({ task_id: 'k4', status: 'merged', todo_id: 'q4' }),
  })
  w.scope = scopeOf(ACCOUNT_A)
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  expect((await ui.find({ key: 'tab-queue' })).props.label).toBe('queue (1)')
  let all = await tabLines(ui, 'tab-queue')
  expect(all.filter(t => /^\d\./.test(t)).map(t => t.slice(0, 2))).toEqual(['1.'])
  expect(all.join('\n')).toContain('Todo q5')
  // The fifth todo starts, then its record leaves tasks/ for the archive between task ticks.
  Object.assign(w.files, task('a', 'k5', { status: 'in-progress', todo_id: 'q5' }))
  await clock.advance(15000)
  expect((await ui.find({ key: 'tab-queue' })).props.label).toBe('queue (0)')
  delete w.files[`${ROOT}/a/tasks/k5.json`]
  w.files[`${ROOT}/a/archive/2026-10/tasks/k5.json`] = JSON.stringify({ task_id: 'k5', status: 'merged', todo_id: 'q5' })
  await clock.advance(15000)
  all = await lines(ui)
  expect(all.join('\n')).toContain('nothing queued')
})

test('a malformed queue says it is unreadable', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...todoFile('q1', 'One'), ...todoFile('x', 'X') })
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  const eleven = Array.from({ length: 11 }, (_, i) => `q${i}`)
  const bad = [
    '{', JSON.stringify({ v: 2, todos: ['q1'] }), JSON.stringify({ v: 1, todos: ['q1', 7] }),
    JSON.stringify({ v: 1, todos: ['../x'] }), JSON.stringify({ v: 1, todos: eleven }),
  ]
  for (const text of bad) {
    w.files[`${ROOT}/a/queue.json`] = text
    w.reads.length = 0
    await clock.advance(15000)
    const all = await tabLines(ui, 'tab-queue')
    expect(all.join('\n')).toContain('queue unreadable')
    expect(all.filter(t => /^\d\./.test(t))).toEqual([])
    expect(w.reads.filter(path => path.includes('/.todos/'))).toEqual([])
  }
})

test('the board link uses the account board file for the lease', async ($, on) => {
  const w = newWorld({
    ...owner('a'), ...queueFile(['q1']), ...boardFiles(), ...todoFile('q1', 'One'),
  })
  w.scope = scopeOf(ACCOUNT_A)
  const clock = stub(on, w)
  await boot($, clock)
  const ui = await pane($)
  await ui.press({ key: 'tab-queue' })
  expect(await hrefs(ui)).toEqual([`file://${BOARD}#todo-q1`])
  const first = w.scopeEvents[0]
  expect(first.argv.slice(2)).toEqual(['account-scope', '--cwd', '/repo', '--runtime', 'claude'])
  expect(first.argv[1]).toBe('/h/.claude/skills/lib/workflow_context.py')
  expect(typeof first.init.timeoutMs).toBe('number')

  w.env.HERDR_PERSONAL = '1'
  await clock.advance(300000)
  expect(w.scopeEvents[w.scopeEvents.length - 1].argv).toContain('--personal')

  // An override directory wins and runs no Python.
  const runs = w.scopeEvents.length
  w.env.TODOS_DASHBOARD_DIR = '/d/'
  w.files['/d/a.html'] = '<html>'
  await clock.advance(300000)
  expect(w.scopeEvents.length).toBe(runs)
  expect(await hrefs(ui)).toEqual(['file:///d/a.html#todo-q1'])

  // Each failure draws the titles with no Link.
  delete w.env.TODOS_DASHBOARD_DIR
  const failures: GhAnswer[] = [
    { exitCode: 1, stdout: '', stderr: 'boom' }, 'reject', scopeOf('not-hex'), scopeOf('c'.repeat(64)),
  ]
  for (const answer of failures) {
    w.scope = answer
    await clock.advance(300000)
    expect(await hrefs(ui)).toEqual([])
    expect((await lines(ui)).join('\n')).toContain('One')
  }
  // A listed account directory without the board file is no board either.
  w.scope = scopeOf(ACCOUNT_A)
  delete w.files[BOARD]
  await clock.advance(300000)
  expect(await hrefs(ui)).toEqual([])
})

const PR_URL = (n: number) => `https://github.com/o/r/pull/${n}`

test('task rows link the title to the board and the PR to GitHub', async ($, on) => {
  const w = newWorld({
    ...owner('a'), ...boardFiles(), ...todoFile('q1', 'Todo one'),
    ...task('a', 't1', { title: 'Todo task', todo_id: 'q1', pr_number: 5, workers: [worker()] }),
    ...task('a', 't2', { title: 'Record url', pr_number: 6, pr_url: PR_URL(6), workers: [worker()] }),
    ...task('a', 't3', { title: 'Unsafe url', pr_number: 7, pr_url: 'javascript:alert(1)', workers: [worker()] }),
  })
  w.scope = scopeOf(ACCOUNT_A)
  withPrs(w, [ghPr(5, { url: 'https://github.com/o/r/pull/5' })])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  const links = await ui.findAll({ type: 'Link' })
  const byText = Object.fromEntries(links.map((l: any) => [labelOf(l), hrefOf(l)]))
  expect(byText['Todo task']).toBe(`file://${BOARD}#todo-q1`)
  expect(byText['#5']).toBe(PR_URL(5))
  expect(byText['#6']).toBe(PR_URL(6))
  expect(byText['#7']).toBeUndefined()
  expect(byText['Record url']).toBeUndefined()
  expect((await lines(ui)).join('\n')).toContain('#7')
})

test('jira keys link to JIRA_URL and stay plain when it is unset', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 'BESS-3832', { kind: 'jira', title: 'Jira task', workers: [worker()] }),
    ...task('a', 't2', { jira_key: 'BESS-3835', title: 'Keyed task', workers: [worker()] }),
  })
  w.env.JIRA_URL = 'https://jira.example.com/'
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  expect(await hrefs(ui)).toEqual([
    'https://jira.example.com/browse/BESS-3832', 'https://jira.example.com/browse/BESS-3835',
  ].sort())
  const text = (await lines(ui)).join('\n')
  expect(text).toContain('BESS-3832')
  expect(text).toContain('BESS-3835')

  delete w.env.JIRA_URL
  await clock.advance(15000)
  expect(await hrefs(ui)).toEqual([])
  expect((await lines(ui)).join('\n')).toContain('BESS-3832')
  w.env.JIRA_URL = 'ftp://x'
  await clock.advance(15000)
  expect(await hrefs(ui)).toEqual([])
  expect((await lines(ui)).join('\n')).toContain('BESS-3835')

  // With no key anywhere the key cell is gone and the title keeps its offset.
  for (const id of ['BESS-3832', 't2']) delete w.files[`${ROOT}/a/tasks/${id}.json`]
  Object.assign(w.files, task('a', 't3', { title: 'Plain task', pr_number: 3, workers: [worker()] }))
  await clock.advance(15000)
  expect(await rowOf(ui, 'Plain task')).toMatch(/^#3\s{5}Plain task/)
})

test('PR and done tab rows link PR numbers and Jira keys', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { title: 'Jira task', jira_key: 'BESS-3835', pr_number: 5, workers: [worker()] }),
    ...task('a', 'd1', { status: 'merged', pr_number: 9, pr_url: PR_URL(9), head_sha: 'abcdef0123' }),
  })
  w.env.JIRA_URL = 'https://jira.example.com'
  withPrs(w, [ghPr(5, { url: PR_URL(5) })])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  await ui.press({ key: 'tab-prs' })
  const byText = async () =>
    Object.fromEntries((await ui.findAll({ type: 'Link' })).map((l: any) => [labelOf(l), hrefOf(l)]))
  const prs = await byText()
  expect(prs['#5']).toBe(PR_URL(5))
  expect(prs.t1).toBe('https://jira.example.com/browse/BESS-3835')
  await ui.press({ key: 'tab-done' })
  const done = await byText()
  expect(done['#9']).toBe(PR_URL(9))
})

test('each group header carries its status icon', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 'ya', { status: 'blocked', title: 'Blocked thing', updated: iso(3000) }),
    ...task('a', 'nd', { status: 'completed', title: 'Review not sent task', updated: iso(100) }),
    ...reviewed('wr', 5, { title: 'Waits on human', updated: iso(600) }),
    ...task('a', 'aw', { title: 'Doing work', workers: [worker({ started_ns: ns(30) })] }),
  })
  withPrs(w, [ghPr(5, { reviewDecision: 'REVIEW_REQUIRED' })])
  const clock = stub(on, w)
  await bootAt($, clock)
  const ui = await pane($)
  const all = await lines(ui)
  const shown = all.filter(t => /\(\d+\)$/.test(t) && !t.startsWith('queue'))
  expect(shown).toEqual([
    '\u{1F514} Your call (1)',
    '\u{1F9ED} Needs director (1)',
    '\u{1F440} Waiting on reviewers (1)',
    '\u{1F916} Agents working (1)',
  ])
})

test('queue and linked rows fit the pane', async ($, on) => {
  const long = 'A very long task title that goes on and on past any sensible pane width'
  const w = newWorld({
    ...owner('a'), ...boardFiles(), ...queueFile(['q1', 'q2', 'q3']),
    ...todoFile('q1', long), ...todoFile('q2', long), ...todoFile('q3', long),
    ...task('a', 'BESS-3832', {
      kind: 'jira', title: long, todo_id: 'q9', pr_number: 12, branch: 'secret/branch-name',
      workers: [worker()],
    }),
    ...task('a', 't2', {
      title: long, jira_key: 'BESS-3835', pr_number: 13, branch: 'secret/other', workers: [worker()],
    }),
  })
  w.scope = scopeOf(ACCOUNT_A)
  w.env.JIRA_URL = 'https://jira.example.com'
  withPrs(w, [ghPr(12), ghPr(13)])
  const clock = stub(on, w)
  await bootAt($, clock)
  for (const cols of [60, 109]) {
    const ui = await pane($, cols)
    await ui.press({ key: 'tab-tasks' })
    const tasks = await lines(ui)
    expect(tasks.some(t => t.includes('BESS-3832'))).toBe(true)
    const queue = await tabLines(ui, 'tab-queue')
    expect(queue.filter(t => /^\d\./.test(t)).length).toBe(3)
    for (const line of [...tasks, ...queue]) expect(line.length).toBeLessThanOrEqual(cols)
    expect([...tasks, ...queue].join('\n')).not.toContain('secret/')
    await ui.unmount()
  }
})
