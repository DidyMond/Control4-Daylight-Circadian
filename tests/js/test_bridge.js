// Test di drivers/webview/www/dist/js/bridge.js e dei limitatori di util.js (Node, solo sviluppo).
// Nessun DOM: il canale col driver non ne ha bisogno. Tempo finto: nessuna attesa reale.
// Esecuzione: node tests/js/test_bridge.js   (lo lancia anche tools/run_tests.ps1 se c'e' node)
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const DIST = path.join(__dirname, '..', '..', 'drivers', 'webview', 'www', 'dist', 'js');

let pass = 0, fail = 0;
function test(name, fn) {
  try { fn(); pass++; console.log('  PASS ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + ' -> ' + (e && e.message ? e.message : e)); }
}
function eq(a, b, msg) { if (a !== b) { throw new Error((msg || 'eq') + ': atteso ' + JSON.stringify(b) + ', ottenuto ' + JSON.stringify(a)); } }
function truthy(v, msg) { if (!v) { throw new Error(msg || 'atteso vero'); } }

// ---------------------------------------------------------------- ambiente finto
function makeEnv() {
  let now = 1700000000000, seq = 0;
  const timers = [];
  const RealDate = Date;
  class FakeDate extends RealDate {
    constructor(...a) { if (a.length) { super(...a); } else { super(now); } }
    static now() { return now; }
  }
  const env = {
    c4calls: [],          // ordine di subscribe / sendCommand
    sentCmds: [],         // { cmd, params }
    events: [],           // { evt, arg }
  };
  const sandbox = {
    console: { log() {} },
    document: { documentElement: {} },
    navigator: { language: 'en' },
    location: { search: '' },
    Date: FakeDate,
    setTimeout(fn, ms) { const id = ++seq; timers.push({ id, at: now + ms, fn, every: null }); return id; },
    setInterval(fn, ms) { const id = ++seq; timers.push({ id, at: now + ms, fn, every: ms }); return id; },
    clearTimeout(id) { const i = timers.findIndex(t => t.id === id); if (i >= 0) { timers.splice(i, 1); } },
    clearInterval(id) { const i = timers.findIndex(t => t.id === id); if (i >= 0) { timers.splice(i, 1); } },
  };
  sandbox.window = sandbox;
  sandbox.C4 = {
    subscribeToDataToUi(flag) { env.c4calls.push('subscribe(' + flag + ')'); },
    sendCommand(cmd, params, async, toProto) {
      env.c4calls.push('send:' + cmd);
      env.sentCmds.push({ cmd, params: JSON.parse(params), async, toProto });
    },
  };
  vm.createContext(sandbox);
  for (const f of ['i18n.js', 'util.js', 'bridge.js']) {
    vm.runInContext(fs.readFileSync(path.join(DIST, f), 'utf8'), sandbox, { filename: f });
  }
  const DC = sandbox.DC;
  for (const evt of ['list', 'state', 'preview', 'ack', 'hello', 'error', 'status', 'language']) {
    DC.bridge.on(evt, arg => env.events.push({ evt, arg }));
  }
  env.DC = DC;
  env.advance = function (ms) {
    const target = now + ms;
    for (;;) {
      const due = timers.filter(t => t.at <= target).sort((a, b) => a.at - b.at)[0];
      if (!due) { break; }
      now = due.at;
      if (due.every) { due.at += due.every; } else { timers.splice(timers.indexOf(due), 1); }
      due.fn();
    }
    now = target;
  };
  // come arriva dal Broker: {"devicecommand":{...,"static":"<JSON>"}}
  env.deliver = function (msg) {
    const envelope = { devicecommand: { command: 'DC_EVENT', params: { param: [{ name: 'json', value: { type: 'string', static: JSON.stringify(msg) } }] } } };
    sandbox.onDataToUi(JSON.stringify(envelope));
  };
  env.log = () => DC.logLines.join('\n');
  env.lastCmd = () => env.sentCmds[env.sentCmds.length - 1];
  return env;
}

// ---------------------------------------------------------------- avvio
test('avvio: iscrizione a subscribeToDataToUi(true) PRIMA di qualunque richiesta', () => {
  const e = makeEnv();
  e.DC.bridge.start();
  eq(e.c4calls[0], 'subscribe(true)', 'primo contatto con C4');
  const firstSend = e.c4calls.findIndex(c => c.indexOf('send:') === 0);
  truthy(firstSend > e.c4calls.indexOf('subscribe(true)'), 'la prima richiesta segue l\'iscrizione');
  eq(e.sentCmds[0].cmd, 'DC_PING'); eq(e.sentCmds[1].cmd, 'DC_LIST');
  eq(e.sentCmds[0].toProto, true, 'sendToProtocol = true');
  eq(e.sentCmds[0].async, false);
});

test('avvio lento: se nessuno risponde si riprova ogni 2 s; alla prima risposta si smette', () => {
  const e = makeEnv();
  e.DC.bridge.start();
  const base = e.sentCmds.length;                       // PING + LIST iniziali
  e.advance(2100);
  eq(e.sentCmds.length, base + 2, 'primo tentativo di ripetizione (PING + LIST)');
  truthy(/avvio: nessuna risposta/.test(e.log()), 'il tentativo e\' nel log');
  e.deliver({ v: 1, ok: true, controllers: [], rid: e.sentCmds[0].params.rid });
  const after = e.sentCmds.length;
  e.advance(7000);                                      // t = 9,1 s: prima del primo heartbeat (10 s)
  eq(e.sentCmds.length, after, 'nessun altro tentativo dopo la prima risposta');
});

// ---------------------------------------------------------------- azioni: ACK, ordine, timeout
function sendAction(e, op, args) {
  const results = [];
  e.DC.bridge.command(367, op, args || {}, (err, ack, kind) => results.push({ err, ack, kind }));
  const cmd = e.lastCmd();
  eq(cmd.cmd, 'DC_CMD'); eq(cmd.params.op, op);
  return { rid: cmd.params.rid, results };
}

test('azione: risposta dell\'hub poi ACK => callback UNA volta, senza errore', () => {
  const e = makeEnv(); e.DC.bridge.start();
  const a = sendAction(e, 'PAUSE');
  e.deliver({ v: 1, ok: true, queued: true, id: 'w1', controller: 367, op: 'PAUSE', rid: a.rid });
  eq(a.results.length, 0, 'non ancora: manca l\'ACK');
  e.deliver({ v: 1, type: 'ACK', id: 'w1', op: 'PAUSE', ok: true, controller: 367 });
  eq(a.results.length, 1); eq(a.results[0].err, null); eq(a.results[0].ack.id, 'w1');
  e.advance(20000);
  eq(a.results.length, 1, 'nessun timeout dopo l\'ACK');
});

test('azione: ACK che arriva PRIMA della risposta dell\'hub viene bufferizzato e collegato (non si perde)', () => {
  const e = makeEnv(); e.DC.bridge.start();
  const a = sendAction(e, 'SET_MODE', { mode: 'Brightness Only' });
  e.deliver({ v: 1, type: 'ACK', id: 'w7', op: 'SET_MODE', ok: true, controller: 367 });   // ordine invertito
  eq(a.results.length, 0, 'l\'ACK da solo non basta a identificare l\'azione');
  e.deliver({ v: 1, ok: true, queued: true, id: 'w7', controller: 367, op: 'SET_MODE', rid: a.rid });
  eq(a.results.length, 1, 'collegato appena arriva la risposta');
  eq(a.results[0].err, null);
  truthy(/ACK anticipato collegato id=w7/.test(e.log()), 'si vede nel log');
  e.advance(20000);
  eq(a.results.length, 1, 'e non scade piu\'');
});

test('azione: ACK negativo => errore "rejected" col messaggio del controller', () => {
  const e = makeEnv(); e.DC.bridge.start();
  const a = sendAction(e, 'RESUME');
  e.deliver({ v: 1, ok: true, queued: true, id: 'w2', controller: 367, op: 'RESUME', rid: a.rid });
  e.deliver({ v: 1, type: 'ACK', id: 'w2', op: 'RESUME', ok: false, error: 'operazione non consentita nello stato ACTIVE' });
  eq(a.results.length, 1); eq(a.results[0].kind, 'rejected');
  truthy(/non consentita/.test(a.results[0].err));
});

test('azione: errore dell\'hub (ok:false con rid) => callback subito, kind "rejected"', () => {
  const e = makeEnv(); e.DC.bridge.start();
  const a = sendAction(e, 'SET_NUM_SP', { count: 99 });
  e.deliver({ v: 1, ok: false, error: 'count: fuori range', rid: a.rid });
  eq(a.results.length, 1); eq(a.results[0].kind, 'rejected');
});

test('timeout a 8 s: nessuna risposta dell\'hub => "hub-reply-missing" nel log, kind "timeout", poi GET_STATE di riallineamento', () => {
  const e = makeEnv(); e.DC.bridge.start();
  const a = sendAction(e, 'PREVIEW');
  const before = e.sentCmds.length;
  e.advance(7900);
  eq(a.results.length, 0, 'prima di 8 s non scade');
  e.advance(200);
  eq(a.results.length, 1); eq(a.results[0].kind, 'timeout');
  truthy(new RegExp('TIMEOUT rid=' + a.rid + ' op=PREVIEW ms=\\d+ stage=hub-reply-missing').test(e.log()), 'riga TIMEOUT con rid, op, ms e stage');
  truthy(e.sentCmds.slice(before).some(c => c.cmd === 'DC_GET_STATE' && c.params.controller === 367), 'la UI si riallinea a com\'e\' davvero');
});

test('timeout a 8 s: risposta dell\'hub arrivata ma niente ACK => "ack-missing" (si capisce quale salto e\' saltato)', () => {
  const e = makeEnv(); e.DC.bridge.start();
  const a = sendAction(e, 'SET_CT_LIMITS', { min: 2400, max: 6000 });
  e.deliver({ v: 1, ok: true, queued: true, id: 'w9', controller: 367, op: 'SET_CT_LIMITS', rid: a.rid });
  e.advance(8100);
  eq(a.results.length, 1); eq(a.results[0].kind, 'timeout');
  truthy(/stage=ack-missing/.test(e.log()) && /id=w9/.test(e.log()));
});

// ---------------------------------------------------------------- poll: mai avvisi
test('poll senza risposta: solo log "TIMEOUT ... (poll)", MAI un errore verso l\'utente', () => {
  const e = makeEnv(); e.DC.bridge.start();
  e.advance(25000);                                     // PING e LIST restano senza risposta
  eq(e.events.filter(x => x.evt === 'error').length, 0, 'nessun evento "error" (che farebbe comparire un avviso)');
  truthy(/TIMEOUT rid=\S+ op=DC_PING ms=\d+ stage=hub-reply-missing \(poll/.test(e.log()), 'ma il log lo registra');
});

test('risposte ai poll collegate per rid e registrate (RX con ms)', () => {
  const e = makeEnv(); e.DC.bridge.start();
  const rid = e.sentCmds[0].params.rid;
  e.advance(120);
  e.deliver({ v: 1, ok: true, controllers: 1, language: 'it', protocol: 1, rid });
  truthy(new RegExp('TX rid=' + rid + ' op=DC_PING').test(e.log()));
  truthy(new RegExp('RX rid=' + rid + ' op=DC_PING ms=120').test(e.log()), 'ms misurati sul tempo finto');
  truthy(e.events.some(x => x.evt === 'language' && x.arg === 'it'));
});

// ---------------------------------------------------------------- limitatore degli avvisi
test('limitatore: al piu\' un avviso ogni 30 s per la stessa op; op diverse indipendenti', () => {
  const e = makeEnv();
  const allow = (k, t) => e.DC.throttle.allow(k, 30000, t);
  eq(allow('toast:PAUSE', 0), true);
  eq(allow('toast:PAUSE', 29999), false, 'ancora dentro la finestra');
  eq(allow('toast:RESUME', 100), true, 'altra op');
  eq(allow('toast:PAUSE', 30000), true, 'finestra scaduta');
});

console.log('  -- ' + pass + ' PASS, ' + fail + ' FAIL');
process.exit(fail ? 1 : 0);
