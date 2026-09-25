// icbc_daily_water WebUI 逻辑 v0.9.6 (多任务 Profiles + 操作录制 + 状态/日志)
// 走 KernelSU 注入的 ksu 接口执行 root 命令
import { exec, toast, moduleInfo } from './kernelsu.js';

const W = '/data/adb/modules/icbc_daily_water/webctl.sh';
const $ = (id) => document.getElementById(id);
let busy = false;
let recPoll = null;   // 录制状态轮询定时器

async function run(arg, options) {
  try {
    const r = await exec('sh ' + W + ' ' + arg, options || {});
    return (r.stdout || '').trim();
  } catch (e) {
    // PIN 通过 options.env 传递，不进入命令 argv；异常信息仍统一脱敏。
    if (String(arg).indexOf('setpin') === 0) return 'EXEC_ERR';
    return 'EXEC_ERR ' + (e && e.message ? e.message : e);
  }
}

function toastMsg(m) { try { toast(m); } catch (e) {} }

// ---------- 状态加载 ----------
function chkRow(name, state, good) {
  return '<div class="ck"><span>' + name + '</span><span class="' + (good ? 'ok' : 'bad') + '">' + state + '</span></div>';
}

async function loadStatus() {
  const out = await run('status');
  const cfg = {};
  for (const line of out.split('\n')) {
    // webctl 键名是小写且单行多 token (svc=… enable=… screen=… now=… sched=… last_ago=…)，
    // 逐 token 解析; 独立行 window_ok=yes / done_ok=yes 同样命中
    const tkre = /([A-Za-z_0-9-]+)=(\S+)/g;
    let tt;
    while ((tt = tkre.exec(line)) !== null) cfg[tt[1]] = tt[2];
    if (line.indexOf('today: ') === 0) cfg._today = line.slice(7);
    if (line.indexOf('service: ') === 0) cfg._svc = line.slice(9);
    if (line.indexOf('fail_times: ') === 0) cfg._fail = line.slice(12);
  }
  // 今日状态
  const t = $('today');
  if (cfg._today === 'DONE') { t.textContent = '今日已浇 ✅'; t.className = 'pill ok'; }
  else { t.textContent = '今日未浇'; t.className = 'pill warn'; }
  // 时间
  const tt = cfg.SCHED_TIME || '0730';
  $('time').value = tt.slice(0, 2) + ':' + tt.slice(2);
  $('enable').checked = cfg.SCHED_ENABLE === '1';
  $('watch').checked = cfg.WATCH_OPEN === '1';
  $('sleep').checked = cfg.SLEEP_AFTER === '1';
  $('mode').value = cfg.UNLOCK_MODE === 'swipe' ? 'swipe' : 'pin';
  $('pin').placeholder = (cfg.PIN && cfg.PIN.length > 0) ? '已设置 ●●●●●●（输入新密码才修改）' : '未设置，请输入 6 位密码';
  // 触发检查
  const svcRun = cfg._svc === 'running';
  const enabled = cfg.enable === '1';
  const screenOff = cfg.screen === '0';
  const winOk = cfg.window_ok === 'yes';
  const doneOk = cfg.done_ok === 'yes';
  const failN = parseInt(cfg._fail || '0', 10);
  const failOk = failN < 3;
  const rows = [
    chkRow('守护服务', svcRun ? '运行中' : '已停止', svcRun),
    chkRow('定时开关', enabled ? '开' : '关', enabled),
    chkRow('在触发窗口（到点后 60 分钟内）', winOk ? ('是（当前 ' + (cfg.now || '') + '）') : '不在窗口', winOk),
    chkRow('当天定时已浇', doneOk ? '已浇（今天不再自动浇）' : '未浇', !doneOk),
    chkRow('触发时屏幕', screenOff ? '已熄（直接唤醒）' : '亮着（会先锁屏再解锁）', true),
    chkRow('连续失败 <3 次', failOk ? (failN + ' 次') : (failN + ' 次（被暂停，超6小时自动清零）'), failOk)
  ];
  $('chk').innerHTML = rows.join('');
  loadProfiles();
}

