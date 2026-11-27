// Run inside chrome://gpu by check.cmd (antiblock.ps1) and check/cdp_check.py, through the browser's debugging port.
// chrome://gpu keeps what Chromium knows of the graphics card in window.browserBridge (Chromium's
// content/browser/resources/gpu/browser_bridge.ts); this turns it into "ok" / "FAIL" / "--" lines, so that the
// PowerShell and the Python checks judge alike. The page's own full report text and its data are left in
// window.__gpuReport and window.__gpuData for the caller to fetch in pieces. Returns a JSON string.
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  for (let i = 0; i < 150; i++) {
    const b = window.browserBridge, v = document.querySelector('info-view');
    if (window.gpuPagePopulated && b && b.gpuInfo && b.clientInfo && v) break;
    await sleep(200);
  }
  const b = window.browserBridge, view = document.querySelector('info-view');
  if (!(b && b.gpuInfo)) return JSON.stringify({ error: 'chrome://gpu did not fill in within 30 s', lines: [] });
  await sleep(500); // let the page draw its sections: the report text is read from them
  const info = b.gpuInfo, client = b.clientInfo || {};
  let text = '';
  try { text = view.getSelectionText(true); } catch (e) { text = 'chrome://gpu gave no report text: ' + e; }
  window.__gpuReport = text;
  window.__gpuData = JSON.stringify({ gpuInfo: info, clientInfo: client, logMessages: b.logMessages || [] }, null, 1);

  const lines = [];
  const say = (verdict, key, t) => lines.push({ verdict, key, text: String(t) });
  const hex4 = n => ('000' + n.toString(16)).slice(-4);
  // chrome://gpu's own words for each feature and status (info_view.ts)
  const LABELS = { '2d_canvas': 'Canvas', gpu_compositing: 'Compositing', webgl: 'WebGL', video_decode: 'Video Decode',
    video_encode: 'Video Encode', rasterization: 'Rasterization', opengl: 'OpenGL', vulkan: 'Vulkan',
    multiple_raster_threads: 'Multiple Raster Threads', webgpu: 'WebGPU', skia_graphite: 'Skia Graphite', webnn: 'WebNN',
    direct_rendering_display_compositor: 'Direct Rendering Display Compositor', webgpu_on_vk_via_gl_interop: 'WebGPU interop',
    raw_draw: 'Raw Draw', trees_in_viz: 'TreesInViz' };
  const STATUS = { disabled_software: 'Software only. Hardware acceleration disabled', disabled_off: 'Disabled',
    disabled_off_ok: 'Disabled', unavailable_software: 'Software only, hardware acceleration unavailable',
    unavailable_off: 'Unavailable', unavailable_off_ok: 'Unavailable',
    enabled_readback: 'Hardware accelerated but at reduced performance', enabled_force: 'Hardware accelerated on all pages',
    enabled: 'Hardware accelerated', enabled_on: 'Enabled', enabled_force_on: 'Force enabled' };
  const KEY = ['gpu_compositing', 'webgl', '2d_canvas', 'rasterization']; // these must be on the card, or FAIL
  const SOFT_NAME = /swiftshader|llvmpipe|softpipe|lavapipe|basic render|microsoft basic|\bwarp\b/i;
  const SOFT_VENDOR = { 0xffff: 'software rendering', 0x15ad: "VMware's virtual adapter", 0x1ab8: "Parallels' virtual adapter" };

  say('--', 'Chromium', (client.version || '?') + ' (' + (client.operating_system || '?') + ')');
  // Every adapter: "VENDOR= 0x10de [...], DEVICE=0x1f06 [...], SUBSYS=..., REV=..., LUID={0,90561}, DRIVER_VENDOR=...,
  // DRIVER_VERSION=... *ACTIVE*" (GPUDeviceToString in content/browser/gpu/gpu_internals_ui.cc; LUID on Windows only)
  const adapters = [];
  for (const row of info.basicInfo || []) {
    if (!/^GPU\d+$/.test(String(row.description))) continue;
    const t = String(row.value);
    const m = /VENDOR= 0x([0-9a-f]+)/i.exec(t), d = /DEVICE=0x([0-9a-f]+)(?: \[([^\]]*)\])?/i.exec(t);
    const l = /LUID=\{(-?\d+),(\d+)\}/.exec(t), dv = /DRIVER_VERSION=([^ ,]+)/.exec(t);
    adapters.push({ name: row.description, vendor: m ? parseInt(m[1], 16) : 0, device: d ? parseInt(d[1], 16) : 0,
      deviceString: (d && d[2]) || '', luid: l ? l[1] + ',' + l[2] : '', driver: dv ? dv[1] : '', active: /\*ACTIVE\*\s*$/.test(t) });
  }
  for (const a of adapters) {
    say('--', 'adapter ' + a.name, hex4(a.vendor) + ':' + hex4(a.device) + ' ' + a.deviceString + ', driver ' + (a.driver || '?') +
      (a.luid ? ', LUID ' + a.luid : '') + (a.active ? '  <- ACTIVE' : ''));
  }
  const active = adapters.find(a => a.active) || adapters[0];
  const nvidia = adapters.filter(a => a.vendor === 0x10de);
  let pin = '';
  if (!active) {
    say('FAIL', 'active GPU', 'Chromium named none');
  } else {
    let what = '';
    const soft = SOFT_NAME.exec(active.deviceString);
    if ((active.vendor === 0x1414 && active.device === 0x8c) || (soft && /basic/i.test(soft[0]))) what = 'the Microsoft Basic Render Driver (software)';
    else if (SOFT_VENDOR[active.vendor]) what = SOFT_VENDOR[active.vendor];
    else if (soft) what = soft[0] + ' (software)';
    if (what) {
      say('FAIL', 'active GPU', what + ' - not a graphics card (Remote Desktop, a VM, no working driver, or no card)');
    } else {
      say('ok', 'active GPU', hex4(active.vendor) + ':' + hex4(active.device) + ' ' + active.deviceString);
    }
    if (nvidia.length && active.vendor !== 0x10de) {
      const card = nvidia[0];
      if (card.luid) {
        pin = '--use-adapter-luid=' + card.luid;
        say('FAIL', 'NVIDIA card drawing', 'no - ' + (card.deviceString || 'it') + ' is in the machine but another adapter draws. ' +
          'Add this line to flags.txt: ' + pin);
      } else {
        say('FAIL', 'NVIDIA card drawing', 'no - it is in the machine but another adapter draws');
      }
    } else if (nvidia.length) {
      say('ok', 'NVIDIA card drawing', 'yes');
    }
  }
  const fs = info.featureStatus || {}, st = fs.featureStatus || {};
  for (const name of Object.keys(st).sort()) {
    const s = st[name], onCard = s.startsWith('enabled') && s !== 'enabled_readback';
    say(KEY.includes(name) ? (onCard ? 'ok' : 'FAIL') : '--', LABELS[name] || name, (STATUS[s] || s) + ' (' + s + ')');
  }
  const affects = p => (p.affectedGpuSettings && p.affectedGpuSettings.length ? ' [affects: ' + p.affectedGpuSettings.join(', ') + ']' : '');
  for (const p of fs.problems || []) {
    say('--', p.tag === 'workarounds' ? 'driver workaround' : 'problem', (p.description || '') + affects(p));
  }
  const hw = info.featureStatusForHardwareGpu;
  if (hw) {
    say('FAIL', 'fell back to software', "yes - Chromium gave up on the card in this session. The card's own path said:");
    for (const p of hw.problems || []) if (p.tag !== 'workarounds') say('--', "  card's problem", (p.description || '') + affects(p));
  }
  const crashes = (info.basicInfo || []).find(r => r.description === 'GPU process crash count');
  if (crashes) say(String(crashes.value) === '0' ? 'ok' : 'FAIL', 'GPU process crashes', crashes.value);
  const cmd = String(client.command_line || '');
  say('--', 'blocklist', /--ignore-gpu-blocklist(\s|$)/.test(cmd) ? 'ignored (--ignore-gpu-blocklist)' : 'in force');
  const luid = /--use-adapter-luid=(\S+)/.exec(cmd);
  if (luid) say('--', 'adapter pinned', luid[1]);
  // Switches that turn the card (or WebGL) off whatever the blocklist says. In chrome://gpu, WebGL alone reading
  // "Disabled" means --disable-webgl (compositor_util.cc), and the page words it "disabled via blocklist or the
  // command line" - easily read as a blocklist.
  const OFF = [
    [/--disable-webgl(?=[\s=]|$)/, 'turns WebGL off: no WebGL page or emulator core can draw'],
    [/--disable-webgl2(?=[\s=]|$)/, 'turns WebGL 2 off (the Dreamcast core and the new Windows engine need it)'],
    [/--disable-3d-apis(?=[\s=]|$)/, 'turns WebGL and WebGPU off'],
    [/--disable-gpu(?=[\s=]|$)/, 'turns the graphics card off for everything (what "Use graphics acceleration" switched off does)'],
    [/--disable-gpu-compositing(?=[\s=]|$)/, 'puts pages together on the processor'],
    [/--disable-gpu-rasterization(?=[\s=]|$)/, 'draws page content on the processor'],
    [/--disable-accelerated-2d-canvas(?=[\s=]|$)/, 'draws 2D canvases on the processor'],
    [/--use-gl=(disabled|swiftshader)(?=\s|$)/, 'asks for no GL, or software GL'],
    [/--use-angle=(swiftshader|swiftshader-webgl|warp)(?=\s|$)/, "asks ANGLE for its software renderer"],
  ];
  for (const [re, why] of OFF) {
    const m = re.exec(cmd);
    if (m) say('FAIL', 'switch on the command line', m[0].trim() + ' - ' + why + '. Take it out of the shortcut or flags.txt');
  }
  if (/--enable-unsafe-swiftshader(?=[\s=]|$)/.test(cmd)) say('--', 'switch on the command line', '--enable-unsafe-swiftshader - WebGL may quietly fall back to the processor');
  return JSON.stringify({ lines, pin, reportLength: window.__gpuReport.length, dataLength: window.__gpuData.length });
})()
