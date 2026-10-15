/* ============================================================
 * bridge.js - canale pagina <-> driver webview (protocollo v1, docs/ARCHITECTURE.md §3b)
 *
 * Fatti verificati su T4/app (non toccare senza riprovare su hardware):
 *  - C4.sendCommand(nome, params, false, TRUE): true = al protocollo (driver Lua);
 *    subscribeToDataToUi(true) = DATA_TO_UI del protocollo (C4:SendDataToUI).
 *  - Il valore di ritorno di UIRequest NON arriva alla pagina: le risposte tornano come
 *    push; ogni richiesta porta un "rid" che il driver rimanda per collegarla alla risposta.
 *  - Gli oggetti annidati nei parametri si perdono: "args" viaggia come stringa JSON.
 *  - I messaggi arrivano come {"devicecommand":{...,"static":"<JSON>"}}: si cerca
 *    ricorsivamente un oggetto {v:1,...}, anche dentro stringhe JSON annidate.
 *  - Navigator non ricarica una webview aperta: URL_CHANGED (Rebuild WebView) arriva come
 *    DATA_TO_UI del proxy e la pagina si ricarica cambiando solo la query.
 *
 * Una azione (command) ha DUE conferme, nell'ordine in cui il driver le manda:
 *   1. la risposta dell'hub  { ok, queued, id, rid }  (il driver ha preso la richiesta)
 *   2. l'ACK del controller  { type:"ACK", id }        (il controller l'ha eseguita)
 * L'ordine di arrivo in pagina NON e' garantito: un ACK che precede la risposta dell'hub
 * viene tenuto in un buffer e collegato appena arriva la risposta (altrimenti si perderebbe
 * e l'azione scadrebbe pur essendo riuscita).
 *
 * Diagnosi sul campo (?debug=1 mostra il log a schermo, altrimenti solo console): ogni richiesta
 * lascia "TX rid op", ogni risposta "RX rid op ms", ogni scadenza "TIMEOUT rid op ms stage=..."
 * dove stage dice quale conferma e' mancata. Confrontato col log del driver ([HUB] ...) e del
 * controller ([COMMS] ...) dice in quale dei quattro salti muore la risposta.
 * ============================================================ */
