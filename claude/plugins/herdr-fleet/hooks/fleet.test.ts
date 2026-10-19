import { expect, mock, test } from 'claude-code/testing'

import { age, ciCell, fitTitle, labelTitle, repoName } from './fleet'
import { LABEL_CASES } from './label-cases'

const ROOT = '/h/.claude/herdr-orch'
const GH = ['gh', 'pr', 'list', '--state', 'open', '--json',
  'number,title,isDraft,headRefName,headRefOid,statusCheckRollup,reviewDecision',
  '--limit', '100']
const OK = { exitCode: 0, stdout: '[]', stderr: '' }

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
}

function newWorld(files: Record<string, string> = {}): World {
  return {
    files, ghosts: [], gh: OK, ghGate: null, readGate: null,
    runs: [], running: 0, maxRunning: 0, opened: [], logs: [], repoFails: false, openFails: false,
    root: '/repo', reads: [],
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
  on('env.get', (_$: any, e: any) => ({ value: e.name === 'HOME' ? '/h' : undefined }))
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

async function lines(ui: any): Promise<string[]> {
  return (await ui.findAll({ type: 'Text' })).map((t: any) => t.text)
}

const prJson = (list: object[]) => JSON.stringify(list)

test('task row shows every field with matching evidence', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', {
      workers: [{ agent: 'impl-x', phase: 'implement', status: 'launched', started_ns: 1e15 }],
      pr_number: 12, ship_launch_id: 'L1',
    }, {
      'tasks/t1.done.json': { head_sha: 'abcdef0123', dirty: true },
      'artifacts/t1/ship-L1/ship.json': { head_sha: 'abcdef0123', verdict: 'APPROVE' },
    }),
  })
  const clock = stub(on, w)
  await boot($, clock)
  const text = (await lines(await pane($))).join('\n')
  for (const part of ['t1', 'in-progress', 'impl-x', 'working', 'abcdef0', '#12', 'ship:APPROVE', 'dirty']) {
    expect(text).toContain(part)
  }
})

test('bare record shows dash defaults', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...task('a', 't1', { head_sha: null }) })
  const clock = stub(on, w)
  await boot($, clock)
  const text = (await lines(await pane($))).join('\n')
  expect(text).toMatch(/t1\s+in-progress\s+-\s*$/)
})

test('older-head evidence is marked and dirty is hidden', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', { ship_launch_id: 'L1' }, {
      'tasks/t1.done.json': { head_sha: '1111111999', dirty: true },
      'artifacts/t1/ship-L1/ship.json': { head_sha: '2222222999', verdict: 'APPROVE' },
    }),
  })
  const clock = stub(on, w)
  await boot($, clock)
  const text = (await lines(await pane($))).join('\n')
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

