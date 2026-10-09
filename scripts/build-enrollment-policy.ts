// Bundle canonical policy from an immutable Soma revision. No runtime backend internals.
import {mkdtemp, mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {createHash} from 'node:crypto';

const revision = 'ed7d7057b3dd11d009599db0ad1b340adf66e070';
const contractHash = '0622fd843c2583c9456ff5d7a48afc90b6c3ae028cececc7e944bcfe3452e20e';
const source = process.argv[2];
if (!source || source.startsWith('--')) throw Error('Usage: bun scripts/build-enrollment-policy.ts SOMA_CHECKOUT [--check]');
const check = process.argv.includes('--check');
const root = resolve(import.meta.dir, '..');
const temporary = await mkdtemp(join(tmpdir(), 'media-policy-'));
async function run(args: string[], cwd?: string) {
  const child = Bun.spawn(args, {cwd, stdout: 'pipe', stderr: 'pipe'});
  const [stdout, stderr, status] = await Promise.all([new Response(child.stdout).arrayBuffer(), new Response(child.stderr).text(), child.exited]);
  if (status !== 0) throw Error(stderr || `Command failed: ${args[0]}`);
  return new Uint8Array(stdout);
}
try {
  const archive = await run(['git', '-C', resolve(source), 'archive', revision, 'core', 'tests/fixtures/enrollment-policy.json', 'tests/fixtures/hub-capture-contract.json']);
  await writeFile(join(temporary, 'source.tar'), archive);
  await run(['tar', '-xf', 'source.tar'], temporary);
  const contract = JSON.parse(await readFile(join(temporary, 'core/contract/core.json'), 'utf8'));
  if (createHash('sha256').update(JSON.stringify(contract)).digest('hex') !== contractHash) throw Error('Pinned contract mismatch');
  const entry = join(temporary, 'entry.ts');
  await writeFile(entry, `
import * as enrollment from './core/src/enrollment.ts';
import {canonicalConsumerConfig} from './core/src/consumer-config.ts';
import {normalizeRowsQuery,supportsRowsQuery} from './core/src/query.ts';
import {validateCaptureReceipt,supportsCapture} from './core/src/capture.ts';
globalThis.mediaPolicy=(operation,input)=>{
 const a=JSON.parse(input);let result;
 switch(operation){
 case 'enrollmentApproval': result=enrollment.enrollmentApproval(a);break;
 case 'validateDeviceSession': result=enrollment.validateDeviceSession(a.data,a.expectedProfile);break;
 case 'enrollmentPollResult': result=enrollment.enrollmentPollResult(a.reply,a.expectedFingerprint,a.expectedProfile);break;
 case 'sessionRevocationResult': result=enrollment.sessionRevocationResult(a);break;
 case 'canonicalConsumerConfig': result=canonicalConsumerConfig(a);break;
 case 'normalizeRowsQuery': result=normalizeRowsQuery(a);break;
 case 'supportsRowsQuery': result=supportsRowsQuery(a);break;
 case 'validateCaptureReceipt': result=validateCaptureReceipt(a.value,a.requestId);break;
 case 'supportsCapture': result=supportsCapture(a.capabilities,a.adapter,a.operation);break;
 default:throw Error('Unknown policy operation');
 }return JSON.stringify(result);
};`);
  const build = await Bun.build({entrypoints: [entry], target: 'browser', format: 'iife', minify: true});
  if (!build.success || build.outputs.length !== 1) throw Error('Policy bundle failed');
  const outputs = new Map([
    ['packages/MediaKit/Sources/MediaKit/Resources/enrollment-policy.js', `// Soma ${revision}; contract ${contractHash}. Generated; do not edit.\n${await build.outputs[0].text()}`],
    ['packages/MediaKit/Sources/MediaKit/Generated/CoreContract.generated.swift', await readFile(join(temporary, 'core/generated/CoreContract.generated.swift'), 'utf8')],
    ['packages/MediaKit/Tests/MediaKitTests/Fixtures/enrollment-policy.json', await readFile(join(temporary, 'tests/fixtures/enrollment-policy.json'), 'utf8')],
    ['packages/MediaKit/Tests/MediaKitTests/Fixtures/hub-capture-contract.json', await readFile(join(temporary, 'tests/fixtures/hub-capture-contract.json'), 'utf8')],
  ]);
  for (const [path, content] of outputs) {
    const destination = join(root, path);
    if (check) {
      if (await readFile(destination, 'utf8') !== content) throw Error(`Generated output differs: ${path}`);
    } else {
      await mkdir(resolve(destination, '..'), {recursive: true});
      await writeFile(destination, content);
    }
  }
  console.log(`${check ? 'Verified' : 'Generated'} canonical native policy (${contractHash})`);
} finally {
  await rm(temporary, {recursive: true, force: true});
}