// ---------- Profiles ----------
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function loadProfiles() {
  const out = await run('profiles');
  // 录制状态恢复: 页面刷新/加载时, 若后台正在录制, 把对应任务卡的按钮恢复为「停止录制」并继续轮询
  let recSlug = null;
  const st = await run('record status');
  if (st.indexOf('recording=yes') === 0) {
    const m = st.match(/\bname=(\S+)/);
    if (m) recSlug = m[1];
    if (!recPoll) { recPoll = setInterval(pollRec, 3000); }
  }
  const box = $('profs');
  if (!out || out.indexOf('EXEC_ERR') === 0) {
    box.innerHTML = '<p class="midi">加载失败：' + esc(out) + '</p>';
    return;
  }
  const list = [];
  for (const line of out.split('\n')) {
    const m = line.match(/^profile=(\S+)\s+(.*)$/);
    if (!m) continue;
    const p = { slug: m[1] };
    const tkre = /([A-Za-z_0-9-]+)=(\S+)/g;
    let tt;
    while ((tt = tkre.exec(m[2])) !== null) p[tt[1]] = tt[2];
    list.push(p);
  }
  if (!list.length) { box.innerHTML = '<p class="midi">还没有任务，用下面表单新增</p>'; return; }
  const gloSched = ($('time').value || '07:30').replace(':', '');
  box.innerHTML = list.map((p) => {
    // 继承: p_sched/p_enable 为空时用全局
    const sched = p.psched || gloSched;
    const en = p.penable === '1' ? true : (p.penable === '' ? $('enable').checked : false);
    const isScript = (p.ptype || 'script') === 'script';
    const doneBadge = p.pdone === 'yes'
      ? '<span class="pill ok">今日已跑</span>'
      : '<span class="pill warn">今日未跑</span>';
    return '<div class="prof" data-slug="' + esc(p.slug) + '">' +
      '<div class="ph">' +
        '<span class="pn">' + esc(p.pname || p.slug) + '</span>' +
        '<span class="pill">' + (isScript ? '脚本型' : '录制型') + '</span>' +
        doneBadge +
        (p.ptry && p.ptry !== '0' ? '<span class="pill">失败' + esc(p.ptry) + '</span>' : '') +
      '</div>' +
      '<div class="pm">包 <input class="pkgbox" data-act="pPkg" value="' + esc(p.ppkg || '') + '" placeholder="未设(亮屏即录)"' + (isScript ? ' disabled' : '') + '><button class="small" data-act="pPkgSave"' + (isScript ? ' disabled' : '') + '>存</button>' +
        (p.pacts && p.pacts !== '0' ? ' · 动作 ' + esc(p.pacts) : '') +
      '</div>' +
      '<div class="prow2">' +
        '<label><input type="checkbox" data-act="pEnable" ' + (en ? 'checked' : '') + '> 启用</label>' +
        '<input type="time" data-act="pTime" value="' + sched.slice(0, 2) + ':' + sched.slice(2) + '">' +
        '<button class="small" data-act="pTimeSave">存</button>' +
        '<button class="small primary" data-act="pRun">' + (isScript ? '立即浇水' : '立即跑') + '</button>' +
        (isScript ? '' : '<button class="small' + (p.slug === recSlug ? ' rec-on' : '') + '" data-act="pRec">' + (p.slug === recSlug ? '停止录制' : '开始录制') + '</button>') +
        (p.slug === 'icbc' ? '' : '<button class="small danger" data-act="pDel">删</button>') +
      '</div>' +
    '</div>';
  }).join('');
}

// ---------- 录制状态轮询 ----------
async function pollRec() {
  // 录制中, 每 3 秒查一次 record status; 停止后刷新列表
  const out = await run('record status');
  const recOn = out.indexOf('recording=yes') === 0;
  if (!recOn) {
    if (recPoll) { clearInterval(recPoll); recPoll = null; }
    toastMsg('录制已停止');
    loadProfiles(); loadLog();
    return;
  }
  // 目标 app 一直没识别到: 提示一次 (防长期 READY=0 白录)
  if (!window._recWarned && out.indexOf('READY') === -1) {
    const m = out.match(/\bname=(\S+)/);
    if (m) {
      window._recWarned = 1;
      toastMsg('还没识别到目标 app（请确认已切到该 app 操作）');
    }
  }
}

