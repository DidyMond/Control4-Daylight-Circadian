/* ============================================================
 * i18n.js - dizionario IT / EN. La lingua arriva dalla proprieta' Language del driver
 * webview (risposta di DC_PING); prima di allora si usa la lingua del dispositivo.
 * Fallback: inglese. Orari sempre HH:MM (24h), temperature in K.
 * ============================================================ */
(function (DC) {
  'use strict';

  var DICT = {
    en: {
      'app.title': 'CIRCADIAN OS',
      'conn.live': 'Connected', 'conn.wait': 'Connecting...', 'conn.error': 'Connection lost',
      'conn.lost': 'Connection lost. Reload the page.', 'conn.reload': 'Reload',
      'help.title': 'How it works',
      'help.close': 'Close',
      'help.1': 'The curve shows the 24-hour schedule the controller applies to your lights: brightness (blue line) and colour temperature (gradient below).',
      'help.2': 'Drag a switchpoint to move it in time and brightness, or tap it to edit every detail.',
      'help.3': 'Hold your finger on the colour gradient to reveal the colour temperature curve.',
      'help.4': 'Preview replays the whole day in about two minutes on the real lights. Follow All Lights re-aligns lights you changed by hand.',
      'ctrl.none': 'No controller',
      'curve.title': 'Solar 24-Hour Curve',
      'curve.sub': '{n} switchpoints · {mode}',
      'curve.now': 'NOW {time} · {b}% / {k}K',
      'curve.sub.paused': '{n} switchpoints · {mode} · paused',
      'mode.both': 'Brightness + CT', 'mode.brightness': 'Brightness only', 'mode.cct': 'CT only',
      'mode.short.both': 'Bri + CT', 'mode.short.brightness': 'Bri only', 'mode.short.cct': 'CT only',
      'astro.sunrise': 'SUNRISE', 'astro.solar_noon': 'SOLAR NOON', 'astro.sunset': 'SUNSET', 'astro.solar_midnight': 'MIDNIGHT',
      'astro.ref.Sunrise': 'Sunrise', 'astro.ref.Solar Noon': 'Solar Noon', 'astro.ref.Sunset': 'Sunset', 'astro.ref.Solar Midnight': 'Solar Midnight',
      'act.preview': 'Preview', 'act.stop': 'Stop Preview', 'act.pause': 'Pause', 'act.resume': 'Resume', 'act.follow': 'Follow lights',
      'cfg.title': 'Engine Settings',
      'cfg.status.active': 'ACTIVE', 'cfg.status.paused': 'PAUSED', 'cfg.status.preview': 'PREVIEW', 'cfg.status.idle': 'IDLE',
      'cfg.mode': 'Curve mode',
      'cfg.ct': 'Colour temperature limits',
      'cfg.ct.min': 'Night minimum', 'cfg.ct.max': 'Day maximum',
      'cfg.points': 'Control points', 'cfg.points.count': '{n} / {max} SP',
      'cfg.points.n': '{n} POINTS', 'cfg.points.sub': 'Monotone cubic spline',
      'cfg.locked': 'Settings locked during preview',
      'preview.badge': 'PREVIEW',
      'preview.banner': 'SIMULATION IN PROGRESS · {f}x',
      'preview.callout': '{time} · {b}%',
      'preview.sim': 'SIMULATION: {time} · {b}% · {k}K',
      'sp.title': 'Switchpoint {n}',
      'sp.crumb': '{ctrl} · Schedule',
      'sp.type': 'Schedule type', 'sp.type.time': 'Fixed time', 'sp.type.astro': 'Astronomical',
      'sp.time': 'Time',
      'sp.astro': 'Solar reference & offset', 'sp.offset': 'Time offset',
      'sp.bright': 'Target brightness', 'sp.bright.min': '0% (Off)', 'sp.bright.max': '100% (Max)',
      'sp.cct': 'Colour temperature', 'sp.cct.sub': 'Daylight spectrum',
      'cct.warm': 'WARM', 'cct.neutral': 'NEUTRAL', 'cct.cool': 'COOL',
      'sp.apply': 'Apply changes', 'sp.applying': 'Applying...', 'sp.delete': 'Delete switchpoint',
      'sp.delete.confirm': 'Tap again to delete', 'sp.delete.min': 'At least {n} switchpoints are required',
      'sp.tip': 'SP {n} · {time} · {b}%',
      'empty.title': 'No controller bound',
      'empty.text': 'Add a "Daylight Circadian Controller" driver in Composer and bind it to this webview.',
      'empty.refresh': 'Refresh',
      'err.prefix': 'Error: {msg}',
      'err.timeout': 'No answer from the controller',
      'close': 'Close',
      'unit.min': 'min'
    },
    it: {
      'app.title': 'CIRCADIANA OS',
      'conn.live': 'Connesso', 'conn.wait': 'Connessione...', 'conn.error': 'Connessione persa',
      'conn.lost': 'Connessione persa. Ricarica la pagina.', 'conn.reload': 'Ricarica',
      'help.title': 'Come funziona',
      'help.close': 'Chiudi',
      'help.1': 'La curva mostra la schedule di 24 ore che il controller applica alle luci: luminosit\u00e0 (linea blu) e temperatura colore (gradiente sotto).',
      'help.2': 'Trascina uno switchpoint per spostarlo nel tempo e nella luminosit\u00e0, oppure toccalo per modificarlo nel dettaglio.',
      'help.3': 'Tieni premuto sul gradiente colore per vedere la curva della temperatura colore.',
      'help.4': 'Anteprima riproduce tutta la giornata in circa due minuti sulle luci reali. Segui tutte le luci riallinea le luci modificate a mano.',
      'ctrl.none': 'Nessun controller',
      'curve.title': 'Curva 24 Ore Solare',
      'curve.sub': '{n} switchpoint · {mode}',
      'curve.now': 'ORA {time} · {b}% / {k}K',
      'curve.sub.paused': '{n} switchpoint · {mode} · in pausa',
      'mode.both': 'Lum + CT', 'mode.brightness': 'Solo luminosit\u00e0', 'mode.cct': 'Solo CT',
      'mode.short.both': 'Lum + CT', 'mode.short.brightness': 'Solo Lum', 'mode.short.cct': 'Solo CT',
      'astro.sunrise': 'ALBA', 'astro.solar_noon': 'SOLARE', 'astro.sunset': 'TRAMONTO', 'astro.solar_midnight': 'MEZZANOTTE',
      'astro.ref.Sunrise': 'Alba', 'astro.ref.Solar Noon': 'Mezzogiorno solare', 'astro.ref.Sunset': 'Tramonto', 'astro.ref.Solar Midnight': 'Mezzanotte solare',
      'act.preview': 'Anteprima', 'act.stop': 'Ferma Anteprima', 'act.pause': 'Pausa', 'act.resume': 'Riprendi', 'act.follow': 'Segui luci',
      'cfg.title': 'Configurazione Motore',
      'cfg.status.active': 'ATTIVO', 'cfg.status.paused': 'IN PAUSA', 'cfg.status.preview': 'ANTEPRIMA', 'cfg.status.idle': 'INATTIVO',
      'cfg.mode': 'Modalit\u00e0 curva',
      'cfg.ct': 'Limiti temperatura colore',
      'cfg.ct.min': 'Minima notturna', 'cfg.ct.max': 'Massima diurna',
      'cfg.points': 'Punti di controllo', 'cfg.points.count': '{n} / {max} SP',
      'cfg.points.n': '{n} PUNTI', 'cfg.points.sub': 'Spline cubica monotona',
      'cfg.locked': 'Parametri bloccati in Anteprima',
      'preview.badge': 'ANTEPRIMA',
      'preview.banner': 'SIMULAZIONE IN CORSO · {f}x',
      'preview.callout': '{time} · {b}%',
      'preview.sim': 'SIMULAZIONE: {time} · {b}% · {k}K',
      'sp.title': 'Switchpoint {n}',
      'sp.crumb': '{ctrl} · Schedule',
      'sp.type': 'Tipo schedulazione', 'sp.type.time': 'Ora fissa', 'sp.type.astro': 'Astronomico',
      'sp.time': 'Orario',
      'sp.astro': 'Riferimento solare e offset', 'sp.offset': 'Scostamento temporale',
      'sp.bright': 'Luminosit\u00e0 target', 'sp.bright.min': '0% (Spento)', 'sp.bright.max': '100% (Massimo)',
      'sp.cct': 'Temperatura colore', 'sp.cct.sub': 'Spettro diurno',
      'cct.warm': 'CALDA', 'cct.neutral': 'NEUTRA', 'cct.cool': 'FREDDA',
      'sp.apply': 'Applica modifiche', 'sp.applying': 'Applico...', 'sp.delete': 'Elimina switchpoint',
      'sp.delete.confirm': 'Tocca ancora per eliminare', 'sp.delete.min': 'Servono almeno {n} switchpoint',
      'sp.tip': 'SP {n} · {time} · {b}%',
      'empty.title': 'Nessun controller legato',
      'empty.text': 'Aggiungi un driver "Daylight Circadian Controller" in Composer e legalo a questa webview.',
      'empty.refresh': 'Aggiorna',
      'err.prefix': 'Errore: {msg}',
      'err.timeout': 'Nessuna risposta dal controller',
      'close': 'Chiudi',
      'unit.min': 'min'
    }
  };

  var lang = 'en';

  function detect() {
    var l = (navigator.language || navigator.userLanguage || 'en') + '';
    return /^it/i.test(l) ? 'it' : 'en';
  }

  // t('chiave', { n: 4 }) -> testo con i segnaposto {n} sostituiti
  function t(key, vars) {
    var s = (DICT[lang] && DICT[lang][key]);
    if (s === undefined) { s = DICT.en[key]; }
    if (s === undefined) { return key; }
    if (vars) {
      s = s.replace(/\{(\w+)\}/g, function (m, k) { return vars[k] !== undefined ? vars[k] : m; });
    }
    return s;
  }

  function setLang(l) {
    var next = /^it/i.test(l || '') ? 'it' : 'en';
    if (next === lang) { return false; }
    lang = next;
    document.documentElement.lang = lang;
    return true;
  }

  DC.i18n = { t: t, setLang: setLang, getLang: function () { return lang; }, detect: detect, DICT: DICT };
  DC.t = t;
  setLang(detect());
})(window.DC = window.DC || {});
