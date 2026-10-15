/* ============================================================
 * widgets.js - controlli riusabili: Slider (dual-axis), Segmented, Stepper, Dropdown,
 * TimePicker, Toast. Bersagli >= 48px (56px per slider e azioni primarie).
 * Ogni widget ritorna { el, ... } e non conosce il protocollo.
 * ============================================================ */
(function (DC) {
  'use strict';
  var h = DC.h, clamp = DC.clamp;

  // ---------------------------------------------------------------- Slider
  // opts: { min, max, step, value, format(v), gradient (css), onInput(v), onCommit(v),
  //         onStart(), onEnd(), label }
  // Live: onInput a ogni movimento (clamp ai bounds correnti); onCommit solo al rilascio.
  function Slider(opts) {
    var min = opts.min, max = opts.max, step = opts.step || 1;
    var lo = min, hi = max;                         // bounds dinamici (es. min < max dei CT limits)
    var value = clamp(opts.value, lo, hi);
    var active = false;
    var format = opts.format || function (v) { return String(v); };

    var fill = h('div', { class: 'slider-fill' });
    var track = h('div', { class: 'slider-track' }, [fill]);
    var thumb = h('div', { class: 'slider-thumb' });
    var bubble = h('div', { class: 'slider-bubble' });
    var el = h('div', { class: 'slider', role: 'slider', tabindex: '0', 'aria-label': opts.label || '' }, [track, bubble, thumb]);

    if (opts.gradient) { fill.style.background = opts.gradient; }

    function paint() {
      var p = (value - min) / (max - min);
      el.style.setProperty('--p', String(clamp(p, 0, 1)));
      bubble.textContent = format(value);
      el.setAttribute('aria-valuemin', String(min));
      el.setAttribute('aria-valuemax', String(max));
      el.setAttribute('aria-valuenow', String(value));
    }

    function snap(v) { return clamp(Math.round(v / step) * step, lo, hi); }

    function fromEvent(e) {
      var r = track.getBoundingClientRect();
      var p = clamp((e.clientX - r.left) / r.width, 0, 1);
      return snap(min + p * (max - min));
    }

    function update(v, fire) {
      if (v === value) { return; }
      value = v;
      paint();
      if (fire && opts.onInput) { opts.onInput(value); }
    }

    el.addEventListener('pointerdown', function (e) {
      if (el.getAttribute('aria-disabled') === 'true') { return; }
      e.preventDefault();
      active = true;
      try { el.setPointerCapture(e.pointerId); } catch (err) { /* pointer sintetico */ }
      el.classList.add('dragging');
      if (opts.onStart) { opts.onStart(); }
      update(fromEvent(e), true);
    });
    el.addEventListener('pointermove', function (e) { if (active) { update(fromEvent(e), true); } });
    function end(e) {
      if (!active) { return; }
      active = false;
      el.classList.remove('dragging');
      try { el.releasePointerCapture(e.pointerId); } catch (err) { /* gia' rilasciato */ }
      if (opts.onEnd) { opts.onEnd(); }
      if (opts.onCommit) { opts.onCommit(value); }
    }
    el.addEventListener('pointerup', end);
    el.addEventListener('pointercancel', end);

    el.addEventListener('keydown', function (e) {
      var d = e.key === 'ArrowRight' || e.key === 'ArrowUp' ? step : (e.key === 'ArrowLeft' || e.key === 'ArrowDown' ? -step : 0);
      if (!d) { return; }
      e.preventDefault();
      update(snap(value + d), true);
      if (opts.onCommit) { opts.onCommit(value); }
    });

    paint();
    return {
      el: el,
      get value() { return value; },
      isActive: function () { return active; },
      setValue: function (v) { if (!active) { value = clamp(v, min, max); paint(); } },
      setBounds: function (a, b) { lo = clamp(a, min, max); hi = clamp(b, min, max); },
      setGradient: function (css) { fill.style.background = css; },
      setDisabled: function (d) { el.setAttribute('aria-disabled', d ? 'true' : 'false'); }
    };
  }

  // ---------------------------------------------------------------- Segmented
  // opts: { options: [{value,label,icon}], value, onChange(value) }
  function Segmented(opts) {
    var value = opts.value;
    var buttons = [];
    var el = h('div', { class: 'segmented', role: 'group' });
    opts.options.forEach(function (o) {
      var b = h('button', { type: 'button', 'aria-pressed': 'false', html: (o.icon ? DC.icon(o.icon) : '') }, [o.label]);
      b.dataset.value = o.value;
      b.addEventListener('click', function () {
        if (el.getAttribute('aria-disabled') === 'true') { return; }
        if (o.value === value) { return; }
        value = o.value;
        paint();
        if (opts.onChange) { opts.onChange(value); }
      });
      buttons.push(b);
      el.appendChild(b);
    });
    function paint() { buttons.forEach(function (b) { b.setAttribute('aria-pressed', b.dataset.value === value ? 'true' : 'false'); }); }
    paint();
    return {
      el: el,
      setValue: function (v) { value = v; paint(); },
      setLabels: function (labels) { buttons.forEach(function (b, i) { if (labels[i] !== undefined) { b.lastChild.textContent = labels[i]; } }); },
      setDisabled: function (d) { el.setAttribute('aria-disabled', d ? 'true' : 'false'); }
    };
  }

  // ---------------------------------------------------------------- Stepper
  // opts: { min, max, step, value, onChange(v), render(valueEl, v) }; tieni premuto = ripete
  function Stepper(opts) {
    var min = opts.min, max = opts.max, step = opts.step || 1, value = opts.value;
    var valEl = h('div', { class: 'step-val' });
    var minus = h('button', { type: 'button', class: 'step-btn', 'aria-label': '-', text: '−' });
    var plus = h('button', { type: 'button', class: 'step-btn', 'aria-label': '+', text: '+' });
    var el = h('div', { class: 'stepper' }, [minus, valEl, plus]);
    var timer = null, repeater = null;

    function paint() {
      opts.render(valEl, value);
      minus.setAttribute('aria-disabled', value <= min ? 'true' : 'false');
      plus.setAttribute('aria-disabled', value >= max ? 'true' : 'false');
    }
    function bump(dir) {
      var next = clamp(value + dir * step, min, max);
      if (next === value) { return false; }
      value = next;
      paint();
      if (opts.onChange) { opts.onChange(value); }
      return true;
    }
    function hold(btn, dir) {
      function stop() { clearTimeout(timer); clearInterval(repeater); timer = repeater = null; }
      btn.addEventListener('pointerdown', function (e) {
        e.preventDefault();
        if (el.getAttribute('aria-disabled') === 'true') { return; }
        bump(dir);
        timer = setTimeout(function () { repeater = setInterval(function () { if (!bump(dir)) { stop(); } }, 90); }, 420);
      });
      ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (ev) { btn.addEventListener(ev, stop); });
      btn.addEventListener('click', function (e) { if (e.detail === 0) { bump(dir); } });   // tastiera
    }
    hold(minus, -1); hold(plus, 1);
    paint();
    return {
      el: el,
      get value() { return value; },
      setValue: function (v) { value = clamp(v, min, max); paint(); },
      setDisabled: function (d) { el.setAttribute('aria-disabled', d ? 'true' : 'false'); }
    };
  }

  // ---------------------------------------------------------------- Dropdown
  // opts: { options: [{value,label,sub}], value, icon, onChange(value) }
  function Dropdown(opts) {
    var value = opts.value;
    var open = false;
    var lead = h('span', { class: 'lead' });
    var btn = h('button', { type: 'button', class: 'dd-btn', 'aria-haspopup': 'listbox' }, [lead, h('span', { html: DC.icon('chevron') })]);
    var list = h('div', { class: 'dd-list', role: 'listbox', hidden: true });
    var el = h('div', { class: 'dropdown' }, [btn, list]);

    function current() { for (var i = 0; i < opts.options.length; i++) { if (opts.options[i].value === value) { return opts.options[i]; } } return null; }
    function paint() {
      var c = current();
      lead.innerHTML = (opts.icon ? DC.icon(opts.icon) : '');
      lead.appendChild(document.createTextNode(c ? c.label : ''));
      if (c && c.sub) { lead.appendChild(h('span', { class: 't', style: 'color:var(--on-surface-variant);font-family:var(--font-mono);font-size:12px', text: c.sub })); }
    }
    function build() {
      DC.clear(list);
      opts.options.forEach(function (o) {
        var it = h('button', { type: 'button', class: 'dd-item', role: 'option', 'aria-selected': o.value === value ? 'true' : 'false' },
          [h('span', { text: o.label }), o.sub ? h('span', { class: 't', text: o.sub }) : null]);
        it.addEventListener('click', function () {
          value = o.value; toggle(false); paint();
          if (opts.onChange) { opts.onChange(value); }
        });
        list.appendChild(it);
      });
    }
    function toggle(on) {
      open = on;
      list.hidden = !on;
      if (on) { build(); }
    }
    btn.addEventListener('click', function () { toggle(!open); });
    paint();
    return {
      el: el,
      setValue: function (v) { value = v; paint(); },
      setOptions: function (o) { opts.options = o; paint(); if (open) { build(); } },
      close: function () { toggle(false); }
    };
  }

  // ---------------------------------------------------------------- TimePicker
  // opts: { value (minuti), onChange(minuti) }. Due colonne scrollabili con snap a 48px.
  function TimePicker(opts) {
    var ROW = 48;
    var hh = Math.floor(opts.value / 60) % 24, mm = opts.value % 60;
    var settling = false;

    function column(count, initial, onPick) {
      var col = h('div', { class: 'tp-col' });
      col.appendChild(h('div', { class: 'tp-pad' }));
      var rows = [];
      for (var i = 0; i < count; i++) {
        (function (i) {
          var r = h('div', { class: 'tp-row', text: DC.pad2(i) });
          r.addEventListener('click', function () {
            if (col.scrollTo) { col.scrollTo({ top: i * ROW, behavior: 'smooth' }); } else { col.scrollTop = i * ROW; }
          });
          rows.push(r); col.appendChild(r);
        })(i);
      }
      col.appendChild(h('div', { class: 'tp-pad' }));
      var idle = null, selected = -1;
      function mark(i) {
        if (i === selected) { return; }
        if (selected >= 0) { rows[selected].classList.remove('sel'); }
        selected = i; rows[i].classList.add('sel');
      }
      col.addEventListener('scroll', function () {
        mark(clamp(Math.round(col.scrollTop / ROW), 0, count - 1));
        clearTimeout(idle);
        idle = setTimeout(function () {                // scroll finito: la riga centrale e' la scelta
          if (settling) { return; }
          onPick(clamp(Math.round(col.scrollTop / ROW), 0, count - 1));
        }, 110);
      });
      return {
        el: col,
        set: function (i) { settling = true; col.scrollTop = i * ROW; mark(i); setTimeout(function () { settling = false; }, 150); },
        init: function () { mark(initial); }
      };
    }

    var colH = column(24, hh, function (i) { if (i !== hh) { hh = i; fire(); } });
    var colM = column(60, mm, function (i) { if (i !== mm) { mm = i; fire(); } });
    function fire() { if (opts.onChange) { opts.onChange(hh * 60 + mm); } }

    var picker = h('div', { class: 'time-picker' }, [colH.el, h('div', { class: 'tp-sep', text: ':' }), colM.el]);
    var el = h('div', { class: 'tp-wrap' }, [picker, h('div', { class: 'tp-band' })]);
    colH.init(); colM.init();
    return {
      el: el,
      get value() { return hh * 60 + mm; },
      // chiamare dopo l'inserimento nel DOM (lo scrollTop richiede il layout)
      sync: function () { colH.set(hh); colM.set(mm); },
      setValue: function (minutes) { hh = Math.floor(minutes / 60) % 24; mm = minutes % 60; colH.set(hh); colM.set(mm); }
    };
  }

  // ---------------------------------------------------------------- Toast
  function toast(message, kind) {
    var root = document.getElementById('toast-root');
    if (!root) { return; }
    var t = h('div', { class: 'toast' + (kind === 'error' ? ' error' : ''), role: 'status', text: message });
    root.appendChild(t);
    setTimeout(function () { if (t.parentNode) { t.parentNode.removeChild(t); } }, 5000);   // auto-dismiss 5 s
  }

  DC.Slider = Slider; DC.Segmented = Segmented; DC.Stepper = Stepper; DC.Dropdown = Dropdown;
  DC.TimePicker = TimePicker; DC.toast = toast;
})(window.DC = window.DC || {});
