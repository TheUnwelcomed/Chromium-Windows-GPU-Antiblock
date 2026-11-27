// node tests/test_judge.mjs - check/gpu-judge.js against made-up chrome://gpu data of the cases that matter on
// Windows: the NVIDIA card drawing; another adapter drawing beside it; the Microsoft Basic Render Driver; a session
// that fell back to software after GPU crashes. The rows are in the form Chromium writes them (gpu_internals_ui.cc).
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const judge = readFileSync(new URL('../check/gpu-judge.js', import.meta.url), 'utf8');
const NV = 'VENDOR= 0x10de [Google Inc. (NVIDIA)], DEVICE=0x1f06 [ANGLE (NVIDIA, NVIDIA GeForce RTX 2060 SUPER (0x00001F06) ' +
  'Direct3D11 vs_5_0 ps_5_0, D3D11)], SUBSYS=0x139f10de, REV=161, LUID={0,90561}, DRIVER_VENDOR=NVIDIA, DRIVER_VERSION=32.0.15.6614';
const INTEL = 'VENDOR= 0x8086 [Google Inc. (Intel)], DEVICE=0x3e92 [ANGLE (Intel, Intel(R) UHD Graphics 630 (0x00003E92) ' +
  'Direct3D11 vs_5_0 ps_5_0, D3D11)], SUBSYS=0x86941043, REV=0, LUID={0,74210}, DRIVER_VENDOR=Intel, DRIVER_VERSION=31.0.101.2125';
const BASIC = 'VENDOR= 0x1414 [Google Inc. (Microsoft)], DEVICE=0x008c [ANGLE (Microsoft, Microsoft Basic Render Driver ' +
  '(0x0000008C) Direct3D11 vs_5_0 ps_5_0, D3D11)], LUID={0,61043}, DRIVER_VENDOR=Microsoft, DRIVER_VERSION=10.0.19041.3636';
const ON = { '2d_canvas': 'enabled', gpu_compositing: 'enabled', webgl: 'enabled', rasterization: 'enabled', video_decode: 'enabled',
  webgpu: 'enabled', opengl: 'enabled_on', vulkan: 'disabled_off', direct_rendering_display_compositor: 'disabled_off_ok' };
const SOFT = { '2d_canvas': 'unavailable_software', gpu_compositing: 'disabled_software', webgl: 'enabled_readback',
  rasterization: 'unavailable_software', video_decode: 'unavailable_software', webgpu: 'unavailable_software' };

async function run(gpuInfo, cmd = 'chrome.exe --ignore-gpu-blocklist --force-high-performance-gpu') {
  globalThis.window = globalThis;
  globalThis.gpuPagePopulated = true;
  globalThis.browserBridge = { gpuInfo, clientInfo: { version: 'Chrome/158.0.8127.88', operating_system: 'Windows NT 10.0.19045', command_line: cmd }, logMessages: [] };
  globalThis.document = { querySelector: () => ({ getSelectionText: () => 'Graphics Feature Status\n...' }) };
  const out = JSON.parse(await (0, eval)(judge));
  const fails = out.lines.filter(l => l.verdict === 'FAIL').map(l => l.key);
  return { out, fails, line: key => out.lines.find(l => l.key === key) };
}
const basic = (...gpus) => [{ description: 'Initialization time', value: '120' }, { description: 'GPU process crash count', value: '0' },
  ...gpus.map((g, i) => ({ description: 'GPU' + i, value: g }))];

// 1. The card draws, everything on it
let r = await run({ basicInfo: basic(NV + ' *ACTIVE*'), featureStatus: { featureStatus: ON, problems: [], workarounds: [] } });
assert.deepEqual(r.fails, []);
assert.equal(r.line('active GPU').verdict, 'ok');
assert.equal(r.line('NVIDIA card drawing').text, 'yes');
assert.equal(r.line('blocklist').text, 'ignored (--ignore-gpu-blocklist)');
assert.equal(r.out.pin, '');
console.log('ok   the card drawing: no FAIL');

// 2. Another adapter (Intel) draws, the card beside it: FAIL and the line to pin it
r = await run({ basicInfo: basic(INTEL + ' *ACTIVE*', NV), featureStatus: { featureStatus: ON, problems: [], workarounds: [] } });
assert.deepEqual(r.fails, ['NVIDIA card drawing']);
assert.equal(r.out.pin, '--use-adapter-luid=0,90561');
assert.match(r.line('NVIDIA card drawing').text, /--use-adapter-luid=0,90561/);
console.log('ok   another adapter drawing: FAIL, pin ' + r.out.pin);

