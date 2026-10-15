/* ============================================================
 * main.js - avvio, stato applicazione, TopBar, schede e collegamento al protocollo v1.
 *
 * La pagina e' una vista del controller: le proprieta' del driver sono la fonte di verita'
 * (docs/ARCHITECTURE.md §3c). Ogni modifica parte come richiesta, il controller scrive le
 * proprie proprieta', ricostruisce la curva e rimanda lo STATE: la UI si aggiorna da quello.
 * Stati della pagina: caricamento (skeleton) / nessun controller (card vuota) / app.
 * ============================================================ */
(function (DC) {
  'use strict';
  var h = DC.h, t = DC.t, clamp = DC.clamp;

  var MODES = [
    { value: 'Brightness + Colour Temperature', key: 'both' },
    { value: 'Brightness Only', key: 'brightness' },
    { value: 'Colour Temperature Only', key: 'cct' }
  ];
  var CT_MIN = 1600, CT_MAX = 6500, CT_STEP = 100;
  var MAX_SP = 10, MIN_SP = 3;
  var STORE_KEY = 'dc.controller';

  var app = {
    ctrls: {},            // id -> { id, name, state, preview }
    selected: null,
    listReceived: false,
    status: 'wait',
    view: null            // 'loading' | 'empty' | 'app'
  };
  var ui = {};            // riferimenti ai nodi costruiti
  var sheet = null;
  var numSpTimer = null;

  // ---------------------------------------------------------------- stato
  function cur() { return app.selected !== null ? app.ctrls[app.selected] : null; }
  function ensure(id) {
    if (!app.ctrls[id]) { app.ctrls[id] = { id: id, name: null, state: null, preview: null }; }
    return app.ctrls[id];
  }
  function ids() { return Object.keys(app.ctrls).map(Number).sort(function (a, b) { return a - b; }); }

  function chooseSelected() {
    var list = ids();
    if (!list.length) { app.selected = null; return; }
    if (app.selected !== null && app.ctrls[app.selected]) { return; }
    var saved = parseInt(DC.storage.get(STORE_KEY), 10);
    app.selected = (!isNaN(saved) && app.ctrls[saved]) ? saved : list[0];
  }

  function isPreview(c) { return !!(c && ((c.preview && c.preview.active) || (c.state && c.state.state === 'PREVIEW'))); }

  function modeKey(mode) {
    for (var i = 0; i < MODES.length; i++) { if (MODES[i].value === mode) { return MODES[i].key; } }
    return 'both';
  }

  // ---------------------------------------------------------------- comandi verso il controller
  // Azione dell'utente verso il controller (Applica, Elimina, pulsanti azione, drag, slider...).
  // E' l'UNICO punto che avvisa l'utente di un fallimento: i poll in background (DC_PING/DC_LIST/
  // DC_GET_STATE) non passano di qui e non producono mai un avviso. Al piu' un avviso ogni 30 s per
  // la stessa op; il resto va solo nel log (?debug=1).
  var TOAST_WINDOW_MS = 30000;
  function command(op, args, cb) {
    var c = cur();
    if (!c) { return; }
    DC.bridge.command(c.id, op, args, function (err, ack, kind) {
      if (err) {
        if (DC.throttle.allow('toast:' + op, TOAST_WINDOW_MS)) { DC.toast(t('err.prefix', { msg: err }), 'error'); }
        else { DC.log('avviso soppresso (dedupe ' + (TOAST_WINDOW_MS / 1000) + ' s) op=' + op + ' kind=' + kind + ' err=' + err); }
      }
      if (cb) { cb(err, ack); }
    });
  }

  // ---------------------------------------------------------------- TopBar
  function buildTopbar() {
    var bar = document.getElementById('topbar');
    DC.clear(bar);
    ui.dot = h('span', { class: 'conn-dot', 'data-state': app.status, role: 'status' });
    var left = h('div', { class: 'tb-left' }, [ui.dot]);   // niente titolo e niente icone senza azione in TopBar

    ui.pill = h('button', { type: 'button', class: 'ctrl-pill', 'aria-haspopup': 'listbox' });
    ui.pill.addEventListener('click', toggleCtrlMenu);
    ui.menuHost = h('div', { class: 'tb-center' }, [ui.pill]);

    ui.badge = h('span', { class: 'badge-preview', hidden: true, text: t('preview.badge') });
    var help = h('button', { type: 'button', class: 'icon-btn', 'aria-label': t('help.title'), html: DC.icon('help') });
    help.addEventListener('click', openHelp);
    var right = h('div', { class: 'tb-right' }, [ui.badge, help]);

    bar.appendChild(left); bar.appendChild(ui.menuHost); bar.appendChild(right);
    updateTopbar();
  }

  function updateTopbar() {
    if (!ui.pill) { return; }
    ui.dot.setAttribute('data-state', app.status);
    ui.dot.title = t('conn.' + app.status);
    var c = cur(), list = ids();
    DC.clear(ui.pill);
    ui.pill.appendChild(h('span', { html: DC.icon('monitor') }));
    ui.pill.appendChild(h('span', { class: 'ctrl-name', text: c ? (c.name || ('#' + c.id)) : t('ctrl.none') }));
    if (c) { ui.pill.appendChild(h('span', { class: 'ctrl-chip', text: '#' + c.id })); }
    var multi = list.length > 1;
    if (multi) { ui.pill.appendChild(h('span', { class: 'chev', html: DC.icon('chevron') })); }   // e' un dropdown
    ui.pill.disabled = !multi;
    ui.badge.hidden = !isPreview(c);
    ui.badge.textContent = t('preview.badge');
  }

  function toggleCtrlMenu() {
    var old = document.getElementById('ctrl-menu');
    if (old) { old.parentNode.removeChild(old); return; }
    var list = ids();
    if (list.length < 2) { return; }
    var menu = h('div', { class: 'ctrl-menu', id: 'ctrl-menu', role: 'listbox' });
    list.forEach(function (id) {
      var c = app.ctrls[id];
      var b = h('button', { type: 'button', role: 'option', 'aria-selected': id === app.selected ? 'true' : 'false' },
        [h('span', { text: c.name || ('#' + id) }), h('span', { class: 'sub', text: (c.state ? c.state.state : '?') + ' · #' + id })]);
      b.addEventListener('click', function () {
        menu.parentNode.removeChild(menu);
        if (id !== app.selected) { selectController(id); }
      });
      menu.appendChild(b);
    });
    ui.menuHost.appendChild(menu);
  }

  function selectController(id) {
    app.selected = id;
    DC.storage.set(STORE_KEY, String(id));
    if (sheet && sheet.isOpen()) { sheet.close(); }
    var c = cur();
    if (c && !c.state) { DC.bridge.getState(id); }
    render(true);
  }

  function openHelp() {
    var root = document.getElementById('modal-root');
    var scrim = h('div', { class: 'modal-scrim' });
    function close() { if (scrim.parentNode) { scrim.parentNode.removeChild(scrim); } }
    var ok = h('button', { type: 'button', class: 'btn-primary', style: 'padding:0 24px', text: t('help.close') });
    ok.addEventListener('click', close);
    scrim.addEventListener('click', function (e) { if (e.target === scrim) { close(); } });
    scrim.appendChild(h('div', { class: 'modal', role: 'dialog' }, [
      h('h2', { text: t('help.title') }),
      h('ul', null, [1, 2, 3, 4].map(function (i) { return h('li', { text: t('help.' + i) }); })),
      h('div', { class: 'modal-foot' }, [ok])
    ]));
    root.appendChild(scrim);
  }

  // ---------------------------------------------------------------- viste: skeleton / vuoto / app
  function viewKind() {
    var c = cur();
    if (app.listReceived && !ids().length) { return 'empty'; }
    if (c && c.state) { return 'app'; }
    return 'loading';
  }

  function sk(w, hgt, extra) { return h('div', { class: 'sk', style: 'width:' + w + ';height:' + hgt + ';' + (extra || '') }); }

  function buildSkeleton(main) {
    var left = h('section', { class: 'card curve-card skeleton' }, [
      h('div', { style: 'display:flex;justify-content:space-between;gap:12px' }, [sk('200px', '24px'), sk('160px', '20px')]),
      sk('100%', '100%', 'flex:1 1 auto;min-height:180px;border-radius:12px'),
      h('div', { style: 'display:flex;gap:8px' }, [sk('150px', '48px', 'border-radius:9999px'), sk('110px', '48px', 'border-radius:9999px'), sk('110px', '48px', 'border-radius:9999px')])
    ]);
    var right = h('section', { class: 'card config-card skeleton' }, [
      sk('70%', '20px'), sk('100%', '48px'), sk('100%', '110px'), sk('100%', '64px')
    ]);
    main.appendChild(left); main.appendChild(right);
  }

  function buildEmpty(main) {
    var refresh = h('button', { type: 'button', class: 'pill-btn primary', html: DC.icon('refresh') }, [t('empty.refresh')]);
    refresh.addEventListener('click', function () { DC.bridge.list(); });
    main.appendChild(h('div', { class: 'empty-wrap' }, [
      h('div', { class: 'card empty-card' }, [
        h('div', { class: 'empty-ico', html: DC.icon('bulb') }),
        h('h2', { text: t('empty.title') }),
        h('p', { text: t('empty.text') }),
        refresh
      ])
    ]));
  }

  // pillola di azione rapida
  function pill(iconName, label, onClick) {
    var b = h('button', { type: 'button', class: 'pill-btn', html: DC.icon(iconName) }, [label]);
    b.addEventListener('click', onClick);
    return b;
  }

  function buildApp(main) {
    // ---- scheda curva
    ui.title2 = h('h1', { text: t('curve.title') });
    ui.sub = h('div', { class: 'sub' });
    ui.readout = h('div', { class: 'live-readout' }, [h('span', { class: 'dot' }), h('span', { class: 'txt' })]);
    ui.simPill = h('div', { class: 'sim-banner', hidden: true }, [h('span', { class: 'rec' }), h('span', { class: 'txt' })]);
    var head = h('div', { class: 'curve-head' }, [h('div', null, [ui.title2, ui.sub]), h('div', null, [ui.readout, ui.simPill])]);

    ui.chartWrap = h('div', { class: 'chart-wrap' });
    ui.glow = h('div', { class: 'chart-glow' });
    ui.chartWrap.appendChild(ui.glow);
    DC.glow.attach(ui.glow);
    ui.curve = new DC.CurveRenderer(ui.chartWrap, {
      onTap: function (n) { openSheet(n); },
      onCommit: function (n, args, cb) { command('SET_SWITCHPOINT', args, cb); },
      onFreeze: function (r) { DC.glow.freeze(r); },
      onRelease: function (r) { DC.glow.release(r); },
      onNow: onNow
    });

    ui.btnPreview = pill('play', t('act.preview'), function () {
      var c = cur();
      command(isPreview(c) ? 'STOP_PREVIEW' : 'PREVIEW', {});
    });
    ui.btnPause = pill('pause', t('act.pause'), function () { command('PAUSE', {}); });
    ui.btnResume = pill('play', t('act.resume'), function () { command('RESUME', {}); });
    ui.btnFollow = pill('link', t('act.follow'), function () { command('FOLLOW', {}); });
    ui.followDot = h('span', { class: 'badge-dot', hidden: true });
    ui.btnFollow.appendChild(ui.followDot);
    var actions = h('div', { class: 'actions' }, [ui.btnPreview, ui.btnPause, ui.btnResume, ui.btnFollow]);

    var curveCard = h('section', { class: 'card curve-card' }, [head, ui.chartWrap, actions]);

    // ---- scheda configurazione
    ui.cfgTitle = h('h2', { text: t('cfg.title') });
    ui.status = h('span', { class: 'status-pill' });
    var cfgHead = h('div', { class: 'cfg-head' }, [ui.cfgTitle, ui.status]);

    ui.modeSeg = DC.Segmented({
      options: MODES.map(function (m) { return { value: m.value, label: t('mode.short.' + m.key) }; }),
      value: MODES[0].value,
      onChange: function (v) { command('SET_MODE', { mode: v }, function (err) { if (err) { render(true); } }); }
    });
    ui.secMode = h('div', { class: 'cfg-sec' }, [h('div', { class: 'eyebrow', text: t('cfg.mode') }), ui.modeSeg.el]);

    buildCtSliders();
    buildPoints();

    ui.lock = h('div', { class: 'lock-overlay', hidden: true, html: DC.icon('lock') }, [h('span', { text: t('cfg.locked') })]);
    var cfgCard = h('section', { class: 'card config-card' }, [cfgHead, ui.secMode, ui.secCt, ui.secPts, ui.lock]);
    ui.cfgCard = cfgCard;

    main.appendChild(curveCard);
    main.appendChild(cfgCard);

    sheet = new DC.ContextSheet(document.getElementById('sheet-root'), {
      command: function (op, args, cb) { command(op, args, cb); },
      onFreeze: function (r) { DC.glow.freeze(r); },
      onRelease: function (r) { DC.glow.release(r); },
      onOpen: function (n) { ui.curve.setActive(n); },
      onClose: function () { ui.curve.setActive(null); }
    });
  }

  function ctGradient() {
    var s = [], k;
    for (k = 0; k <= 8; k++) { s.push(DC.kelvinColor(CT_MIN + (CT_MAX - CT_MIN) * k / 8)); }
    return 'linear-gradient(90deg, ' + s.join(', ') + ')';
  }

  function buildCtSliders() {
    function box(label, slider, valEl) {
      return h('div', { class: 'slider-box' }, [h('div', { class: 'row' }, [h('span', { class: 'lbl', text: label }), valEl]), slider.el]);
    }
    ui.minVal = h('span', { class: 'val' });
    ui.maxVal = h('span', { class: 'val' });
    function paintVals() {
      ui.minVal.textContent = ui.minSlider.value + 'K'; ui.minVal.style.color = DC.kelvinColor(ui.minSlider.value);
      ui.maxVal.textContent = ui.maxSlider.value + 'K'; ui.maxVal.style.color = DC.kelvinColor(ui.maxSlider.value);
    }
    // clamp LIVE: min < max anche durante il drag, non solo al rilascio
    function bounds() {
      ui.minSlider.setBounds(CT_MIN, ui.maxSlider.value - CT_STEP);
      ui.maxSlider.setBounds(ui.minSlider.value + CT_STEP, CT_MAX);
    }
    function commit() {
      command('SET_CT_LIMITS', { min: ui.minSlider.value, max: ui.maxSlider.value }, function (err) { if (err) { render(true); } });
    }
    var common = {
      min: CT_MIN, max: CT_MAX, step: CT_STEP, gradient: ctGradient(),
      format: function (v) { return v + 'K'; },
      onStart: function () { DC.glow.freeze('slider'); },
      onEnd: function () { DC.glow.release('slider'); }
    };
    ui.minSlider = DC.Slider(Object.assign({}, common, { value: 2200, label: t('cfg.ct.min'), onInput: function () { bounds(); paintVals(); }, onCommit: commit }));
    ui.maxSlider = DC.Slider(Object.assign({}, common, { value: 6500, label: t('cfg.ct.max'), onInput: function () { bounds(); paintVals(); }, onCommit: commit }));
    ui.ctPaint = function () { bounds(); paintVals(); };
    ui.ctLabels = [h('span', { class: 'lbl', text: t('cfg.ct.min') }), h('span', { class: 'lbl', text: t('cfg.ct.max') })];
    ui.secCt = h('div', { class: 'cfg-sec' }, [
      h('div', { class: 'eyebrow', text: t('cfg.ct') }),
      h('div', { class: 'ct-sliders' }, [box(t('cfg.ct.min'), ui.minSlider, ui.minVal), box(t('cfg.ct.max'), ui.maxSlider, ui.maxVal)])
    ]);
  }

  function buildPoints() {
    ui.ptsCount = h('span', { class: 'mono' });
    ui.stepper = DC.Stepper({
      min: MIN_SP, max: MAX_SP, step: 1, value: 4,
      render: function (el, v) {
        DC.clear(el);
        el.appendChild(h('div', { class: 'big', text: t('cfg.points.n', { n: v }) }));
        el.appendChild(h('div', { class: 'small', text: t('cfg.points.sub') }));
        if (ui.ptsCount) { ui.ptsCount.textContent = t('cfg.points.count', { n: v, max: MAX_SP }); }
      },
      onChange: function (v) {                      // raccoglie i tocchi ripetuti e invia una volta sola
        clearTimeout(numSpTimer);
        numSpTimer = setTimeout(function () { command('SET_NUM_SP', { count: v }, function (err) { if (err) { render(true); } }); }, 600);
      }
    });
    ui.secPts = h('div', { class: 'cfg-sec' }, [
      h('div', { class: 'sec-head' }, [h('div', { class: 'eyebrow', text: t('cfg.points') }), ui.ptsCount]),
      h('div', { class: 'pts-box' }, [ui.stepper.el])
    ]);
  }

  // ---------------------------------------------------------------- aggiornamento dell'app dallo STATE
  function onNow(v) {
    var c = cur();
    if (!c || !ui.readout) { return; }
    if (!isPreview(c)) { DC.glow.set(v.k, v.b); }
    ui.readout.querySelector('.txt').textContent = t('curve.now', { time: DC.hhmm(v.minute), b: Math.round(v.b), k: Math.round(v.k / 100) * 100 });
  }

  function updateApp() {
    var c = cur(), st = c.state;
    var preview = isPreview(c);
    var paused = st.state === 'PAUSED';

    // intestazione
    ui.title2.textContent = t('curve.title');
    var simInfo = null;
    if (preview) {
      var pv = c.preview || {};
      var dur = pv.duration_s || (st.preview && st.preview.duration_s);
      var factor = dur ? Math.round(86400 / dur) : null;                    // reale: 24h / durata, mai "60x" fisso
      ui.sub.textContent = t('preview.banner', { f: factor !== null ? factor : '?' }).replace(' · ?x', '');
      ui.sub.style.color = 'var(--error)';
      if (typeof pv.minute === 'number') {
        var k = typeof pv.cct === 'number' ? pv.cct : 0, b = typeof pv.brightness === 'number' ? pv.brightness : 0;
        ui.simPill.querySelector('.txt').textContent = t('preview.sim', { time: DC.hhmm(pv.minute), b: Math.round(b), k: Math.round(k) });
        DC.glow.set(k || 4000, b);
        simInfo = true;
      }
    } else {
      ui.sub.textContent = t(paused ? 'curve.sub.paused' : 'curve.sub', { n: st.count, mode: t('mode.' + modeKey(st.mode)) });
      ui.sub.style.color = '';
    }
    ui.simPill.hidden = !simInfo;
    ui.readout.hidden = preview;

    // curva
    ui.curve.setState(st);
    ui.curve.setPreview(preview ? (c.preview || { active: true, minute: 0 }) : null);

    // azioni rapide
    var playing = isPreview(c);
    ui.btnPreview.className = 'pill-btn ' + (playing ? 'danger' : 'primary');
    ui.btnPreview.innerHTML = DC.icon(playing ? 'stop' : 'play');
    ui.btnPreview.appendChild(document.createTextNode(t(playing ? 'act.stop' : 'act.preview')));
    ui.btnPause.lastChild.textContent = t('act.pause');
    ui.btnResume.lastChild.textContent = t('act.resume');
    ui.btnPause.setAttribute('aria-disabled', st.state === 'ACTIVE' ? 'false' : 'true');   // vietata in PAUSED/PREVIEW/IDLE
    ui.btnResume.setAttribute('aria-disabled', paused ? 'false' : 'true');
    var overridden = false;
    (st.lights || []).forEach(function (l) { if (l.overridden) { overridden = true; } });
    ui.followDot.hidden = !overridden;                                                     // c'e' qualcosa da riallineare

    // configurazione
    var kind = preview ? 'preview' : (paused ? 'paused' : (st.state === 'ACTIVE' ? 'active' : 'idle'));
    ui.status.setAttribute('data-kind', kind);
    ui.status.textContent = t('cfg.status.' + kind);
    ui.modeSeg.setValue(st.mode);
    var ct = st.ct || { min: 2200, max: 6500 };
    ui.maxSlider.setValue(ct.max);
    ui.minSlider.setValue(ct.min);
    ui.ctPaint();
    ui.stepper.setValue(st.count || 4);
    ui.cfgCard.classList.toggle('locked', preview);
    ui.lock.hidden = !preview;

    // sheet aperta: aggiorna i dati di contorno o chiudila se l'SP non esiste piu'
    if (sheet && sheet.isOpen()) {
      if (sheet.n > st.count) { sheet.close(); } else { sheet.refresh(st); }
    }
  }

  function openSheet(n) {
    var c = cur();
    if (!c || !c.state || isPreview(c)) { return; }
    sheet.open(c.state, n, c.name || ('#' + c.id));
  }

  // ---------------------------------------------------------------- render
  var lastView = null;
  function render(force) {
    chooseSelected();
    updateTopbar();
    var kind = viewKind();
    var main = document.getElementById('main');
    if (kind !== lastView || force) {
      if (sheet && sheet.isOpen()) { sheet.destroy(); }
      DC.clear(main);
      ui.curve = null;
      if (kind === 'loading') { buildSkeleton(main); }
      else if (kind === 'empty') { buildEmpty(main); }
      else { buildApp(main); }
      lastView = kind;
    }
    if (kind === 'app') { updateApp(); }
    updateBanner();
  }

  function updateBanner() {
    var el = document.getElementById('banner');
    var lost = app.status === 'error';
    if (lost && el.hidden) {
      DC.clear(el);
      var b = h('button', { type: 'button', text: t('conn.reload') });
      b.addEventListener('click', function () { location.reload(); });
      el.appendChild(h('span', { text: t('conn.lost') }));
      el.appendChild(b);
    }
    el.hidden = !lost;
  }

  // ---------------------------------------------------------------- eventi dal canale
  function wire() {
    var b = DC.bridge;
    b.on('list', function (items) {
      app.listReceived = true;
      var seen = {};
      items.forEach(function (it) {
        if (it.bound === false) { return; }
        var c = ensure(it.id); seen[it.id] = true;
        if (it.name) { c.name = it.name; }
        if (it.state && it.state.type === 'STATE') { c.state = it.state; }
        if (!c.state) { b.getState(it.id); }
      });
      Object.keys(app.ctrls).forEach(function (k) { if (!seen[k]) { delete app.ctrls[k]; } });
      if (app.selected !== null && !app.ctrls[app.selected]) { app.selected = null; }
      render();
    });
    b.on('state', function (msg) {
      app.listReceived = true;
      var c = ensure(msg.controller);
      c.state = msg;
      if (msg.name) { c.name = msg.name; }
      if (!msg.preview || !msg.preview.active) { c.preview = null; }
      render();
    });
    b.on('preview', function (msg) {
      var c = ensure(msg.controller);
      c.preview = msg.active ? msg : null;
      if (cur() === c && viewKind() === 'app') { updateApp(); updateTopbar(); }
    });
    b.on('ack', function (msg) {
      if (msg.state && msg.state.type === 'STATE') { var c = ensure(msg.controller); c.state = msg.state; render(); }
    });
    b.on('hello', function (msg) { var c = ensure(msg.controller); if (msg.name) { c.name = msg.name; } updateTopbar(); });
    b.on('error', function (m) { DC.log('errore dal driver, nessun avviso (non e una azione dell utente): ' + m); });
    b.on('status', function (s) { app.status = s; updateTopbar(); updateBanner(); });
    b.on('language', function (l) { if (DC.i18n.setLang(l)) { document.title = t('app.title'); buildTopbar(); render(true); } });
  }

  // ---------------------------------------------------------------- avvio
  function start() {
    document.title = t('app.title');
    if (/[?&]debug=1/.test(location.search)) {
      var pre = document.getElementById('debug-log');
      pre.hidden = false;
      DC.attachLog(pre);
    }
    buildTopbar();
    document.title = t('app.title');
    wire();
    render(true);
    DC.bridge.start();
    setInterval(function () { if (ui.curve && viewKind() === 'app') { ui.curve.tick(); } }, 30000);
  }

  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); } else { start(); }
})(window.DC = window.DC || {});
