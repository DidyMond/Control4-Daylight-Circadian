/* ============================================================
 * glow-layer.js - alone ambientale dietro la curva, tinto dalla temperatura colore
 * corrente. Regola di performance del T4 (gia' pagata altrove, non negoziabile):
 *  - durante drag di marker/slider e con la ContextSheet aperta il layer e' CONGELATO
 *    (nessun ricalcolo), poi UN solo ricalcolo quando cade l'ultimo motivo di blocco;
 *  - il raggio dell'alone e' quantizzato a passi da 10 unita': una variazione ordinaria
 *    di luminosita' raramente cambia il rendering.
 * ============================================================ */
(function (DC) {
  'use strict';

  var el = null;
  var holds = {};               // motivo -> true
  var held = 0;
  var target = null;            // ultimo { k, b } richiesto
  var applied = '';             // ultima chiave applicata (evita scritture inutili)
  var recomputes = 0;

  function attach(node) { el = node; apply(); }

  function apply() {
    if (!el || !target) { return; }
    var b = DC.clamp(target.b, 0, 100);
    var radius = 40 + Math.round(b / 10) * 3;                      // 40%..70%, passi da 10 unita' di luminosita'
    var alpha = (0.06 + 0.26 * (Math.round(b / 10) / 10)).toFixed(2);
    var k = Math.round(target.k / 100) * 100;                      // quantizza anche il colore
    var key = radius + '|' + alpha + '|' + k;
    if (key === applied) { return; }
    applied = key;
    recomputes++;
    el.style.setProperty('--glow-r', radius + '%');
    el.style.setProperty('--glow-color', DC.kelvinColor(k, alpha));
  }

  // set({k, b}): se congelato ricorda solo il valore, altrimenti ricalcola
  function set(k, b) {
    target = { k: k, b: b };
    if (held === 0) { apply(); }
  }

  function freeze(reason) {
    if (!holds[reason]) { holds[reason] = true; held++; }
  }

  function release(reason) {
    if (!holds[reason]) { return; }
    delete holds[reason];
    held--;
    if (held === 0) { apply(); }                                   // un solo ricalcolo al rilascio
  }

  DC.glow = {
    attach: attach, set: set, freeze: freeze, release: release,
    isFrozen: function () { return held > 0; },
    recomputes: function () { return recomputes; }
  };
})(window.DC = window.DC || {});
