import { expect, mock, test } from 'claude-code/testing'

import { ciCell } from './fleet'

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
  openFails: boolean
}

function newWorld(files: Record<string, string> = {}): World {
  return {
    files, ghosts: [], gh: OK, ghGate: null, readGate: null,
    runs: [], running: 0, maxRunning: 0, opened: [], logs: [], repoFails: false, openFails: false,
  }
}

function owner(slug: string): Record<string, string> {
  return { [`${ROOT}/${slug}/owner.json`]: JSON.stringify({ session_id: 'sess' }) }
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
    return { value: { root: '/repo', remote: null } }
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
      workers: [{ agent: 'impl-x', phase: 'implement' }],
      pr_number: 12, ship_launch_id: 'L1',
    }, {
      'tasks/t1.done.json': { head_sha: 'abcdef0123', dirty: true },
      'artifacts/t1/ship-L1/ship.json': { head_sha: 'abcdef0123', verdict: 'APPROVE' },
    }),
  })
  const clock = stub(on, w)
  await boot($, clock)
  const text = (await lines(await pane($))).join('\n')
  for (const part of ['t1', 'in-progress', 'impl-x', 'implement', 'abcdef0', '#12', 'ship:APPROVE', 'dirty']) {
    expect(text).toContain(part)
  }
})

test('bare record shows dash defaults', async ($, on) => {
  const w = newWorld({ ...owner('a'), ...task('a', 't1', { head_sha: null }) })
  const clock = stub(on, w)
  await boot($, clock)
  const text = (await lines(await pane($))).join('\n')
  expect(text).toMatch(/t1\s+in-progress\s+-\s+-\s+-\s+-\s+-/)
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
  expect(result.text).toBe('fleet: 1 active, 1 done, 1 PRs (1 draft)')
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
  Object.assign(w.files, owner('b'))
  await clock.advance(15000)
  release()
  await clock.settle()
  const ui = await pane($)
  await ui.press({ key: 'tab-done' })
  const text = (await lines(ui)).join('\n')
  expect(text).toContain('lease b')
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
  expect(rows.some(line => line.startsWith('new-item'))).toBe(true)
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
