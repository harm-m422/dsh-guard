#!/usr/bin/env node
/**
 * dsh-guard 的测试。没有第三方依赖，跑 `node test.mjs` 就行。
 *
 * 每条用例都在自己的临时 DSH_HOME 里跑，绝不碰真实的 profile：这个工具会改
 * cordis.patch.yml、会重启 harness，测试必须先在沙盒里证明它只改它该改的。
 */
import { spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const GUARD = fileURLToPath(new URL('./dsh-guard', import.meta.url))
const results = []

function pass(name, detail) { results.push({ ok: true, name, detail }) }
function fail(name, detail) { results.push({ ok: false, name, detail }) }
function check(name, condition, detail) {
  if (condition) pass(name, detail)
  else fail(name, detail)
}

/** 建一个可丢弃的 DSH_HOME。 */
function sandbox() {
  const root = mkdtempSync(join(tmpdir(), 'dsh-guard-test-'))
  const home = join(root, 'home')
  const profile = join(root, 'home', 'profiles', 'web')
  mkdirSync(profile, { recursive: true })
  mkdirSync(join(home, 'guard-snapshots'), { recursive: true })
  return { root, home, profile, patch: join(profile, 'cordis.patch.yml') }
}

function plugin(box, name, { broken = false, version = '1.0.0' } = {}) {
  const dir = join(box.profile, 'node_modules', name)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'package.json'), JSON.stringify({ name, version, main: 'index.js' }))
  if (!broken) writeFileSync(join(dir, 'index.js'), 'export default {}\n')
  return dir
}

function run(box, args, env = {}) {
  const out = spawnSync('bash', [GUARD, ...args], {
    env: {
      PATH: process.env.PATH,
      HOME: env.HOME ?? box.home,
      DSH_HOME: box.home,
      DSH_PROFILE_DIR: box.profile,
      DSH_GUARD_LOG: join(box.home, 'guard.log'),
      DSH_GUARD_SNAPSHOTS: join(box.home, 'guard-snapshots'),
      DSH_GUARD_NO_UI: '1',
      ...env
    },
    encoding: 'utf8',
    timeout: 120000
  })
  return { code: out.status, out: (out.stdout ?? '') + (out.stderr ?? '') }
}

function snapshots(box) {
  const base = join(box.home, 'guard-snapshots')
  if (!existsSync(base)) return []
  return readdirSync(base).filter((n) => n !== 'trash' && n !== 'last-good' && !n.startsWith('.')).sort()
}

function snapText(box, name) {
  const file = join(box.home, 'guard-snapshots', name, 'cordis.patch.yml')
  return existsSync(file) ? readFileSync(file, 'utf8') : null
}

const PATCH_BASE = `# 用户自己的注释，必须原样保留
- id: ui-settings-general
  name: "@deepseek-ai/dsh-client-ui-settings-general"
- insert:
    - id: demo-plugin
      name: demo-plugin
- insert:
    - id: core-thing
      name: core-thing
`

function writePatch(box, text = PATCH_BASE) {
  writeFileSync(box.patch, text)
}

// ── 1. dsh 可执行文件解析：只有一套探测 ────────────────────────────────────
{
  const box = sandbox()
  const bin = join(box.home, '.dsh-cli', '9.9.9', 'node_modules', '.bin')
  mkdirSync(bin, { recursive: true })
  writeFileSync(join(bin, 'dsh'), '#!/bin/sh\nexit 0\n')
  chmodSync(join(bin, 'dsh'), 0o755)
  const r = run(box, ['--web-cmd'])
  check('解析：扫最新的 .dsh-cli 版本', r.code === 0 && r.out.includes('9.9.9'), r.out.trim())
}

{
  const box = sandbox()
  const r = run(box, ['--web-cmd'], { DSH_WEB_CMD: 'my-custom-web --flag' })
  check('解析：DSH_WEB_CMD 优先', r.code === 0 && r.out.trim() === 'my-custom-web --flag', r.out.trim())
}

{
  const box = sandbox()
  const r = run(box, ['--web-cmd'])
  check('解析：都找不到时回落到 dsh web', r.code === 0 && r.out.trim() === 'dsh web', r.out.trim())
}