test('gh non-zero exit keeps the last good list', async ($, on) => {
  const w = newWorld(owner('a'))
  w.gh = { exitCode: 0, stderr: '', stdout: prJson([
    { number: 3, title: 'Kept', isDraft: false, headRefName: 'k', headRefOid: 'ddddddd111', statusCheckRollup: [], reviewDecision: '' },
  ]) }
  const clock = stub(on, w)
  await boot($, clock)
  w.gh = { exitCode: 1, stderr: 'boom\nsecond line', stdout: '' }
  await clock.advance(300000)
  const text = await prsText(await pane($))
  expect(text).toContain('gh unavailable: boom')
  expect(text).not.toContain('second line')
  expect(text).toContain('#3')
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
  expect((await lines(await pane($))).join('\n')).toMatch(/bad\.json\s+unreadable/)
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
  expect(text).toContain('fence 2')
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
  const text = await prsText(await pane($))
  expect(text).not.toContain('gh unavailable')
  expect(text).toContain('reading...')
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
  expect(rows.some((line) => line.startsWith('herdr fleet: Make rows readable'))).toBe(true)
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
  expect(rows.some((line) => line.startsWith('zsh fix'))).toBe(true)
  expect(rows.some((line) => line.startsWith('only-ids'))).toBe(true)
  expect(rows.some((line) => /^bad\.json\s+unreadable/.test(line))).toBe(true)
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
  expect(header).toContain(' | fence 7 | read ')
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
  const row = (await lines(await pane($))).find((line) => line.startsWith('t1'))!
  expect(row).toMatch(/^t1\s+in-progress\s+impl-x working 30s\s*$/)
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
  const cell = async () => (await lines(ui)).find((line) => line.startsWith('t1'))!
  expect(await cell()).toMatch(/impl-x idle 1m/)

  Object.assign(
    w.files,
    task('a', 't1', {
      workers: [worker({ reprompts: [{ started_ns: ns(60), status: 'delivered' }] })],
    }),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x working/)

  Object.assign(w.files, events(evt(80, 'stopped'), evt(60, 'stopped')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x working/)

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
  expect(await cell()).toMatch(/impl-x unknown/)

  Object.assign(w.files, events(evt(60, 'stopped'), evt(30, 'stopped')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x idle/)

  Object.assign(
    w.files,
    task('a', 't1', {
      workers: [worker({ reprompts: [{ started_ns: ns(20), status: 'starting' }] })],
    }),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x unknown/)

  Object.assign(w.files, events(evt(30, 'stopped'), evt(10, 'review-stopped')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x idle/)
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
  const cell = async () => (await lines(ui)).find((line) => line.startsWith('t1'))!
  expect(await cell()).toMatch(/impl-x blocked 50s/)

  Object.assign(w.files, events(evt(50, 'blocked'), evt(40, 'stopped', 'other')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x blocked/)

  Object.assign(w.files, events(evt(50, 'blocked'), evt(50, 'stopped')))
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x idle/)
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
  const cell = async () => (await lines(ui)).find((line) => line.startsWith('t1'))!
  expect(await cell()).toMatch(/impl-x done 30s/)

  Object.assign(w.files, doneFile({ launch_id: 'L1', outcome: 'paused', ts: iso(30) }))
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x paused/)

  Object.assign(w.files, doneFile({ launch_id: 'L0', outcome: 'completed', ts: iso(30) }))
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x working/)

  Object.assign(
    w.files,
    doneFile({ launch_id: 'L1', outcome: 'completed', ts: iso(30) }),
    task('a', 't1', {
      workers: [worker({ reprompts: [{ started_ns: ns(20), status: 'delivered' }] })],
    }),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x working/)

  Object.assign(
    w.files,
    doneFile({ launch_id: 'L1', outcome: 'completed', ts: iso(80) }),
    task('a', 't1', {
      workers: [worker({ reprompts: [{ started_ns: ns(70), status: 'uncertain' }] })],
    }),
    events(evt(69, 'stopped')),
  )
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x idle/)
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
  const rows = (await lines(await pane($, 60))).filter((line) => /^t[12]\s/.test(line))
  expect(rows.length).toBe(2)
  for (const row of rows) {
    expect(row).toMatch(/^t[12]\s+in-progress\s+impl-x working 1m/)
    expect(row).not.toContain('#12')
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
  const cell = async () => (await lines(ui)).find((line) => line.startsWith('t1'))!
  expect(w.reads.some((path) => path.includes('events.jsonl'))).toBe(false)
  expect(await cell()).toMatch(/impl-x working/)

  Object.assign(w.files, task('a', 't1', { workers: [worker()] }))
  w.files[`${ROOT}/a/workspaces/w1.events.jsonl`] = [
    '{"v":1,"ts":',
    'not json',
    JSON.stringify(evt(50, 'stopped')),
    '{"v":1,"ts"',
  ].join('\n')
  await clock.advance(15000)
  expect(await cell()).toMatch(/impl-x idle/)
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
  expect(rows.find((line) => line.startsWith('failed1'))).toMatch(/impl-x launch_failed 2m/)
  expect(rows.find((line) => line.startsWith('bare1'))).toMatch(/in-progress\s+-\s*$/)
  await ui.press({ key: 'tab-done' })
  const merged = (await lines(ui)).find((line) => line.startsWith('merged1'))!
  expect(merged).toMatch(/merged\s+impl-x\s*$/)
})

test('a mixed list blanks the evidence cells of a plan row', async ($, on) => {
  const w = newWorld({
    ...owner('a'),
    ...task('a', 't1', {
      pr_number: 12,
      workers: [worker({ phase: 'implement', started_ns: ns(60) })],
    }),
    ...task('a', 't2', {
      head_sha: null,
      workers: [worker({ started_ns: ns(60) })],
    }),
  })
  const clock = stub(on, w)
  await bootAt($, clock)
  const rows = await lines(await pane($, 160))
  const t1 = rows.find((line) => line.startsWith('t1'))!
  const t2 = rows.find((line) => line.startsWith('t2'))!
  expect(t1).toContain('abcdef0')
  expect(t1).toContain('#12')
  expect(t2.trimEnd().endsWith('working 1m')).toBe(true)
})