// ---------- 保存动作 ----------
async function saveTime() {
  if (busy) return;
  const v = $('time').value; // HH:MM
  if (!/^\d{2}:\d{2}$/.test(v)) { toastMsg('时间格式错误'); return; }
  const hhmm = v.replace(':', '');
  busy = true;
  const r = await run('settime ' + hhmm);
  busy = false;
  toastMsg(r.indexOf('ERR') === 0 ? r : '时间已保存（2 秒内生效，无需重启）');
  loadStatus(); loadLog();
}

async function savePin() {
  if (busy) return;
  const v = $('pin').value.trim();
  if (!v) { toastMsg('未输入新密码'); return; }
  if (!/^\d{4,8}$/.test(v)) { toastMsg('密码需 4-8 位数字'); return; }
  $('pin').value = '';
  busy = true;
  // 通过 KernelSU exec 的 env 传递，PIN 不出现在 shell 命令字符串/argv 中。
  const r = await run('setpin', { env: { WEBUI_PIN: v } });
  busy = false;
  toastMsg(r.indexOf('ERR') === 0 ? r : 'PIN 已保存');
  loadStatus();
}

async function toggle(key, val) {
  if (busy) return;
  busy = true;
  const r = await run(key + ' ' + val);
  busy = false;
  toastMsg(r.indexOf('ERR') === 0 ? r : '已保存');
  loadStatus();
}

// ---------- 新增任务 ----------
async function addProfile() {
  if (busy) return;
  const name = $('npName').value.trim();
  const pkg = $('npPkg').value.trim();
  if (!name) { toastMsg('请输入任务名'); return; }
  // slug 校验须与 webctl 白名单一致: 中英数_横线, 无空格/特殊字符
  if (!/^[0-9A-Za-z_\u4e00-\u9fa5-]+$/.test(name) || name.length > 24) {
    toastMsg('任务名只能中文/字母/数字/下划线/横线，且不超过24字');
    return;
  }
  // 包名可留空：空包名是“亮屏全量录制/回放当前画面”模式。
  if (pkg && !/^[0-9A-Za-z_.]+$/.test(pkg)) { toastMsg('包名格式不对'); return; }
  const hhmm = ($('npTime').value || '07:30').replace(':', '');
  busy = true;
  const r = await run("profile add '" + name + "' '" + name + "' '" + pkg + "' " + hhmm);
  busy = false;
  if (r.indexOf('ERR') === 0) { toastMsg('新增失败：' + r); return; }
  toastMsg('任务已新增，点它的「开始录制」');
  // 新任务 slug = 任务名 (webctl 校验)
  $('npName').value = ''; $('npPkg').value = '';
  loadProfiles();
}