// ── 2. 体检 ───────────────────────────────────────────────────────────────
{
  const box = sandbox()
  plugin(box, 'demo-plugin')
  writePatch(box)
  const r = run(box, ['--check'])
  check('体检：能加载的插件报「可加载」', r.out.includes('可加载'), r.out.split('\n').find((l) => l.includes('demo-plugin')))
}

{
  const box = sandbox()
  plugin(box, 'demo-plugin', { broken: true })
  writePatch(box)
  const r = run(box, ['--check'])
  check('体检：缺入口要点出来', r.out.includes('缺入口'), r.out.split('\n').find((l) => l.includes('demo-plugin')))
}

// ── 3. 事后自愈：快照轮转（A） ────────────────────────────────────────────
{
  const box = sandbox()
  plugin(box, 'demo-plugin')
  writePatch(box)
  const log = join(box.home, 'boot.log')
  writeFileSync(log, 'boot: demo-plugin did not activate\n')

  const r = run(box, ['--heal-log', log])
  const text = readFileSync(box.patch, 'utf8')
  check('自愈：停用了被点名的插件', r.code === 0 && /disabled:\s*true/.test(text), r.out.trim().split('\n').slice(-2).join(' '))
  check('自愈：注释还在', text.includes('# 用户自己的注释，必须原样保留'))
  check('自愈：没有再写固定 .bak-guard', !existsSync(box.patch + '.bak-guard'), 'cordis.patch.yml.bak-guard')

  const snaps = snapshots(box)
  check('快照：生成了带时间戳的一份', snaps.length === 1, JSON.stringify(snaps))
  const firstName = snaps[0]
  const first = firstName === undefined ? '' : snapText(box, firstName)
  check('快照：存的是改动前的原文', first !== null && first.includes('demo-plugin') && !/disabled:\s*true/.test(first), first === null ? 'null' : 'ok')

  // 第二次自愈：关键断言 —— 第一份原文不能被覆盖
  writeFileSync(log, 'boot: core-thing did not activate\n')
  const r2 = run(box, ['--heal-log', log])
  const snaps2 = snapshots(box)
  const firstStill = firstName === undefined ? '' : snapText(box, firstName)
  check('快照：连着自愈两次得到两份', r2.code === 0 && snaps2.length === 2, JSON.stringify(snaps2))
  check('快照：第一次的原文没被覆盖（A 的核心）', firstStill === first, firstStill === first ? '同一份字节' : '被覆盖了')
  check('快照：带原因文件', existsSync(join(box.home, 'guard-snapshots', firstName ?? '', 'REASON')), firstName)
}

// ── 4. 快照只留最近 N 份，旧的进 trash/（不删） ───────────────────────────
{
  const box = sandbox()
  plugin(box, 'demo-plugin')
  writePatch(box)
  const log = join(box.home, 'boot.log')
  for (let i = 0; i < 8; i += 1) {
    writeFileSync(log, 'boot: demo-plugin did not activate\n')
    run(box, ['--heal-log', log])
  }
  const snaps = snapshots(box)
  const trashDir = join(box.home, 'guard-snapshots', 'trash')
  const trash = existsSync(trashDir) ? readdirSync(trashDir).length : 0
  check('快照：最多留 5 份', snaps.length === 5, '留了 ' + snaps.length + ' 份')
  check('快照：被挤出去的进了 trash/', trash > 0, 'trash 里 ' + trash + ' 份')
}

// ── 5. 不改坏 patch：重复 disabled、幂等 ───────────────────────────────────
{
  const box = sandbox()
  plugin(box, 'demo-plugin')
  writePatch(box, PATCH_BASE.replace('    - id: demo-plugin\n      name: demo-plugin\n', '    - id: demo-plugin\n      name: demo-plugin\n      disabled: true\n'))
  const log = join(box.home, 'boot.log')
  writeFileSync(log, 'boot: demo-plugin did not activate\n')
  const r = run(box, ['--heal-log', log])
  const text = readFileSync(box.patch, 'utf8')
  const count = (text.match(/disabled:\s*true/g) ?? []).length
  check('幂等：已禁用的不会插第二行', count === 1, 'disabled 出现 ' + count + ' 次')
  check('幂等：没有改坏的迹象', r.code === 0, r.out.trim().slice(0, 80))
}