(function (DC) {
  'use strict';

  var PING_MS = 10000;          // heartbeat leggero (DC_PING)
  var RESYNC_MS = 30000;        // risincronizzazione completa (DC_LIST)
  var SILENCE_MS = 30000;       // nessun messaggio per tanto => connessione persa
  var CMD_TIMEOUT_MS = 8000;    // azioni dell'utente
  var STARTUP_RETRY_MS = 2000;  // se all'avvio nessuno risponde (iscrizione non ancora attiva su un T4 lento)
  var STARTUP_RETRIES = 12;
  var EARLY_TTL_MS = 30000, EARLY_MAX = 50;

  var listeners = {};
  var rid_base = String(new Date().getTime());
  var rid_seq = 0;
  var pending = {};             // rid -> { cb, hubId, timer, op, t0, controller }   azioni dell'utente
  var byHubId = {};             // id assegnato dall'hub -> rid
  var early = {};               // id hub -> { msg, t }   ACK arrivati prima della risposta dell'hub
  var sent = {};                // rid -> { op, t0 }      ogni richiesta (anche i poll), solo per la diagnosi
  var lastRx = 0;
  var everRx = false;
  var startedAt = 0;
  var startupTries = 0;
  var status = 'wait';

  function now() { return new Date().getTime(); }
  function on(evt, fn) { (listeners[evt] = listeners[evt] || []).push(fn); }
  function emit(evt, arg) { var l = listeners[evt] || []; for (var i = 0; i < l.length; i++) { try { l[i](arg); } catch (e) { DC.log('listener ' + evt + ': ' + e); } } }

  function hasC4() { return typeof window.C4 === 'object' && window.C4 !== null && typeof window.C4.sendCommand === 'function'; }

  function opName(cmd, params) { return (cmd === 'DC_CMD' && params && params.op) ? params.op : cmd; }

  // ---------------------------------------------------------------- invio
  function send(cmd, params) {
    var p = {}, k;
    for (k in (params || {})) { if (Object.prototype.hasOwnProperty.call(params, k)) { p[k] = params[k]; } }
    if (p.args && typeof p.args === 'object') { p.args = JSON.stringify(p.args); }
    var rid = rid_base + '-' + (++rid_seq);
    p.rid = rid;
    var op = opName(cmd, p);
    sent[rid] = { op: op, t0: now() };
    DC.log('TX rid=' + rid + ' op=' + op);
    if (!hasC4()) { DC.log('API C4 non disponibile: ' + cmd); return rid; }
    try { window.C4.sendCommand(cmd, JSON.stringify(p), false, true); }
    catch (e) { DC.log('sendCommand ' + cmd + ' ERRORE: ' + e); }
    return rid;
  }

  // command(controllerId, op, args, cb(err, ack, kind)): scrive e aspetta l'ACK del controller.
  // E' SEMPRE un'azione dell'utente (i poll non passano da qui): solo per queste si avvisa l'utente.
  // kind: 'timeout' | 'rejected' (errore dell'hub o ACK negativo) | null
  function command(controllerId, op, args, cb) {
    var rid = send('DC_CMD', { controller: controllerId, op: op, args: args || {} });
    var entry = { cb: cb, hubId: null, timer: null, op: op, t0: now(), controller: controllerId };
    entry.timer = setTimeout(function () { onTimeout(rid); }, CMD_TIMEOUT_MS);
    pending[rid] = entry;
    return rid;
  }

  function onTimeout(rid) {
    var e = pending[rid];
    if (!e) { return; }
    var stage = e.hubId
      ? 'ack-missing (risposta dell\'hub arrivata, id=' + e.hubId + '): perso driver->controller, controller->driver o driver->pagina'
      : 'hub-reply-missing: perso pagina->driver o driver->pagina';
    DC.log('TIMEOUT rid=' + rid + ' op=' + e.op + ' ms=' + (now() - e.t0) + ' stage=' + stage);
    finish(rid, DC.t('err.timeout'), null, 'timeout');
    if (e.controller !== undefined && e.controller !== null) { getState(e.controller); }   // riallinea la UI a com'e' davvero
  }

  function finish(rid, err, ack, kind) {
    var e = pending[rid];
    if (!e) { return; }
    clearTimeout(e.timer);
    delete pending[rid];
    delete sent[rid];
    if (e.hubId) { delete byHubId[e.hubId]; delete early[e.hubId]; }
    if (e.cb) { e.cb(err || null, ack || null, err ? (kind || 'rejected') : null); }
  }

  // ---------------------------------------------------------------- ricezione
  // Cerca messaggi {v:1,...} ovunque nel payload (anche in stringhe JSON annidate)
  function extract(resp) {
    var found = [];
    function walk(o, depth) {
      if (o === null || o === undefined || depth > 10) { return; }
      if (typeof o === 'string') {
        var c = o.charAt(0);
        if (c === '{' || c === '[') { try { walk(JSON.parse(o), depth + 1); } catch (e) { /* non JSON */ } }
        return;
      }
      if (Array.isArray(o)) { for (var i = 0; i < o.length; i++) { walk(o[i], depth + 1); } return; }
      if (typeof o === 'object') {
        if (o.v === 1) { found.push(o); return; }
        for (var k in o) { if (Object.prototype.hasOwnProperty.call(o, k)) { walk(o[k], depth + 1); } }
      }
    }
    walk(resp, 0);
    return found;
  }

  function checkUrlChanged(raw) {
    var m = /index\.html\?r=([A-Za-z0-9._-]+)/.exec(raw);
    if (!m) { return false; }
    var cur = /[?&]r=([A-Za-z0-9._-]+)/.exec(location.search);
    if (cur && cur[1] === m[1]) { return true; }
    DC.log('URL_CHANGED visto (r=' + m[1] + '): ricarico');
    setTimeout(function () { location.search = '?r=' + m[1]; }, 200);
    return true;
  }

  // ACK del controller: lo collega alla sua azione (anche se arriva prima della risposta dell'hub)
  function onAck(msg) {
    var rid = byHubId[msg.id];
    if (rid === undefined) {
      early[msg.id] = { msg: msg, t: now() };
      var ids = Object.keys(early);
      if (ids.length > EARLY_MAX) { delete early[ids[0]]; }
      DC.log('RX ack id=' + msg.id + ' op=' + msg.op + ' (nessuna azione collegata: in buffer)');
      return;
    }
    var e = pending[rid];
    DC.log('RX ack id=' + msg.id + ' rid=' + rid + ' op=' + (e ? e.op : msg.op) + (e ? ' ms=' + (now() - e.t0) : '') + (msg.ok === false ? ' ok=false' : ''));
    finish(rid, msg.ok === false ? (msg.error || 'error') : null, msg, 'rejected');
  }

  function handle(msg) {
    lastRx = now();
    everRx = true;
    if (msg.rid && sent[msg.rid]) {                           // risposta dell'hub a una nostra richiesta
      DC.log('RX rid=' + msg.rid + ' op=' + sent[msg.rid].op + ' ms=' + (now() - sent[msg.rid].t0) + (msg.ok === false ? ' ok=false' : ''));
      if (!pending[msg.rid]) { delete sent[msg.rid]; }
    }
    if (msg.rid && pending[msg.rid]) {
      if (msg.ok === false) { finish(msg.rid, msg.error || 'error', null, 'rejected'); }
      else if (msg.queued && msg.id) {
        pending[msg.rid].hubId = msg.id;
        byHubId[msg.id] = msg.rid;
        delete sent[msg.rid];
        var a = early[msg.id];
        if (a) {                                              // l'ACK era arrivato prima: ora si collega
          delete early[msg.id];
          DC.log('ACK anticipato collegato id=' + msg.id + ' rid=' + msg.rid);
          onAck(a.msg);
        }
      }
    }
    if (msg.type === 'ACK' && msg.id) { onAck(msg); }
    if (msg.language) { emit('language', msg.language); }
    if (msg.controllers && msg.controllers.length !== undefined && typeof msg.controllers !== 'number') { emit('list', msg.controllers); }
    else if (msg.type === 'STATE') { emit('state', msg); }
    else if (msg.type === 'PREVIEW') { emit('preview', msg); }
    else if (msg.type === 'ACK') { emit('ack', msg); }
    else if (msg.type === 'HELLO') { emit('hello', msg); }
    else if (msg.ok === false && !msg.rid) { emit('error', msg.error || 'error'); }
    evaluate();
  }

  window.onDataToUi = function (response) {
    var raw = typeof response === 'string' ? response : JSON.stringify(response);
    if (checkUrlChanged(raw)) { return; }
    var msgs = extract(response);
    for (var i = 0; i < msgs.length; i++) { handle(msgs[i]); }
  };
  window.onSubscribeToDataToUiError = function (m) { DC.log('subscribeToDataToUi ERRORE: ' + m); };
  window.onSendCommandError = function (m) { DC.log('sendCommand ERRORE: ' + m); };

  // ---------------------------------------------------------------- stato della connessione
  // wait = in attesa del primo messaggio, live = parla, error = muto da troppo
  function evaluate() {
    var t = now();
    var next;
    if (everRx) { next = (t - lastRx > SILENCE_MS) ? 'error' : 'live'; }
    else { next = (t - startedAt > SILENCE_MS) ? 'error' : 'wait'; }
    if (next !== status) { status = next; DC.log('connessione: ' + status); emit('status', status); }
    sweep(t);
  }

  // diagnosi: richieste di poll rimaste senza risposta (solo log: i poll non avvisano mai l'utente)
  function sweep(t) {
    var rid;
    for (rid in sent) {
      if (Object.prototype.hasOwnProperty.call(sent, rid) && !pending[rid] && t - sent[rid].t0 > CMD_TIMEOUT_MS) {
        DC.log('TIMEOUT rid=' + rid + ' op=' + sent[rid].op + ' ms=' + (t - sent[rid].t0) + ' stage=hub-reply-missing (poll, nessun avviso)');
        delete sent[rid];
      }
    }
    for (var id in early) {
      if (Object.prototype.hasOwnProperty.call(early, id) && t - early[id].t > EARLY_TTL_MS) { delete early[id]; }
    }
  }

  // Su un T4 lento l'iscrizione ai DATA_TO_UI puo' non essere ancora attiva quando parte la
  // prima richiesta: una risposta mandata prima andrebbe persa. Finche' nessuno risponde, si riprova.
  function startupRetry() {
    if (everRx || startupTries >= STARTUP_RETRIES) { return; }
    startupTries++;
    DC.log('avvio: nessuna risposta, riprovo (' + startupTries + '/' + STARTUP_RETRIES + ')');
    send('DC_PING', {});
    send('DC_LIST', {});
    setTimeout(startupRetry, STARTUP_RETRY_MS);
  }

  function start() {
    startedAt = now();
    if (hasC4()) {
      // ORDINE: prima l'iscrizione, poi qualunque richiesta (window.onDataToUi e' gia' definita sopra).
      // true = DATA_TO_UI del protocollo (C4:SendDataToUI del driver Lua)
      try { window.C4.subscribeToDataToUi(true); DC.log('subscribeToDataToUi(true)'); }
      catch (e) { DC.log('subscribeToDataToUi ERRORE: ' + e); }
      // proxy: URL_CHANGED (Rebuild WebView); innocuo se non consegna nulla
      try { window.C4.subscribeToDataToUi(false); } catch (e2) { DC.log('subscribeToDataToUi(false) ERRORE: ' + e2); }
      send('DC_PING', {});
      send('DC_LIST', {});
      setTimeout(startupRetry, STARTUP_RETRY_MS);
    } else {
      DC.log('window.C4 assente: pagina fuori da Navigator');
    }
    setInterval(function () { if (hasC4()) { send('DC_PING', {}); } }, PING_MS);
    setInterval(function () { if (hasC4()) { send('DC_LIST', {}); } }, RESYNC_MS);
    setInterval(evaluate, 2000);
    evaluate();
  }

  function getState(id) { send('DC_GET_STATE', { controller: id }); }

  DC.bridge = {
    start: start, on: on, send: send, command: command, hasC4: hasC4,
    status: function () { return status; },
    list: function () { send('DC_LIST', {}); },
    getState: getState
  };
})(window.DC = window.DC || {});
