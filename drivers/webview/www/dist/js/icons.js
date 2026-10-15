/* ============================================================
 * icons.js - icone SVG inline (24x24, stroke = currentColor). Nessuna risorsa esterna.
 * DC.icon('play') ritorna la stringa SVG.
 * ============================================================ */
(function (DC) {
  'use strict';

  var P = {
    play: '<polygon points="7 4 20 12 7 20 7 4" fill="currentColor" stroke="none"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="1.5" fill="currentColor" stroke="none"/>',
    pause: '<rect x="6" y="5" width="4" height="14" rx="1" fill="currentColor" stroke="none"/><rect x="14" y="5" width="4" height="14" rx="1" fill="currentColor" stroke="none"/>',
    link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    check: '<polyline points="5 12.5 10 17.5 19 7.5"/>',
    trash: '<path d="M4 7h16"/><path d="M9 7V4h6v3"/><path d="M6 7l1 13h10l1-13"/>',
    close: '<line x1="6" y1="6" x2="18" y2="18"/><line x1="18" y1="6" x2="6" y2="18"/>',
    help: '<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.6 2.2c-.7.4-1.1 1-1.1 1.8"/><circle cx="12" cy="17" r=".6" fill="currentColor"/>',
    chevron: '<polyline points="6 9 12 15 18 9"/>',
    monitor: '<rect x="3" y="4" width="18" height="12" rx="2"/><line x1="8" y1="20" x2="16" y2="20"/><line x1="12" y1="16" x2="12" y2="20"/>',
    lock: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
    sunrise: '<path d="M4 18h16"/><path d="M7 18a5 5 0 0 1 10 0"/><line x1="12" y1="6" x2="12" y2="9"/><polyline points="9.5 7.5 12 5 14.5 7.5"/>',
    clock: '<circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15.5 14"/>',
    sun: '<circle cx="12" cy="12" r="4"/><line x1="12" y1="2" x2="12" y2="5"/><line x1="12" y1="19" x2="12" y2="22"/><line x1="2" y1="12" x2="5" y2="12"/><line x1="19" y1="12" x2="22" y2="12"/>',
    refresh: '<path d="M20 11a8 8 0 0 0-14.5-3.5L4 9"/><polyline points="4 4 4 9 9 9"/><path d="M4 13a8 8 0 0 0 14.5 3.5L20 15"/><polyline points="20 20 20 15 15 15"/>',
    bulb: '<path d="M9 18h6"/><path d="M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z"/>'
  };

  function icon(name) {
    var inner = P[name] || '';
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + inner + '</svg>';
  }

  DC.icon = icon;
})(window.DC = window.DC || {});