// ── 6. 干净启动只停第三方，不碰核心 id 覆盖 ───────────────────────────────
{
  const box = sandbox()
  plugin(box, 'demo-plugin')
  writePatch(box)
  const r = run(box, ['--clean-start'])
  const text = existsSync(box.patch) ? readFileSync(box.patch, 'utf8') : ''
  function rowDisabled(body, id) {
    const lines = body.split('\n')
    const at = lines.findIndex((line) => line.trim() === '- id: ' + id)
    if (at < 0) return false
    for (let i = at + 1; i < lines.length; i += 1) {
      if (/^\s*-\s/.test(lines[i])) break
      if (/^\s*disabled:\s*true\s*$/.test(lines[i])) return true
    }
    return false
  }
  const demoOff = rowDisabled(text, 'demo-plugin')
  const coreOff = rowDisabled(text, 'core-thing')
  check('干净启动：第三方被停用', r.code === 0 && demoOff, demoOff ? 'demo-plugin disabled' : '没停')
  check('干净启动：核心 id 覆盖不动', !coreOff, coreOff ? 'core-thing 被误停' : 'core-thing 未被碰')
  check('干净启动：也留了快照', snapshots(box).length === 1, JSON.stringify(snapshots(box)))
}

// ── 7. 「起来了」不等于「好了」（B） ──────────────────────────────────────
function freePort() {
  for (let i = 0; i < 40; i += 1) {
    const port = 39000 + Math.floor(Math.random() * 6000)
    const probe = spawnSync('bash', ['-c', 'ss -ltnH "sport = :' + port + '" 2>/dev/null | grep -q LISTEN'], { encoding: 'utf8' })
    if (probe.status !== 0) return port
  }
  return 39999
}

{
  const box = sandbox()
  plugin(box, 'demo-plugin')
  writePatch(box)
  const port = freePort()
  const r = run(box, [], {
    DSH_WEB_PORT: String(port),
    // 起来 1 秒就自己退出：典型的假成功
    DSH_WEB_CMD: 'timeout 1 python3 -m http.server ' + port + ' --bind 127.0.0.1',
    DSH_GUARD_GRACE: '4',
    DSH_HEALTH_TIMEOUT: '20'
  })
  const good = existsSync(join(box.home, 'guard-snapshots', 'last-good', 'cordis.patch.yml'))
  check('宽限期：起来又崩的不算成功', r.code !== 0, '退出码 ' + r.code)
  check('宽限期：不写 last-good', !good, good ? '写了（错）' : '没写')
  spawnSync('bash', ['-c', 'pkill -f "http.server ' + port + '" 2>/dev/null'], { encoding: 'utf8' })
}

{
  const box = sandbox()
  plugin(box, 'demo-plugin')
  writePatch(box)
  const port = freePort()
  const r = run(box, [], {
    DSH_WEB_PORT: String(port),
    DSH_WEB_CMD: 'python3 -m http.server ' + port + ' --bind 127.0.0.1',
    DSH_GUARD_GRACE: '3',
    DSH_HEALTH_TIMEOUT: '20'
  })
  const good = join(box.home, 'guard-snapshots', 'last-good', 'cordis.patch.yml')
  check('宽限期：稳定服务过了宽限期才算好', r.code === 0, '退出码 ' + r.code)
  check('宽限期：好的那份镜像进 last-good', existsSync(good), good)
  spawnSync('bash', ['-c', 'pkill -f "http.server ' + port + '" 2>/dev/null'], { encoding: 'utf8' })
}

// ── 汇总 ──────────────────────────────────────────────────────────────────
const failed = results.filter((r) => !r.ok)
for (const r of results) {
  console.log((r.ok ? 'ok   ' : 'FAIL ') + r.name + (r.detail ? '   [' + r.detail + ']' : ''))
}
console.log('\n' + (results.length - failed.length) + '/' + results.length + ' passed')
process.exit(failed.length === 0 ? 0 : 1)