// 3. The Microsoft Basic Render Driver (Remote Desktop, a VM, a driver not working), blocklisted by entry 74
r = await run({ basicInfo: basic(BASIC + ' *ACTIVE*', NV), featureStatus: { featureStatus: SOFT, problems: [
  { description: "GPU access is blocked if users don't have proper graphics driver installed after Windows installation",
    crBugs: ['248178'], affectedGpuSettings: ['all'], tag: 'disabledFeatures' }], workarounds: [] } }, 'chrome.exe');
assert.ok(r.fails.includes('active GPU') && r.fails.includes('NVIDIA card drawing') && r.fails.includes('WebGL') && r.fails.includes('Compositing'));
assert.match(r.line('active GPU').text, /Basic Render/);
assert.equal(r.line('blocklist').text, 'in force');
assert.match(r.line('problem').text, /proper graphics driver/);
console.log('ok   Basic Render Driver: FAIL on ' + r.fails.join(', '));

// 4. Fell back to software after GPU process crashes (what chrome://gpu then shows for the hardware GPU as well)
r = await run({ basicInfo: basic('VENDOR= 0xffff [Google Inc.], DEVICE=0xffff [ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)), SwiftShader driver)] *ACTIVE*')
  .map(x => x.description === 'GPU process crash count' ? { ...x, value: '3' } : x),
  featureStatus: { featureStatus: SOFT, problems: [], workarounds: [] },
  featureStatusForHardwareGpu: { featureStatus: ON, problems: [{ description: 'GPU process crashed too many times', affectedGpuSettings: [], tag: 'disabledFeatures' }], workarounds: [] } });
assert.ok(r.fails.includes('fell back to software') && r.fails.includes('GPU process crashes') && r.fails.includes('active GPU'));
assert.equal(r.line('GPU process crashes').text, '3');
console.log('ok   fell back after crashes: FAIL on ' + r.fails.join(', '));

// 5. The owner's screen of 2026-11-26 (Chromium 160.0.8187.0, Windows 10 19045): every feature on the card but
//    WebGL "Disabled" - which only --disable-webgl on the command line produces (compositor_util.cc)
r = await run({ basicInfo: basic(NV + ' *ACTIVE*'), featureStatus: { featureStatus: { ...ON, webgl: 'disabled_off', skia_graphite: 'enabled_on',
  multiple_raster_threads: 'enabled_on', rasterization: 'enabled_force', webnn: 'disabled_off' },
  problems: [{ description: 'WebGL has been disabled via blocklist or the command line.', affectedGpuSettings: ['webgl'], tag: 'disabledFeatures' }], workarounds: [] } },
  '"C:\\Users\\someone\\Downloads\\chrome-win\\chrome.exe" --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy --disable-webgl --flag-switches-begin --enable-gpu-rasterization --flag-switches-end');
assert.deepEqual(r.fails, ['WebGL', 'switch on the command line']);
assert.match(r.out.lines.find(l => l.key === 'switch on the command line').text, /^--disable-webgl - turns WebGL off/);
assert.equal(r.line('Rasterization').verdict, 'ok');
console.log('ok   the photo of 2026-11-26: FAIL on ' + r.fails.join(', ') + ' - "' + r.out.lines.find(l => l.key === 'switch on the command line').text + '"');

// 6. Our own switches are not mistaken for ones that turn the card off
r = await run({ basicInfo: basic(NV + ' *ACTIVE*'), featureStatus: { featureStatus: ON, problems: [], workarounds: [] } },
  'chrome.exe --ignore-gpu-blocklist --force-high-performance-gpu --disable-gpu-process-crash-limit --disable-gpu-driver-bug-workarounds --disable-gpu-vsync --disable-webgl-image-chromium');
assert.deepEqual(r.fails, []);
console.log('ok   --disable-gpu-process-crash-limit and friends are not taken for --disable-gpu');

// 7. chrome://gpu never filled in
globalThis.browserBridge = null;
console.log('ok   (waiting for an empty chrome://gpu takes 30 s; not run)');
