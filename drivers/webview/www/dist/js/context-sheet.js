/* ============================================================
 * context-sheet.js - ContextSheet "Modifica switchpoint".
 *
 * Posizione (DESIGN.md, form factor T4): card flottante top 68 / right 12 / bottom 12,
 * 460px da 900px in su (960px da 1920px), bottom sheet sotto 900px; superficie SOLIDA
 * sotto 1920px (niente blur). Aprirla congela il GlowLayer (un ricalcolo alla chiusura).
 *
 * La sheet lavora su una BOZZA: "Applica" invia a SET_SWITCHPOINT solo i campi cambiati;
 * "Elimina" invia DELETE_SWITCHPOINT (solo se gli SP sono piu' del minimo, con conferma).
 * ============================================================ */
(function (DC) {
  'use strict';
  var h = DC.h, t = DC.t, clamp = DC.clamp;

  var MIN_SP = 3;
  var REFS = ['Sunrise', 'Solar Noon', 'Sunset', 'Solar Midnight'];
  var REF_KEY = { 'Sunrise': 'sunrise', 'Solar Noon': 'solar_noon', 'Sunset': 'sunset', 'Solar Midnight': 'solar_midnight' };
  var T_TIME = 'Set Time', T_ASTRO = 'Astronomical';
  var MODE_CCT = 'Colour Temperature Only', MODE_BRI = 'Brightness Only';

  function ContextSheet(root, hooks) {
    this.root = root;
    this.hooks = hooks || {};
    this.scrim = null;
    this.sheet = null;
    this.draft = null;
    this.orig = null;
    this.state = null;
    this.n = null;
    this.busy = false;
    this.confirmTimer = null;
    this.onKey = null;
  }
  var P = ContextSheet.prototype;

  P.isOpen = function () { return !!this.sheet; };

  // open(state, n, controllerName)
  P.open = function (state, n, ctrlName) {
    var sp = null, i, list = state.switchpoints || [];
    for (i = 0; i < list.length; i++) { if (list[i].n === n) { sp = list[i]; } }
    if (!sp) { return; }
    if (this.sheet) { this.destroy(); }
    var self = this;
    this.state = state;
    this.n = n;
    this.ctrlName = ctrlName || '';
    this.orig = {
      type: sp.type === T_ASTRO ? T_ASTRO : T_TIME,
      time: typeof sp.t === 'number' ? Math.round(sp.t) : 0,
      astroRef: sp.astroRef || 'Sunrise',
      offset: typeof sp.offset === 'number' ? sp.offset : 0,
      brightness: Math.round(sp.brightness),
      cct: Math.round(sp.cct)
    };
    if (typeof sp.time === 'string' && /^\d\d:\d\d$/.test(sp.time)) {           // valore della proprieta' (Set Time)
      this.orig.time = parseInt(sp.time.slice(0, 2), 10) * 60 + parseInt(sp.time.slice(3), 10);
    }
    var ct = state.ct || { min: 1600, max: 6500 };
    this.orig.cct = clamp(this.orig.cct, ct.min, ct.max);                         // la slider mostra il valore effettivo
    this.draft = JSON.parse(JSON.stringify(this.orig));
    this.busy = false;

    this.scrim = h('div', { class: 'sheet-scrim' });
    this.scrim.addEventListener('click', function () { self.close(); });
    this.sheet = h('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true' });
    this.build();
    this.root.appendChild(this.scrim);
    this.root.appendChild(this.sheet);
    this.time.sync();
    // forza il layout prima di aggiungere .open, cosi' la transizione parte
    void this.sheet.offsetWidth;
    this.scrim.classList.add('open');
    this.sheet.classList.add('open');
    if (this.hooks.onFreeze) { this.hooks.onFreeze('sheet'); }
    if (this.hooks.onOpen) { this.hooks.onOpen(n); }
    this.onKey = function (e) { if (e.key === 'Escape') { self.close(); } };
    window.addEventListener('keydown', this.onKey);
  };

  // dallo STATE che arriva mentre e' aperta: aggiorna solo i dati di contorno (conteggio, ore astro)
  P.refresh = function (state) {
    this.state = state;
    if (!this.sheet) { return; }
    this.updateDelete();
    this.refreshRefs();
  };

  // ---------------------------------------------------------------- costruzione
  P.build = function () {
    var self = this, d = this.draft, st = this.state;
    var ct = st.ct || { min: 1600, max: 6500 };

    // header
    this.titleEl = h('h2', { text: t('sp.title', { n: this.n }) });
    this.crumbEl = h('div', { class: 'crumb' });
    var closeBtn = h('button', { type: 'button', class: 'icon-btn', 'aria-label': t('close'), html: DC.icon('close') });
    closeBtn.addEventListener('click', function () { self.close(); });
    var head = h('div', { class: 'sheet-head' }, [h('div', null, [this.titleEl, this.crumbEl]), closeBtn]);

    // tipo
    this.typeSeg = DC.Segmented({
      options: [{ value: T_TIME, label: t('sp.type.time'), icon: 'clock' }, { value: T_ASTRO, label: t('sp.type.astro'), icon: 'sun' }],
      value: d.type,
      onChange: function (v) { d.type = v; self.syncType(); self.updateCrumb(); }
    });
    var typeField = h('div', { class: 'field' }, [h('div', { class: 'eyebrow', text: t('sp.type') }), this.typeSeg.el]);

    // orario fisso
    this.time = DC.TimePicker({ value: d.time, onChange: function (m) { d.time = m; self.updateCrumb(); } });
    this.timeField = h('div', { class: 'field' }, [h('div', { class: 'eyebrow', text: t('sp.time') }), this.time.el]);

    // astronomico: riferimento + offset
    this.refDd = DC.Dropdown({ options: this.refOptions(), value: d.astroRef, icon: 'sunrise', onChange: function (v) { d.astroRef = v; self.updateCrumb(); } });
    this.offsetStepper = DC.Stepper({
      min: -180, max: 180, step: 5, value: d.offset,
      render: function (el, v) { el.innerHTML = ''; el.appendChild(h('div', { class: 'big', text: DC.signed(v) + ' ' + t('unit.min') })); },
      onChange: function (v) { d.offset = v; self.updateCrumb(); }
    });
    this.astroField = h('div', { class: 'field' }, [
      h('div', { class: 'eyebrow', text: t('sp.astro') }),
      h('div', { class: 'field-card' }, [
        this.refDd.el,
        h('div', { class: 'row' }, [h('span', { class: 'lbl', text: t('sp.offset') }), this.offsetStepper.el])
      ])
    ]);

    // luminosita'
    var bVal = h('span', { class: 'val', style: 'color:var(--secondary)', text: d.brightness + '%' });
    this.briSlider = DC.Slider({
      min: 0, max: 100, step: 1, value: d.brightness, label: t('sp.bright'),
      gradient: 'linear-gradient(90deg, #141a29, #ffb95f)',
      format: function (v) { return v + '%'; },
      onInput: function (v) { d.brightness = v; bVal.textContent = v + '%'; },
      onStart: function () { if (self.hooks.onFreeze) { self.hooks.onFreeze('slider'); } },
      onEnd: function () { if (self.hooks.onRelease) { self.hooks.onRelease('slider'); } }
    });
    this.briCard = h('div', { class: 'field-card' }, [
      h('div', { class: 'slider-box' }, [
        h('div', { class: 'row' }, [h('span', { class: 'lbl eyebrow', text: t('sp.bright') }), bVal]),
        this.briSlider.el,
        h('div', { class: 'ends' }, [h('span', { text: t('sp.bright.min') }), h('span', { text: t('sp.bright.max') })])
      ])
    ]);

    // temperatura colore (range = CT limits del controller)
    this.cctVal = h('span', { class: 'val' });
    this.cctPill = h('span', { class: 'cct-pill' });
    var grad = [], k;
    for (k = 0; k <= 6; k++) { grad.push(DC.kelvinColor(ct.min + (ct.max - ct.min) * k / 6)); }
    this.cctSlider = DC.Slider({
      min: ct.min, max: ct.max, step: 100, value: d.cct, label: t('sp.cct'),
      gradient: 'linear-gradient(90deg, ' + grad.join(', ') + ')',
      format: function (v) { return v + 'K'; },
      onInput: function (v) { d.cct = v; self.paintCct(); },
      onStart: function () { if (self.hooks.onFreeze) { self.hooks.onFreeze('slider'); } },
      onEnd: function () { if (self.hooks.onRelease) { self.hooks.onRelease('slider'); } }
    });
    this.cctCard = h('div', { class: 'field-card' }, [
      h('div', { class: 'slider-box' }, [
        h('div', { class: 'row' }, [h('span', { class: 'lbl eyebrow', text: t('sp.cct') }), this.cctVal]),
        this.cctSlider.el,
        h('div', { class: 'ends' }, [h('span', { text: t('sp.cct.sub') }), this.cctPill])
      ])
    ]);
    this.paintCct();
    // modalita' che ignorano un canale: la scheda resta visibile ma attenuata
    this.briCard.setAttribute('data-dim', st.mode === MODE_CCT ? 'true' : 'false');
    this.cctCard.setAttribute('data-dim', st.mode === MODE_BRI ? 'true' : 'false');

    var body = h('div', { class: 'sheet-body' }, [typeField, this.timeField, this.astroField, this.briCard, this.cctCard]);

    // footer
    this.applyBtn = h('button', { type: 'button', class: 'btn-primary', html: DC.icon('check') }, [t('sp.apply')]);
    this.applyBtn.addEventListener('click', function () { self.apply(); });
    this.delBtn = h('button', { type: 'button', class: 'btn-muted', html: DC.icon('trash') }, [t('sp.delete')]);
    this.delBtn.addEventListener('click', function () { self.askDelete(); });
    var foot = h('div', { class: 'sheet-foot' }, [this.applyBtn, this.delBtn]);

    this.sheet.appendChild(head);
    this.sheet.appendChild(body);
    this.sheet.appendChild(foot);
    this.syncType();
    this.updateCrumb();
    this.updateDelete();
  };

  P.refOptions = function () {
    var a = this.state.astro || {};
    return REFS.map(function (r) {
      var v = a[REF_KEY[r]];
      return { value: r, label: t('astro.ref.' + r), sub: typeof v === 'number' ? DC.hhmm(v) : '' };
    });
  };
  P.refreshRefs = function () { if (this.refDd) { this.refDd.setOptions(this.refOptions()); } };

  P.syncType = function () {
    var astro = this.draft.type === T_ASTRO;
    this.timeField.hidden = astro;
    this.astroField.hidden = !astro;
    if (!astro) { this.time.sync(); }
  };

  // ora risolta della bozza (per l'intestazione)
  P.resolvedTime = function () {
    var d = this.draft;
    if (d.type === T_TIME) { return d.time; }
    var a = this.state.astro || {};
    var ref = a[REF_KEY[d.astroRef]];
    return typeof ref === 'number' ? ((Math.round(ref) + d.offset) % 1440 + 1440) % 1440 : null;
  };

  P.updateCrumb = function () {
    var rt = this.resolvedTime();
    DC.clear(this.crumbEl);
    this.crumbEl.appendChild(document.createTextNode(t('sp.crumb', { ctrl: this.ctrlName }) + ' \u00b7 '));
    this.crumbEl.appendChild(h('span', { class: 'hl', text: 'SP ' + this.n + (rt === null ? '' : ' (' + DC.hhmm(rt) + ')') }));
  };

  P.paintCct = function () {
    var k = this.draft.cct;
    this.cctVal.textContent = k + 'K';
    this.cctVal.style.color = DC.kelvinColor(k);
    var band = DC.cctBand(k);
    this.cctPill.setAttribute('data-band', band);
    this.cctPill.textContent = t('cct.' + band) + ' \u00b7 ' + k + 'K';
  };

  P.updateDelete = function () {
    var count = this.state.count || 0;
    var blocked = count <= MIN_SP;
    this.delBtn.setAttribute('aria-disabled', blocked ? 'true' : 'false');
    this.delBtn.title = blocked ? t('sp.delete.min', { n: MIN_SP }) : '';
  };

  // ---------------------------------------------------------------- azioni
  P.changedArgs = function () {
    var d = this.draft, o = this.orig, args = { n: this.n };
    var typeChanged = d.type !== o.type;
    if (typeChanged) { args.type = d.type; }
    if (d.type === T_TIME) {
      if (typeChanged || d.time !== o.time) { args.time = DC.hhmm(d.time); }
    } else {
      if (typeChanged || d.astroRef !== o.astroRef) { args.astroRef = d.astroRef; }
      if (typeChanged || d.offset !== o.offset) { args.offset = d.offset; }
    }
    if (d.brightness !== o.brightness) { args.brightness = d.brightness; }
    if (d.cct !== o.cct) { args.cct = d.cct; }
    return args;
  };

  P.setBusy = function (on) {
    this.busy = on;
    this.applyBtn.disabled = on;
    this.applyBtn.lastChild.textContent = on ? t('sp.applying') : t('sp.apply');
  };

  P.apply = function () {
    if (this.busy) { return; }
    var self = this, args = this.changedArgs();
    if (Object.keys(args).length <= 1) { this.close(); return; }      // niente da inviare
    this.setBusy(true);
    this.hooks.command('SET_SWITCHPOINT', args, function (err) {
      if (err) { self.setBusy(false); return; }          // l'avviso lo da' main.command (una volta sola)
      self.close();
    });
  };

  P.askDelete = function () {
    if (this.busy || this.delBtn.getAttribute('aria-disabled') === 'true') { return; }
    var self = this;
    if (!this.delBtn.classList.contains('confirm')) {                  // primo tocco: chiede conferma
      this.delBtn.classList.add('confirm');
      this.delBtn.lastChild.textContent = t('sp.delete.confirm');
      clearTimeout(this.confirmTimer);
      this.confirmTimer = setTimeout(function () { self.resetDelete(); }, 3000);
      return;
    }
    this.resetDelete();
    this.busy = true;
    this.hooks.command('DELETE_SWITCHPOINT', { n: this.n }, function (err) {
      self.busy = false;
      if (err) { return; }                               // l'avviso lo da' main.command (una volta sola)
      self.close();
    });
  };

  P.resetDelete = function () {
    clearTimeout(this.confirmTimer);
    if (!this.delBtn) { return; }
    this.delBtn.classList.remove('confirm');
    this.delBtn.lastChild.textContent = t('sp.delete');
  };

  // ---------------------------------------------------------------- chiusura
  P.close = function () {
    if (!this.sheet) { return; }
    var self = this, sheet = this.sheet, scrim = this.scrim;
    this.sheet = null; this.scrim = null;
    clearTimeout(this.confirmTimer);
    window.removeEventListener('keydown', this.onKey);
    sheet.classList.remove('open');
    scrim.classList.remove('open');
    setTimeout(function () {                                           // 200ms di chiusura, poi rimuove
      if (sheet.parentNode) { sheet.parentNode.removeChild(sheet); }
      if (scrim.parentNode) { scrim.parentNode.removeChild(scrim); }
    }, 220);
    if (this.hooks.onRelease) { this.hooks.onRelease('sheet'); this.hooks.onRelease('slider'); }
    if (this.hooks.onClose) { this.hooks.onClose(self.n); }
  };

  P.destroy = function () {
    if (this.sheet && this.sheet.parentNode) { this.sheet.parentNode.removeChild(this.sheet); }
    if (this.scrim && this.scrim.parentNode) { this.scrim.parentNode.removeChild(this.scrim); }
    this.sheet = null; this.scrim = null;
    window.removeEventListener('keydown', this.onKey);
  };

  DC.ContextSheet = ContextSheet;
})(window.DC = window.DC || {});