// ---------- Profile 操作 ----------
async function onProfAct(e) {
  const btn = e.target.closest('button, input');
  if (!btn || !btn.dataset || !btn.dataset.act) return;
  const prof = btn.closest('.prof');
  if (!prof) return;
  const slug = prof.dataset.slug;
  const act = btn.dataset.act;
  if (busy && act !== 'pEnable') return;
  busy = true;
  try {
    if (act === 'pEnable') {
      const r = await run('profile set ' + slug + ' p_enable ' + (btn.checked ? '1' : '0'));
      toastMsg(r.indexOf('ERR') === 0 ? r : (btn.checked ? '已启用' : '已停用'));
    } else if (act === 'pTimeSave') {
      const ti = prof.querySelector('[data-act=pTime]');
      const hhmm = (ti.value || '07:30').replace(':', '');
      const r = await run('profile set ' + slug + ' p_sched ' + hhmm);
      toastMsg(r.indexOf('ERR') === 0 ? r : '定时已保存');
    } else if (act === 'pRun') {
      const r = await run('trigger ' + slug);
      if (r.indexOf('ERR') === 0) { toastMsg(r); return; }
      toastMsg('已触发「' + slug + '」！屏不亮就重启服务');
      setTimeout(loadStatus, 4000);
    } else if (act === 'pPkgSave') {
      const pgb = prof.querySelector('[data-act=pPkg]');
      const v = (pgb.value || '').trim();
      if (v && !/^[0-9A-Za-z_.]+$/.test(v)) { toastMsg('包名格式不对'); return; }
      const r = await run('profile set ' + slug + ' p_pkg ' + (v || ''));
      toastMsg(r.indexOf('ERR') === 0 ? r : (v ? '目标app已保存：' + v : '已清空（亮屏即录）'));
    } else if (act === 'pDel') {
      if (!window.confirm('删除任务「' + slug + '」及其录制动作？')) return;
      const r = await run('profile del ' + slug);
      toastMsg(r.indexOf('ERR') === 0 ? r : '已删除');
      loadProfiles();
    } else if (act === 'pRec') {
      if (btn.textContent.indexOf('停止') === 0) {
        const r = await run('record stop ' + slug);
        toastMsg(r.indexOf('ERR') === 0 ? r : '录制已停止');
        if (recPoll) { clearInterval(recPoll); recPoll = null; }
        loadProfiles();
      } else {
        const r = await run('record start ' + slug);
        if (r.indexOf('ERR') === 0) { toastMsg(r); return; }
        window._recWarned = 0;
        toastMsg('开始录制！切到目标 app 才会开录，离开自动暂停，操作完点「停止录制」');
        btn.textContent = '停止录制';
        btn.classList.add('rec-on');
        if (recPoll) clearInterval(recPoll);
        recPoll = setInterval(pollRec, 3000);
      }
    }
  } finally {
    busy = false;
  }
}

// ---------- 日志 ----------
async function loadLog() {
  const out = await run('log');
  $('log').textContent = out || '(no log yet)';
}

// ---------- 事件 ----------
$('btnTime').addEventListener('click', saveTime);
$('btnPin').addEventListener('click', savePin);
$('btnPAdd').addEventListener('click', addProfile);
$('btnShow').addEventListener('click', () => {
  const p = $('pin');
  const show = p.type === 'password';
  p.type = show ? 'text' : 'password';
  $('btnShow').textContent = show ? '隐藏' : '显示';
});

$('enable').addEventListener('change', (e) => toggle('setenable', e.target.checked ? '1' : '0'));
$('watch').addEventListener('change', (e) => toggle('setwatch', e.target.checked ? '1' : '0'));
$('sleep').addEventListener('change', (e) => toggle('setsleep', e.target.checked ? '1' : '0'));
$('mode').addEventListener('change', (e) => toggle('setmode', e.target.value));

$('profs').addEventListener('click', onProfAct);

$('btnTrigger').addEventListener('click', async () => {
  if (busy) return;
  busy = true;
  const r = await run('trigger');
  busy = false;
  if (r.indexOf('ERR') === 0) { toastMsg(r); return; }
  toastMsg('已触发！若屏幕 2 秒内不亮，说明守护进程没在运行，点「重启服务」');
  setTimeout(loadStatus, 3000);
});

$('btnRestart').addEventListener('click', async () => {
  if (busy) return;
  busy = true;
  const r = await run('restart');
  busy = false;
  toastMsg(r.indexOf('ERR') === 0 ? r : '服务已重启');
  setTimeout(loadStatus, 2000);
});

$('btnRefresh').addEventListener('click', () => { loadStatus(); loadLog(); });
$('btnLog').addEventListener('click', loadLog);

// 初次加载 + 每 15 秒自动刷新状态
try {
  const mi = moduleInfo();
  const ver = $('ver');
  if (mi && mi.version) ver.textContent = mi.version;
} catch (e) {}
loadStatus();
loadLog();
setInterval(() => { loadStatus(); }, 15000);