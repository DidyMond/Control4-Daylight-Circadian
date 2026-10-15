/* ============================================================
 * util.js - helper DOM, orari, colore da temperatura (Kelvin), log di debug.
 * Nessuna logica della curva: la curva la calcola il controller (curve:samples).
 * ============================================================ */
(function (DC) {
  'use strict';

  // ---------------------------------------------------------------- DOM
  // h('div', { class: 'x', text: 'ciao', html: '<b>..</b>', on: { click: fn }, attrs... }, [figli])
  function h(tag, attrs, children) {
    var e = document.createElement(tag);
    var k;
    if (attrs) {
      for (k in attrs) {
        if (!Object.prototype.hasOwnProperty.call(attrs, k)) { continue; }
        var v = attrs[k];
        if (v === undefined || v === null || v === false) { continue; }
        if (k === 'class') { e.className = v; }
        else if (k === 'text') { e.textContent = v; }
        else if (k === 'html') { e.innerHTML = v; }
        else if (k === 'style') { e.style.cssText = v; }
        else if (k === 'on') { for (var ev in v) { if (Object.prototype.hasOwnProperty.call(v, ev)) { e.addEventListener(ev, v[ev]); } } }
        else { e.setAttribute(k, v === true ? '' : v); }
      }
    }
    if (children) {
      for (var i = 0; i < children.length; i++) {
        var c = children[i];
        if (c === null || c === undefined || c === false) { continue; }
        e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
      }
    }
    return e;
  }

  var SVG_NS = 'http://www.w3.org/2000/svg';
  function s(tag, attrs, children) {
    var e = document.createElementNS(SVG_NS, tag);
    if (attrs) {
      for (var k in attrs) {
        if (!Object.prototype.hasOwnProperty.call(attrs, k)) { continue; }
        if (attrs[k] === undefined || attrs[k] === null) { continue; }
        if (k === 'text') { e.textContent = attrs[k]; } else { e.setAttribute(k, attrs[k]); }
      }
    }
    if (children) { for (var i = 0; i < children.length; i++) { if (children[i]) { e.appendChild(children[i]); } } }
    return e;
  }

  function clear(node) { while (node.firstChild) { node.removeChild(node.firstChild); } }

  // ---------------------------------------------------------------- numeri e orari
  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  function pad2(n) { return (n < 10 ? '0' : '') + n; }

  // minuti dall'inizio del giorno -> "HH:MM" (modulo 24h)
  function hhmm(minutes) {
    var m = Math.round(minutes) % 1440;
    if (m < 0) { m += 1440; }
    return pad2(Math.floor(m / 60)) + ':' + pad2(m % 60);
  }

  // differenza con segno fra due istanti del giorno, in (-720, 720]
  function wrapDiff(a, b) {
    var d = (a - b) % 1440;
    if (d > 720) { d -= 1440; }
    if (d <= -720) { d += 1440; }
    return d;
  }

  function signed(n) { return (n > 0 ? '+' : (n < 0 ? '-' : '')) + Math.abs(n); }

  // ---------------------------------------------------------------- Kelvin -> colore
  // Approssimazione di Tanner Helland (corpo nero), ottima per un gradiente di UI.
  function kelvinToRgb(k) {
    var t = clamp(k, 1000, 10000) / 100;
    var r, g, b;
    r = t <= 66 ? 255 : 329.698727446 * Math.pow(t - 60, -0.1332047592);
    g = t <= 66 ? 99.4708025861 * Math.log(t) - 161.1195681661 : 288.1221695283 * Math.pow(t - 60, -0.0755148492);
    if (t >= 66) { b = 255; } else if (t <= 19) { b = 0; } else { b = 138.5177312231 * Math.log(t - 10) - 305.0447927307; }
    return [clamp(Math.round(r), 0, 255), clamp(Math.round(g), 0, 255), clamp(Math.round(b), 0, 255)];
  }
  function kelvinColor(k, alpha) {
    var c = kelvinToRgb(k);
    return alpha === undefined ? 'rgb(' + c[0] + ',' + c[1] + ',' + c[2] + ')' : 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + alpha + ')';
  }

  // fascia: <3500K calda, 3500-5000K neutra, >5000K fredda (DESIGN.md §7)
  function cctBand(k) { return k < 3500 ? 'warm' : (k <= 5000 ? 'neutral' : 'cool'); }

  // ---------------------------------------------------------------- campioni del controller
  // Interpolazione LINEARE fra i campioni gia' calcolati dal controller, solo per leggere
  // un valore nel punto in cui cade un'etichetta (ora, preview). Non rigenera la curva.
  function interp(samples, t) {
    if (!samples || !samples.length) { return null; }
    var step = samples.length > 1 ? (samples[1][0] - samples[0][0]) : 10;
    var m = ((t % 1440) + 1440) % 1440;
    var i = Math.floor(m / step);
    var a = samples[i % samples.length];
    var b = samples[(i + 1) % samples.length];
    var f = (m - a[0]) / step;
    return { b: a[1] + (b[1] - a[1]) * f, k: a[2] + (b[2] - a[2]) * f };
  }

  // ---------------------------------------------------------------- varie
  function storageGet(key) { try { return window.localStorage.getItem(key); } catch (e) { return null; } }
  function storageSet(key, v) { try { window.localStorage.setItem(key, v); } catch (e) { /* assente o negato */ } }

  // ---------------------------------------------------------------- limitatore (avvisi all'utente)
  // allow(chiave, finestraMs): true al massimo una volta per finestra e per chiave
  var throttleAt = {};
  function throttleAllow(key, windowMs, nowMs) {
    var n = nowMs === undefined ? new Date().getTime() : nowMs;
    var last = throttleAt[key];
    if (last !== undefined && n - last < windowMs) { return false; }
    throttleAt[key] = n;
    return true;
  }

  // ---------------------------------------------------------------- log di debug
  // Sempre su console (su Navigator: tocca 4 volte l'intestazione); con ?debug=1 anche a schermo.
  var logLines = [];
  var logEl = null;
  function log(msg) {
    var d = new Date();
    var ms = d.getMilliseconds();
    var line = pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds()) + '.' + (ms < 10 ? '00' : (ms < 100 ? '0' : '')) + ms + ' ' + msg;
    logLines.push(line);
    if (logLines.length > 150) { logLines.shift(); }
    if (window.console && console.log) { console.log(msg); }
    if (logEl) { logEl.textContent = logLines.join('\n'); logEl.scrollTop = logEl.scrollHeight; }
  }
  function attachLog(el) { logEl = el; logEl.textContent = logLines.join('\n'); }

  DC.h = h; DC.s = s; DC.clear = clear;
  DC.clamp = clamp; DC.pad2 = pad2; DC.hhmm = hhmm; DC.wrapDiff = wrapDiff; DC.signed = signed;
  DC.kelvinToRgb = kelvinToRgb; DC.kelvinColor = kelvinColor; DC.cctBand = cctBand;
  DC.interp = interp;
  DC.storage = { get: storageGet, set: storageSet };
  DC.log = log; DC.attachLog = attachLog; DC.logLines = logLines;
  DC.throttle = { allow: throttleAllow };
})(window.DC = window.DC || {});
