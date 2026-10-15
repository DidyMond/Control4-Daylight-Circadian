/* ============================================================
 * curve-renderer.js - curva circadiana in SVG inline.
 *
 * NON calcola la curva: disegna i 144 campioni {t, brightness, cct} del controller
 * (curve:samples(10), la STESSA monotone cubic che pilota le luci). L'unico calcolo
 * lato pagina e' una lettura lineare fra campioni per le etichette (ora, Kelvin).
 *
 * Interazioni:
 *  - tap su un marker SP  -> hooks.onTap(n) (apre la ContextSheet)
 *  - drag di un marker    -> sposta tempo/luminosita'; SET_SWITCHPOINT SOLO al rilascio
 *                            (a ogni movimento le luci reali si riallineerebbero)
 *  - press-and-hold 500 ms sul gradiente CT -> rivela la curva CT sovrapposta
 * Durante il drag il GlowLayer e' congelato (hooks.onFreeze / onRelease).
 * ============================================================ */
(function (DC) {
  'use strict';
  var s = DC.s, clamp = DC.clamp, t = DC.t;

  var ASTRO = ['sunrise', 'solar_noon', 'sunset', 'solar_midnight'];
  var REF_KEY = { 'Sunrise': 'sunrise', 'Solar Noon': 'solar_noon', 'Sunset': 'sunset', 'Solar Midnight': 'solar_midnight' };
  var MODE_CCT = 'Colour Temperature Only', MODE_BRI = 'Brightness Only';
  var SNAP_MIN = 5;             // passo del drag orizzontale (minuti); il dettaglio fine sta nella ContextSheet
  var TAP_PX = 6, HOLD_MS = 500, SETTLE_MS = 2500;
  var L = 38, R = 48, TOP = 34, BOTTOM = 62;

  function CurveRenderer(host, hooks) {
    var self = this;
    this.host = host;
    this.hooks = hooks || {};
    this.svg = s('svg', { 'class': 'chart', role: 'img' });
    host.appendChild(this.svg);
    this.state = null;
    this.preview = null;
    this.locked = false;
    this.activeSp = null;
    this.drag = null;
    this.committing = null;      // n dello SP inviato al controller e in attesa di conferma
    this.pendingState = null;
    this.settleTimer = null;
    this.holdTimer = null;
    this.g = null;
    if (window.ResizeObserver) { new ResizeObserver(function () { self.render(); }).observe(host); }
    else { window.addEventListener('resize', function () { self.render(); }); }
  }
  var P = CurveRenderer.prototype;

  // ---------------------------------------------------------------- API
  P.setState = function (state) {
    if (this.drag && this.drag.moved) { this.pendingState = state; return; }   // niente re-render sotto il dito
    this.state = state;
    this.render();
  };

  P.setPreview = function (pv) {
    this.preview = (pv && pv.active) ? pv : null;
    this.locked = !!this.preview;
    this.renderPreview();
    this.renderNow();
    this.svg.classList.toggle('locked', this.locked);
  };

  P.setActive = function (n) { this.activeSp = n; this.render(); };
  P.tick = function () { this.renderNow(); };

  // ---------------------------------------------------------------- geometria
  P.geometry = function () {
    var r = this.host.getBoundingClientRect();
    var W = Math.max(240, r.width), H = Math.max(160, r.height);
    var g = { W: W, H: H, L: L, R: R, T: TOP, B: BOTTOM };
    g.w = W - L - R;
    g.h = Math.max(40, H - TOP - BOTTOM);
    g.barY = TOP + g.h + 10;
    g.barH = 10;
    g.X = function (m) { return L + (m / 1440) * g.w; };
    g.Yb = function (b) { return TOP + g.h - (clamp(b, 0, 100) / 100) * g.h; };
    var ct = (this.state && this.state.ct) || { min: 1600, max: 6500 };
    var span = Math.max(1, ct.max - ct.min);
    g.Yc = function (k) { return TOP + g.h - (clamp((k - ct.min) / span, 0, 1)) * g.h; };
    g.ct = ct;
    return g;
  };

  // ---------------------------------------------------------------- render completo
  P.render = function () {
    var svg = this.svg, st = this.state;
    DC.clear(svg);
    this.g = null;
    if (!st || !st.curve || !st.curve.samples) { return; }
    var g = this.geometry();
    this.g = g;
    svg.setAttribute('viewBox', '0 0 ' + g.W + ' ' + g.H);
    svg.classList.toggle('mode-cct', st.mode === MODE_CCT);
    svg.classList.toggle('mode-b', st.mode === MODE_BRI);
    svg.classList.toggle('locked', this.locked);

    var smp = st.curve.samples;
    var i, m, x, y;

    // gradienti
    var stops = [];
    for (i = 0; i < smp.length; i += 2) {
      stops.push(s('stop', { offset: (smp[i][0] / 1440).toFixed(4), 'stop-color': DC.kelvinColor(smp[i][2]) }));
    }
    stops.push(s('stop', { offset: '1', 'stop-color': DC.kelvinColor(smp[0][2]) }));
    var defs = s('defs', null, [
      s('linearGradient', { id: 'ctgrad', x1: '0', y1: '0', x2: '1', y2: '0' }, stops),
      s('linearGradient', { id: 'areagrad', x1: '0', y1: '0', x2: '0', y2: '1' }, [
        s('stop', { offset: '0', 'stop-color': '#adc6ff', 'stop-opacity': '0.22' }),
        s('stop', { offset: '1', 'stop-color': '#adc6ff', 'stop-opacity': '0' })
      ])
    ]);
    svg.appendChild(defs);

    // griglia verticale ogni 2h + etichette orarie
    var full = g.w / 12 >= 40;
    for (m = 0; m <= 1440; m += 120) {
      x = g.X(m);
      svg.appendChild(s('line', { x1: x, y1: g.T, x2: x, y2: g.T + g.h, 'class': 'grid' }));
      if (full || (m % 240 === 0)) {
        svg.appendChild(s('text', { x: x, y: g.H - 6, 'class': 'hour', text: full ? (m === 1440 ? '24:00' : DC.hhmm(m)) : DC.pad2(m / 60) }));
      }
    }
    // griglia orizzontale ogni 20% + asse sinistro; asse destro in Kelvin
    for (i = 0; i <= 5; i++) {
      y = g.Yb(i * 20);
      svg.appendChild(s('line', { x1: g.L, y1: y, x2: g.L + g.w, y2: y, 'class': 'grid h' }));
      svg.appendChild(s('text', { x: g.L - 6, y: y + 3, 'class': 'axis-l', 'text-anchor': 'end', text: (i * 20) + '%' }));
      var kv = Math.round((g.ct.min + (g.ct.max - g.ct.min) * (i / 5)) / 100) * 100;
      svg.appendChild(s('text', { x: g.L + g.w + 6, y: y + 3, 'class': 'axis-r', 'text-anchor': 'start', text: kv + 'K' }));
    }

    this.drawAstro(g, st);

    // curve: brightness (area + linea) e CT (nascosta finche' non si tiene premuto il gradiente)
    var pb = [], pc = [];
    for (i = 0; i < smp.length; i++) {
      pb.push((i ? 'L' : 'M') + g.X(smp[i][0]).toFixed(1) + ' ' + g.Yb(smp[i][1]).toFixed(1));
      pc.push((i ? 'L' : 'M') + g.X(smp[i][0]).toFixed(1) + ' ' + g.Yc(smp[i][2]).toFixed(1));
    }
    pb.push('L' + g.X(1440).toFixed(1) + ' ' + g.Yb(smp[0][1]).toFixed(1));     // ciclica: chiude a mezzanotte
    pc.push('L' + g.X(1440).toFixed(1) + ' ' + g.Yc(smp[0][2]).toFixed(1));
    svg.appendChild(s('path', { d: pb.join(' ') + ' L' + g.X(1440) + ' ' + g.Yb(0) + ' L' + g.X(0) + ' ' + g.Yb(0) + ' Z', 'class': 'curve-area', fill: 'url(#areagrad)' }));
    svg.appendChild(s('path', { d: pb.join(' '), 'class': 'curve-b' }));
    svg.appendChild(s('path', { d: pc.join(' '), 'class': 'curve-ct' }));

    this.drawCtBar(g, st);

    this.gNow = s('g', { 'class': 'now' });
    svg.appendChild(this.gNow);
    this.gPreview = s('g', { 'class': 'pv' });
    svg.appendChild(this.gPreview);
    this.gMarkers = s('g', { 'class': 'markers' });
    svg.appendChild(this.gMarkers);
    this.drawMarkers(g, st);
    this.gTip = s('g', { 'class': 'tip' });
    svg.appendChild(this.gTip);
    this.renderNow();
    this.renderPreview();
  };

  // linee e tag delle posizioni astronomiche (alba / mezzogiorno / tramonto / mezzanotte)
  P.drawAstro = function (g, st) {
    var a = st.astro;
    if (!a) { return; }
    var list = [];
    ASTRO.forEach(function (key) {
      if (key === 'solar_midnight' && g.w < 420) { return; }          // poco spazio: i tag si accavallerebbero
      if (typeof a[key] === 'number' && a[key] > 0 && a[key] < 1440) { list.push({ key: key, m: a[key] }); }
    });
    list.sort(function (p, q) { return p.m - q.m; });
    var rows = [-1e9, -1e9];                         // fine (px) dell'ultimo tag per riga
    list.forEach(function (it) {
      var x = g.X(it.m);
      var label = t('astro.' + it.key) + ' ' + DC.hhmm(it.m);
      var wTag = label.length * 6.3 + 12;
      var row = (x - wTag / 2 > rows[0] + 4) ? 0 : ((x - wTag / 2 > rows[1] + 4) ? 1 : 0);
      rows[row] = x + wTag / 2;
      var ty = 2 + row * 16;
      var cx = clamp(x, g.L + wTag / 2, g.L + g.w - wTag / 2);
      this.svg.appendChild(s('line', { x1: x, y1: ty + 14, x2: x, y2: g.T + g.h, 'class': 'astro-line' }));
      this.svg.appendChild(s('g', { 'class': 'astro-tag' }, [
        s('rect', { x: cx - wTag / 2, y: ty, width: wTag, height: 14, rx: 4 }),
        s('text', { x: cx, y: ty + 10.5, text: label })
      ]));
    }, this);
  };

  // barra del gradiente CT TEMPORALE (caldo -> freddo -> caldo) + etichette Kelvin
  P.drawCtBar = function (g, st) {
    var svg = this.svg, smp = st.curve.samples, self = this;
    svg.appendChild(s('rect', { x: g.L, y: g.barY, width: g.w, height: g.barH, 'class': 'ct-bar', fill: 'url(#ctgrad)' }));
    var marks = [{ m: 0, a: 'start' }];
    var a = st.astro;
    if (a) {
      if (typeof a.sunrise === 'number') { marks.push({ m: a.sunrise, a: 'middle' }); }
      if (typeof a.solar_noon === 'number') { marks.push({ m: a.solar_noon, a: 'middle' }); }
      if (typeof a.sunset === 'number') { marks.push({ m: a.sunset, a: 'middle' }); }
    } else {
      marks.push({ m: 720, a: 'middle' });
    }
    marks.push({ m: 1440, a: 'end' });
    var lastX = -1e9, kept = [];
    marks.forEach(function (mk, idx) {
      var x = g.X(mk.m);
      if (idx === marks.length - 1 && kept.length && x - kept[kept.length - 1].x < 50) { kept.pop(); lastX = kept.length ? kept[kept.length - 1].x : -1e9; }
      if (x - lastX >= 50 || idx === 0 || idx === marks.length - 1) { kept.push({ x: x, m: mk.m, a: mk.a }); lastX = x; }
    });
    kept.forEach(function (mk) {
      var v = DC.interp(smp, mk.m % 1440);
      var k = Math.round(v.k / 100) * 100;
      var txt = s('text', { x: mk.x, y: g.barY + g.barH + 12, 'class': 'k-label', 'text-anchor': mk.a, text: k + 'K' });
      txt.setAttribute('fill', DC.kelvinColor(k));
      svg.appendChild(txt);
    });
    // area sensibile (48px) per il press-and-hold: barra + etichette
    var hit = s('rect', { x: g.L, y: g.barY - 14, width: g.w, height: 48, 'class': 'ct-hit' });
    function down(e) { e.preventDefault(); clearTimeout(self.holdTimer); self.holdTimer = setTimeout(function () { svg.classList.add('ct-reveal'); }, HOLD_MS); }
    function up() { clearTimeout(self.holdTimer); svg.classList.remove('ct-reveal'); }
    hit.addEventListener('pointerdown', down);
    ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (ev) { hit.addEventListener(ev, up); });
    svg.appendChild(hit);
  };

  // ---------------------------------------------------------------- marker SP
  P.drawMarkers = function (g, st) {
    var self = this;
    var sps = st.switchpoints || [];
    var order = sps.slice().sort(function (a, b) { return (a.n === self.activeSp ? 1 : 0) - (b.n === self.activeSp ? 1 : 0); });
    order.forEach(function (sp) {
      if (typeof sp.t !== 'number') { return; }
      var x = g.X(sp.t), y = g.Yb(sp.brightness);
      var grp = s('g', { 'class': 'sp' + (sp.n === self.activeSp ? ' active' : '') + (self.locked ? ' locked' : '') + (self.committing === sp.n ? ' pending' : ''), transform: 'translate(' + x + ',' + y + ')', 'data-n': sp.n }, [
        s('circle', { r: 15, 'class': 'halo' }),
        s('circle', { r: 7.5, 'class': 'dot' }),
        s('circle', { r: 24, 'class': 'hit' })                 // 48px di bersaglio
      ]);
      grp.addEventListener('pointerdown', function (e) { self.onDown(e, sp, grp); });
      self.gMarkers.appendChild(grp);
    });
  };

  P.spById = function (n) {
    var l = (this.state && this.state.switchpoints) || [];
    for (var i = 0; i < l.length; i++) { if (l[i].n === n) { return l[i]; } }
    return null;
  };

  P.pointer = function (e) {
    var r = this.svg.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };

  P.onDown = function (e, sp, grp) {
    if (this.locked || !this.g) { return; }
    e.preventDefault();
    e.stopPropagation();
    var p = this.pointer(e);
    var self = this;
    var st = this.state;
    var ref = (sp.type === 'Astronomical' && st.astro) ? st.astro[REF_KEY[sp.astroRef]] : null;
    this.drag = { n: sp.n, sp: sp, grp: grp, x0: p.x, y0: p.y, t0: new Date().getTime(), moved: false, newT: sp.t, newB: sp.brightness,
      ref: (typeof ref === 'number') ? ref : null };
    function move(ev) { self.onMove(ev); }
    function up(ev) {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', up);
      self.onUp(ev);
    }
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
    window.addEventListener('pointercancel', up);
  };

  P.onMove = function (e) {
    var d = this.drag, g = this.g;
    if (!d || !g) { return; }
    var p = this.pointer(e);
    if (!d.moved) {
      if (Math.abs(p.x - d.x0) < TAP_PX && Math.abs(p.y - d.y0) < TAP_PX) { return; }
      d.moved = true;
      if (this.hooks.onFreeze) { this.hooks.onFreeze('drag'); }       // glow fermo finche' dura il drag
      d.grp.classList.add('active');
    }
    var mode = this.state.mode;
    var newT = clamp(Math.round(((p.x - g.L) / g.w) * 1440 / SNAP_MIN) * SNAP_MIN, 0, 1439);
    if (d.ref !== null) {                                             // SP astronomico: si muove l'OFFSET (+-180 min)
      var off = clamp(DC.wrapDiff(newT, d.ref), -180, 180);
      newT = ((Math.round(d.ref) + off) % 1440 + 1440) % 1440;
    }
    var newB = (mode === MODE_CCT) ? d.sp.brightness : clamp(Math.round(((g.T + g.h - p.y) / g.h) * 100), 0, 100);
    d.newT = newT; d.newB = newB;
    d.grp.setAttribute('transform', 'translate(' + g.X(newT) + ',' + g.Yb(newB) + ')');
    this.drawTip(g, d);
  };

  P.drawTip = function (g, d) {
    DC.clear(this.gTip);
    var txt = t('sp.tip', { n: d.n, time: DC.hhmm(d.newT), b: d.newB });
    if (d.ref !== null) { txt += ' (' + DC.signed(DC.wrapDiff(d.newT, d.ref)) + ')'; }
    var w = txt.length * 6.6 + 16;
    var x = clamp(g.X(d.newT), g.L + w / 2, g.L + g.w - w / 2);
    var yy = g.Yb(d.newB) - 40;
    if (yy < g.T) { yy = g.Yb(d.newB) + 22; }
    this.gTip.appendChild(s('g', { 'class': 'sp-tip' }, [
      s('rect', { x: x - w / 2, y: yy, width: w, height: 20, rx: 6 }),
      s('text', { x: x, y: yy + 14, text: txt })
    ]));
  };

  P.onUp = function () {
    var d = this.drag;
    if (!d) { return; }
    var self = this;
    DC.clear(this.gTip);
    if (!d.moved) {                                                   // tap: apre il dettaglio
      this.drag = null;
      if (this.hooks.onTap) { this.hooks.onTap(d.n); }
      return;
    }
    var sp = d.sp, args = { n: d.n };
    if (d.ref !== null) {
      var off = DC.wrapDiff(d.newT, d.ref);
      if (off !== sp.offset) { args.offset = off; }
    } else if (d.newT !== sp.t) {
      args.time = DC.hhmm(d.newT);
    }
    if (d.newB !== sp.brightness && this.state.mode !== MODE_CCT) { args.brightness = d.newB; }
    if (this.hooks.onRelease) { this.hooks.onRelease('drag'); }       // un solo ricalcolo del glow
    var changed = Object.keys(args).length > 1;
    this.drag = null;
    if (!changed) { this.render(); return; }
    this.committing = d.n;
    d.grp.classList.add('pending');
    if (this.hooks.onCommit) {
      this.hooks.onCommit(d.n, args, function (err) {
        self.committing = null;
        self.clearSettle();
        if (err) { self.pendingState = null; }                         // rifiutato: torna alla posizione reale
        else if (self.pendingState) { self.state = self.pendingState; self.pendingState = null; }
        self.render();
      });
    }
    // rete di sicurezza: se la conferma non arriva, ridisegna comunque dalla posizione reale
    this.clearSettle();
    this.settleTimer = setTimeout(function () {
      self.committing = null;
      if (self.pendingState) { self.state = self.pendingState; self.pendingState = null; }
      self.render();
    }, SETTLE_MS);
  };

  P.clearSettle = function () { clearTimeout(this.settleTimer); this.settleTimer = null; };

  // ---------------------------------------------------------------- "adesso"
  P.renderNow = function () {
    var g = this.g, st = this.state;
    if (!g || !this.gNow) { return; }
    DC.clear(this.gNow);
    var smp = st && st.curve && st.curve.samples;
    if (!smp) { return; }
    var d = new Date();
    var minute = d.getHours() * 60 + d.getMinutes();
    var v = DC.interp(smp, minute);
    if (this.hooks.onNow) { this.hooks.onNow({ minute: minute, b: v.b, k: v.k }); }
    if (this.preview) { return; }                                     // in preview il tempo vive nel banner e nel callout
    var x = g.X(minute);
    this.gNow.appendChild(s('line', { x1: x, y1: g.T, x2: x, y2: g.T + g.h, 'class': 'now-line' }));
    this.gNow.appendChild(s('circle', { cx: x, cy: g.Yb(v.b), r: 4.5, 'class': 'now-dot' }));
  };

  // ---------------------------------------------------------------- anteprima
  P.renderPreview = function () {
    var g = this.g, pv = this.preview;
    if (!g || !this.gPreview) { return; }
    DC.clear(this.gPreview);
    if (!pv) { return; }
    var x = g.X(pv.minute || 0);
    var b = typeof pv.brightness === 'number' ? pv.brightness : (DC.interp(this.state.curve.samples, pv.minute || 0) || { b: 0 }).b;
    var y = g.Yb(b);
    this.gPreview.appendChild(s('line', { x1: x, y1: g.T, x2: x, y2: g.barY + g.barH, 'class': 'pv-line' }));
    this.gPreview.appendChild(s('circle', { cx: x, cy: y, r: 6, 'class': 'pv-dot' }));
    // callout sul marker: ora e luminosita' (la CCT sta nel banner)
    var txt = t('preview.callout', { time: DC.hhmm(pv.minute || 0), b: Math.round(b) });
    var w = txt.length * 6.8 + 16;
    var cx = clamp(x, g.L + w / 2, g.L + g.w - w / 2);
    var ty = y - 36 < g.T ? y + 14 : y - 36;                          // sotto il punto se sopra c'e' la fascia dei tag astro
    this.gPreview.appendChild(s('g', { 'class': 'pv-tip' }, [
      s('rect', { x: cx - w / 2, y: ty, width: w, height: 20, rx: 6 }),
      s('text', { x: cx, y: ty + 14, text: txt })
    ]));
  };

  DC.CurveRenderer = CurveRenderer;
})(window.DC = window.DC || {});
