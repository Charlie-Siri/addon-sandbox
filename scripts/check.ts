// Headless check: load addons in Node (no browser), run commands, print errors, warnings and chat.
// Usage: npm run check -- VendorPrinter [--dir path/to/AddonFolder] [--run "/vp"] [--seconds 2] [--no-sv] [--frames]
//
// Use cases (profile/usecases/<Addon>/<name>.usecase.json):
//   npm run check -- --usecase VendorPrinter/vendor-tab [--usecase ...] [--report] [--log]
//   npm run check -- --usecases [VendorPrinter]          every use case (of one addon)
// Reads the WoW install and the sandbox profile; writes nothing. Exit code 1 on any error or failed use case.
import { loadHeadless, loadUseCaseHeadless, resolveUseCaseRef, allUseCaseRefs } from './headless.ts';
import { failureReport } from '../src/core/runner.ts';
import { describeStep } from '../src/core/usecase.ts';

const args = process.argv.slice(2);
const addons: string[] = [];
const dirs: string[] = [];
const commands: string[] = [];
const useCases: string[] = [];
let allUseCases: string | null = null;
let seconds = 1;
let useSV = true;
let showFrames = false;
let report = false;
let showLog = false;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--run') commands.push(args[++i]);
  else if (a === '--seconds') seconds = Number(args[++i]);
  else if (a === '--no-sv') useSV = false;
  else if (a === '--frames') showFrames = true;
  else if (a === '--dir') dirs.push(args[++i]);
  else if (a === '--usecase') useCases.push(args[++i]);
  else if (a === '--usecases') allUseCases = args[i + 1] && !args[i + 1].startsWith('--') ? args[++i] : '';
  else if (a === '--report') report = true;
  else if (a === '--log') showLog = true;
  else addons.push(a);
}

if (useCases.length || allUseCases !== null) {
  const refs = [...useCases, ...(allUseCases !== null ? allUseCaseRefs(allUseCases || undefined) : [])];
  if (!refs.length) {
    console.log(`No use cases found${allUseCases ? ` for ${allUseCases}` : ''} in profile/usecases/.`);
    process.exit(1);
  }
  let failedCount = 0;
  for (const ref of refs) {
    const ok = await checkUseCase(ref);
    if (!ok) failedCount++;
  }
  if (refs.length > 1) console.log(`\n${refs.length - failedCount} of ${refs.length} use cases passed.`);
  process.exitCode = failedCount ? 1 : 0;
} else {
  await classicCheck();
}

async function checkUseCase(ref: string): Promise<boolean> {
  let resolved;
  try { resolved = resolveUseCaseRef(ref); }
  catch (e) { console.log(`\n${ref}\n  ✗ ${(e as Error).message}`); return false; }
  const uc = resolved.useCase;
  console.log(`\n${resolved.id}  "${uc.title}"`);
  const { runner, errors, loadMs } = await loadUseCaseHeadless(resolved, showLog ? (l) => console.log(`    ${l}`) : undefined);
  if (errors.length) {
    console.log(`  ✗ The file has ${errors.length} problem${errors.length === 1 ? '' : 's'}:`);
    for (const e of errors) console.log(`      ${e}`);
    return false;
  }
  const started = performance.now();
  runner.fastForward();
  const ms = performance.now() - started;
  const pad = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + '…' : s.padEnd(n));
  if (runner.failure && runner.failure.step < 0) {
    console.log(`  ✗ setup: ${runner.failure.message}`);
  }
  uc.steps.forEach((step, i) => {
    const r = runner.results[i];
    const mark = r.status === 'passed' ? '✓' : r.status === 'failed' ? '✗' : '·';
    const say = step.say ? `  "${step.say.length > 50 ? step.say.slice(0, 49) + '…' : step.say}"` : '';
    const info = r.status === 'failed' ? `  ${runner.failure?.message}` : r.info ? `  ${r.info}` : '';
    console.log(`  ${mark} ${String(i + 1).padStart(2)} ${pad(describeStep(step), 44)}${info}${r.status !== 'failed' ? say : ''}`);
    if (r.status === 'failed' && runner.failure?.candidates?.length) {
      for (const c of runner.failure.candidates) console.log(`         ${c}`);
    }
  });
  for (const w of runner.warnings) console.log(`  ! ${w}`);
  const passed = runner.results.filter((r) => r.status === 'passed').length;
  const verdict = runner.done ? 'passed' : 'FAILED';
  console.log(`  -> ${verdict}: ${passed} of ${uc.steps.length} steps, ${runner.displayTime.toFixed(1)} s of video, `
    + `${runner.sandboxTime.toFixed(1)} s of game time (load ${loadMs.toFixed(0)} ms, run ${ms.toFixed(0)} ms)`);
  if (!runner.done && report) console.log('\n' + failureReport(runner).split('\n').map((l) => '    ' + l).join('\n'));
  else if (!runner.done) console.log('     (add --report for the screen, chat and errors at the failure)');
  runner.sandbox.close();
  return runner.done;
}

async function classicCheck() {
  const session = await loadHeadless({ addons: addons.length ? addons : undefined, dirs, useSV });
  const { sandbox, log } = session;
  sandbox.advance(seconds);
  for (const cmd of commands) {
    log.chat.push(`> ${cmd}`);
    sandbox.chat(cmd);
    sandbox.advance(seconds);
  }
  const render = JSON.parse(sandbox.render());

  console.log(`Loaded: ${sandbox.loadOrder.join(', ')}  (${session.loadMs.toFixed(0)} ms)`);
  if (session.missingDeps.length) console.log(`Missing dependencies: ${session.missingDeps.join(', ')}`);
  console.log(`\n== Chat (${log.chat.length})`);
  for (const line of log.chat) console.log('  ' + line);
  console.log(`\n== Errors (${log.errors.length})`);
  for (const e of log.errors) console.log(`  ${e.message}\n${e.stack.split('\n').slice(0, 6).map((l) => '      ' + l.trim()).join('\n')}`);
  console.log(`\n== Warnings (${log.warnings.length})`);
  for (const w of log.warnings) console.log('  ' + w);
  console.log(`\n== Unemulated APIs used (${log.missing.length})`);
  if (log.missing.length) console.log('  ' + log.missing.join(', '));
  console.log(`\n== Render: ${render.items.length} items on a ${render.w}x${render.h} screen`);
  if (showFrames) {
    for (const it of render.items) {
      const label = it.t ? JSON.stringify(it.t.slice(0, 60)) : it.st ?? it.tex ?? it.atl ?? (it.c ? 'color' : '');
      console.log(`  ${it.k} #${it.id} ${Math.round(it.x)},${Math.round(it.y)} ${Math.round(it.w)}x${Math.round(it.h)} ${label}`);
    }
  }
  sandbox.close();
  process.exitCode = log.errors.length ? 1 : 0;
}
