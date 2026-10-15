# DESIGN — Nocturne Architectural OS per la webview Daylight Circadian

Fonte **normativa** del design della webview. È derivata, per estrazione e adattamento, dal design
system *Nocturne Architectural OS* (già validato su pannello T4 8" reale): qui non è una dipendenza
né un rimando. Le parti specifiche di altre applicazioni (planimetria, pucks dei dispositivi,
drawer delle zone, scene) **non** sono state portate. Se un valore serve e qui manca, si aggiunge a
questo file con la sua origine; non si inventa nel CSS.

Si legge insieme a [ARCHITECTURE.md §3b/§3d](ARCHITECTURE.md) (protocollo e decisioni).

## 1. Cosa è normativo

| Blocco | Contenuto | Stato |
|---|---|---|
| Front-matter (§2) | accenti funzionali, tipografia, raggi, spaziature, touch target | **normativo** |
| Tier di superficie, hairline, testo, stato di connessione (§3) | `#0A0D14`, `#141A29`, `#1E283D`, `#273550`, `#2A3750`, `#F8FAFC`… | **normativo** |
| Regole hardware (§6) | form factor T4 8", prestazioni | **normativo** |
| Componenti circadiani (§7) | curva, marker, gradiente CT, preview, ContextSheet, stati | **normativo** |
| Il resto dei design system d'origine | componenti di altre applicazioni | non adottato |

**Decisione palette.** Il design system d'origine ha due palette in apparenza in conflitto: i token
del front-matter (accenti `#adc6ff`, `#ffb95f`, `#4edea3`, superfici tonali Material) e la
prosa (cobalto `#3B82F6`, ambra `#F59E0B`, tier `#0A0D14`→`#273550`). La webview usa
**gli accenti del front-matter con le superfici-tier della prosa**; è la combinazione adottata:

- **accenti, tipografia, raggi, spaziature, touch target → front-matter (§2)**;
- **superfici, hairline, testo e colori dello stato di connessione → tier della prosa (§3)**;
- il cobalto `#3B82F6` e l'ambra `#F59E0B` della prosa **non** si usano.

Per cambiare palette si cambiano le variabili in `css/nocturne-tokens.css` e le poche occorrenze
letterali dei gradienti SVG in `js/curve-renderer.js` e `js/context-sheet.js` (`#adc6ff`,
`#ffb95f`, `#141a29`). Nel codice non c'è nessun altro colore pieno fuori da §2/§3 (verificato
con una scansione dei valori letterali); le varianti alfa sono quelle ammesse in §3.

## 2. Token del front-matter (normativi, invariati)

```yaml
name: Nocturne Architectural OS
colors:
  surface: '#0e1320'
  surface-dim: '#0e1320'
  surface-bright: '#343947'
  surface-container-lowest: '#090e1b'
  surface-container-low: '#161b29'
  surface-container: '#1a1f2d'
  surface-container-high: '#252a38'
  surface-container-highest: '#303443'
  on-surface: '#dee2f5'
  on-surface-variant: '#c2c6d6'
  inverse-surface: '#dee2f5'
  inverse-on-surface: '#2b303e'
  outline: '#8c909f'
  outline-variant: '#424754'
  surface-tint: '#adc6ff'
  primary: '#adc6ff'
  on-primary: '#002e6a'
  primary-container: '#4d8eff'
  on-primary-container: '#00285d'
  inverse-primary: '#005ac2'
  secondary: '#ffb95f'
  on-secondary: '#472a00'
  secondary-container: '#ee9800'
  on-secondary-container: '#5b3800'
  tertiary: '#4edea3'
  on-tertiary: '#003824'
  tertiary-container: '#00a572'
  on-tertiary-container: '#00311f'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#d8e2ff'
  primary-fixed-dim: '#adc6ff'
  on-primary-fixed: '#001a42'
  on-primary-fixed-variant: '#004395'
  secondary-fixed: '#ffddb8'
  secondary-fixed-dim: '#ffb95f'
  on-secondary-fixed: '#2a1700'
  on-secondary-fixed-variant: '#653e00'
  tertiary-fixed: '#6ffbbe'
  tertiary-fixed-dim: '#4edea3'
  on-tertiary-fixed: '#002113'
  on-tertiary-fixed-variant: '#005236'
  background: '#0e1320'
  on-background: '#dee2f5'
  surface-variant: '#303443'
typography:
  display-lg:   { fontFamily: Plus Jakarta Sans, fontSize: 40px, fontWeight: '600', lineHeight: 48px, letterSpacing: -0.02em }
  headline-xl:  { fontFamily: Plus Jakarta Sans, fontSize: 32px, fontWeight: '600', lineHeight: 40px, letterSpacing: -0.015em }
  headline-lg:  { fontFamily: Plus Jakarta Sans, fontSize: 24px, fontWeight: '600', lineHeight: 32px, letterSpacing: -0.01em }
  headline-md:  { fontFamily: Plus Jakarta Sans, fontSize: 20px, fontWeight: '500', lineHeight: 28px, letterSpacing: -0.005em }
  body-lg:      { fontFamily: Inter, fontSize: 16px, fontWeight: '400', lineHeight: 24px }
  body-md:      { fontFamily: Inter, fontSize: 14px, fontWeight: '400', lineHeight: 20px }
  body-sm:      { fontFamily: Inter, fontSize: 12px, fontWeight: '400', lineHeight: 16px }
  label-lg:     { fontFamily: Inter, fontSize: 14px, fontWeight: '500', lineHeight: 20px, letterSpacing: 0.01em }
  label-md:     { fontFamily: Inter, fontSize: 12px, fontWeight: '600', lineHeight: 16px, letterSpacing: 0.02em }
  code-telemetry: { fontFamily: JetBrains Mono, fontSize: 13px, fontWeight: '500', lineHeight: 18px, letterSpacing: 0.03em }
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  space-2xs: 0.25rem
  space-xs: 0.5rem
  space-sm: 0.75rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2rem
  space-2xl: 3rem
  touch-target-min: 48px
  touch-target-optimal: 56px
  cad-grid-step: 8px
```

Ruoli degli accenti nella webview: `primary` curva della luminosità e azioni
primarie · `secondary` marker degli switchpoint, valori di luminosità, "adesso" · `tertiary` linee e
tag astronomici, curva CT, stato attivo · `error`/`error-container` anteprima (e solo quella).
`--on-surface`, `--on-surface-variant`, `--outline`… in `nocturne-tokens.css` mappano gli omonimi
`on-surface`, `on-surface-variant`, `outline`… del front-matter **tranne** dove §3 fissa un valore
di testo diverso.

## 3. Superfici, hairline, testo, connessione (normativi)

| Ruolo | Valore | Variabile CSS |
|---|---|---|
| Canvas assoluto | `#0A0D14` | `--canvas` |
| Tier 1 (TopBar, scheda curva) | `#141A29` | `--tier1` |
| Tier 2 (scheda configurazione, campi) | `#1E283D` | `--tier2` |
| Tier 3 (ContextSheet, modal, flyout) | `#273550` | `--tier3` |
| Livello 4, vetro (solo ≥ 1920 px) | `#1F2B42`, bordo `#3B4D70`, scrim `rgba(10,13,20,.75)` | — |
| Hairline | `#2A3750` (base), `#3B4D70` (rialzato/hover) | `--hairline`, `--hairline-hi` |
| Testo alta enfasi | `#F8FAFC` | `--on-surface` |
| Testo media enfasi | `#94A3B8` | `--on-surface-variant` |
| Testo secondario/assi | `#64748B` | `--outline` |
| Testo spento / unità inattive | `#475569` | `--text-dim` |
| Connessione live / errore / in attesa | `#10B981` / `#EF4444` / `#FBBF24` | `--conn-live` / `--conn-error` / `--conn-wait` |

**Varianti ammesse, nient'altro.** Si possono derivare: (a) varianti **alfa** di un token (glow,
riempimenti traslucidi, scrim, bordi); (b) **nero alfa** per le ombre e **bianco alfa** per il
filo di luce (`inset 0 1px 0 rgba(255,255,255,.08)`). Qualunque altro colore pieno va prima
aggiunto qui. Fa eccezione il colore del **gradiente CT**, che non è un token: è calcolato dalla
temperatura (§7.3).

Il dot di connessione riflette **solo** la connessione (verde live, rosso errore, ambra
lampeggiante in attesa): **mai** stati applicativi come anteprima o pausa, che hanno già badge e
banner dedicati.

## 4. Tipografia

- **Plus Jakarta Sans**: titoli e navigazione (titolo TopBar 16/600 con `letter-spacing .04em`,
  titoli di scheda 18/600 e 15/600, titolo sheet 22/600, modal 20/600).
- **Inter**: testo e controlli (14/400–500, etichette 12–13/500–600, eyebrow 11/600 maiuscolo
  `letter-spacing .08em`).
- **JetBrains Mono**: numeri e telemetria, per evitare il jitter negli aggiornamenti (orari, K,
  percentuali, offset, assi, tag astro, tooltip).
- Pesi disponibili nei woff2 vendorizzati: Plus Jakarta Sans **500–600**, Inter **400–600**,
  JetBrains Mono **500**. Il peso 700 del design d'origine **non** esiste nel pacchetto: i titoli
  che lo prevedono usano 600.

## 5. Forma, griglia, elevazione

- Raggi: pannelli e card `1rem` (`--r-lg`), sheet `1.5rem` (`--r-xl`), controlli `.5–.75rem`, pill
  `9999px`. Marker e thumb: cerchi.
- Griglia da **8 px**; padding e margini sono multipli di 4/8.
- **Touch target mai sotto 48 px**, 56 px per i controlli primari (Applica, slider della sheet).
  Su T4 8" (5,6 px CSS/mm): 48 px ≈ 8,6 mm, 56 px ≈ 10,1 mm. Un elemento visivamente più piccolo
  (marker da 15 px, thumb da 28 px) ha un'area sensibile invisibile di almeno 48 px.
- Elevazione senza ombre pesanti: livelli tonali (canvas → Tier 1 → 2 → 3), bordo da 1 px
  `--hairline`, vetro e blur **solo** da 1920 px.

## 6. Regole imparate sull'hardware (T4 8" C4-T4IW8, 1920×1200, DPR≈2)

Il viewport utile della webview è **967×532 CSS px** (il chrome di Navigator, ~68 px, sta fuori
dalla pagina). Tutte le regole sotto vengono da prove sul pannello reale e non si cambiano senza
riprovarle:

1. **TopBar flottante sotto 1920 px**: non è una riga che occupa spazio, ma un overlay
   (`position:absolute`, scrim che sfuma a trasparente, `pointer-events:none` tranne i figli
   interattivi); da 1920 px torna riga fissa da 64 px.
2. **Niente `backdrop-filter` sotto 1920 px**: un blur ricalcolato a ogni frame è un contributo
   misurato di lag. Sotto 1920 px le superfici flottanti sono solide (Tier 2/3); da 1920 px vetro
   con `blur(20px)`.
3. **Glow congelato** durante drag di marker/slider e con la ContextSheet aperta: un solo
   ricalcolo al rilascio; raggio dell'alone a passi da 10 unità di luminosità e colore a passi da
   100 K, così una variazione ordinaria raramente cambia il rendering. Contributo misurato di lag
   sul pannello.
4. **`overscroll-behavior: contain`** su ogni scroller interno (body, main, sheet, modal,
   scheda configurazione): un drag a fine corsa non deve trascinare la pagina sotto.
5. **`touch-action: none`** sugli slider e sul grafico: un gesto che parte lì non scorre mai.
6. **ContextSheet flottante** sotto 1920 px: `top:68px; right:12px; bottom:12px` (libera la TopBar
   da 56 px più margine), larghezza **460 px** da 900 px, **960 px** da 1920 px, bottom sheet sotto
   900 px. (Il design d'origine ha un tier intermedio da 640 px a 1366–1919: non adottato.)
   Il corpo è l'unico scroller; su 532 px il corpo scorre e il footer a pila resta fisso.
7. **Dot di connessione** sempre visibile a sinistra della TopBar; mai riusato per altro (§3).
8. **Niente icone o bottoni senza azione**: ogni elemento che sembra un controllo deve fare
   qualcosa (la TopBar non ha un logo-bottone; il "?" apre l'aiuto).
9. **Asset versionati**: CSS e JS portano `?v=<versione driver>` (lo stampa `tools/build.ps1`):
   Navigator mette in cache i file separati per pannello.
10. Browser dei T4 ≈ Firefox 96: niente funzioni più recenti di Firefox 85 e nessuna risorsa
    esterna.

Breakpoint: **< 900 px** telefono (colonna singola che scorre, ContextSheet come bottom sheet) ·
**900–1919 px** T4/tablet (due colonne 1fr + 300 px, TopBar flottante, sheet 460 px) ·
**≥ 1920 px** pannello grande (colonna config 380 px, TopBar riga fissa, sheet 960 px, vetro).

## 7. Componenti circadiani

### 7.1 TopBar
Dot di connessione (10 px, **nessun titolo**: su 532 px di altezza non serve) · pill del
controller, **centrata** (griglia a 3 colonne da 900 px in su, flex sotto) (48 px, nome + chip `#id` in mono; **chevron e menu solo se i controller sono più di
uno**, altrimenti è un'etichetta disabilitata) · badge `ANTEPRIMA` (pill `error-container`, solo
in anteprima) · pulsante **?** (48 px, cerchio) che apre il modal di aiuto. Nessun altro elemento.

### 7.2 Curva SVG
SVG inline, nessun canvas né libreria. Disegna i **144 campioni** `[t, luminosità, CCT]` di
`curve:samples(10)` del controller: **non** calcola la curva (ARCHITECTURE §3d). Asse X 00:00–24:00
con griglia ogni 2 h, asse sinistro 0–100 % ogni 20 %, asse destro in Kelvin sui CT limits. Linea
`primary` da 3 px con area `primary` da 22 % a 0. Linee astronomiche tratteggiate `tertiary` con
tag (mono 10/600, su `on-tertiary` all'85 % con bordo `tertiary` al 50 %) su due righe; il tag
"mezzanotte" sparisce se il grafico è largo meno di 420 px. Marcatore "adesso": linea e punto
`secondary`.

### 7.3 Gradiente CT temporale e press-and-hold
Barra da 10 px sotto la curva con `linearGradient` **temporale**: un colore ogni 20 minuti dalla CCT
del campione (caldo la sera e la notte, freddo a mezzogiorno), come la schedule reale e non un
semplice min→max. Il colore da Kelvin è l'approssimazione di corpo nero di Tanner Helland. Etichette
Kelvin (mono 10/600, nel colore del punto) a 00:00, alba, mezzogiorno solare, tramonto, 24:00,
senza avvicinarsi sotto i 50 px. **Tenendo premuto 500 ms** la barra o le etichette (area da 48 px)
compare la curva CT (`tertiary` 2,5 px, opacità 0,8) e l'asse destro si accende; al rilascio sfuma
in 300 ms.

### 7.4 Marker degli switchpoint
Cerchio da 15 px (`secondary`, bordo Tier 1), alone `secondary` al 18 %, area sensibile da 48 px.
**Tocco** (spostamento < 6 px) apre la ContextSheet. **Drag**: segue il dito con un tooltip
(`SP n · HH:MM · b%`, mono 11/600); orizzontale a passi di 5 minuti, verticale al punto percentuale;
**la richiesta parte solo al rilascio** (a ogni movimento le luci reali si riallineerebbero) e solo
con i campi cambiati. Su uno switchpoint **astronomico** il drag orizzontale cambia l'**offset
(±180 min)** rispetto al riferimento, mai il tipo; su uno **Set Time** cambia l'orario. In
modalità *Colour Temperature Only* il drag verticale è disattivato. Marker attivo (sheet aperta):
pieno `on-surface` con bordo `secondary`; in attesa di conferma: opacità 55 %. Disattivati in
anteprima.

### 7.5 Azioni rapide
Pill da 48 px (`padding 0 16px`, 14/600): **Anteprima/Ferma anteprima** (primary / error),
**Pausa**, **Riprendi**, **Segui luci** (op `FOLLOW`, icona link, pallino `secondary` se una luce è
in override manuale). Disabilitate = opacità 0,4 e nessun puntatore. Pausa solo se lo stato è
`ACTIVE`; Riprendi solo se `PAUSED`; entrambe attenuate in anteprima. Riprendi resta visibile (non
sposta il layout).

### 7.6 Scheda configurazione
Tier 2, 300 px (380 px da 1920). **Modalità curva**: segmented a 3 (Lum + CT / Solo Lum / Solo CT).
**Limiti temperatura colore**: due slider (1600–6500 K, passo 100 K) con **clamp live** `min < max`
(almeno 100 K) anche durante il drag, invio al rilascio. **Punti di controllo**: stepper 3–10 con
pulsanti da 48 px, tenere premuto ripete, un solo invio dopo l'ultimo tocco (600 ms). Slider: pista
da 14 px, thumb da 28 px, area sensibile da 48 px (56 px nella sheet), riempimento a gradiente fino
al thumb, bolla con il valore durante il drag. In anteprima la scheda è bloccata da un overlay
("Parametri bloccati in Anteprima").

### 7.7 Anteprima
24 ore in `duration_s` secondi (oggi 120): **fattore = 86400 / duration_s** (720×), calcolato, mai
fisso. Elementi, ciascuno **una sola volta**: badge `ANTEPRIMA` in TopBar · sotto-titolo della
scheda `SIMULAZIONE IN CORSO · 720x` in `error` e pill `SIMULAZIONE: HH:MM · L% · K` (`error-container`
al 40 %, mono 12/600, pallino che pulsa) · linea tratteggiata `error` con punto sul marker e
**callout** `HH:MM · L%` (`error-container`). Scheda configurazione bloccata; Pausa e Riprendi
attenuate. Il dot di connessione **non cambia**. Lo stesso valore di tempo non compare una terza volta.

### 7.8 ContextSheet "Modifica switchpoint"
Superficie Tier 3 (solida; vetro `#1F2B42` + blur solo da 1920 px), raggio 1,5 rem, bordo
`--hairline-hi`, scrim `rgba(10,13,20,.6)`. Apertura slide-in da destra (bottom sheet su telefono)
**300 ms** ease-out, chiusura **200 ms**. Aprirla congela il glow.

- **Header**: `Switchpoint N` (Jakarta 22/600), breadcrumb `Controller · Schedule · SP N (HH:MM)`
  con l'orario risolto in `secondary` mono, chiudi cerchio da 48 px.
- **Tipo**: segmented *Ora fissa* / *Astronomico*. Ora fissa → time picker a due colonne
  scorrevoli con snap da 48 px a riga, mono 24. Astronomico → dropdown del riferimento (Alba,
  Mezzogiorno solare, Tramonto, Mezzanotte solare, con l'orario di oggi) + **stepper dell'offset**
  (−180…+180 min, passo 5, pulsanti da 48 px, tenere premuto ripete).
- **Luminosità**: slider 0–100 % con gradiente da Tier 1 a `secondary`, valore in `secondary`.
- **Temperatura colore**: slider con range = CT limits del controller, gradiente dei colori
  Kelvin, valore nel colore del punto e **pill** Calda (< 3500 K, `secondary`) / Neutra
  (3500–5000 K, `tertiary`) / Fredda (> 5000 K, `primary`).
- **Footer**: *Applica modifiche* (primario, 56 px, invia **solo i campi cambiati**; nessuna
  modifica = si chiude) e *Elimina switchpoint* (outline, `DELETE_SWITCHPOINT`, **conferma al
  secondo tocco**, disabilitato con 3 punti).
- Lavora su una bozza: uno `STATE` che arriva mentre è aperta aggiorna solo i dati di contorno
  (conteggio, orari astro), mai i valori che l'utente sta editando.

### 7.9 Stati della pagina
- **Caricamento**: skeleton con shimmer (1,4 s) che ricalca curva, azioni e configurazione.
- **Nessun controller** (solo dopo una risposta che lo conferma): card centrale con icona,
  testo e pulsante *Aggiorna*; **mai** una curva orfana.
- **Connessione persa**: dopo 30 s senza messaggi, banner `error-container` con *Ricarica* e dot
  rosso. Heartbeat leggero ogni 10 s, risincronizzazione ogni 30 s.
- **Errori**: toast in basso, 5 s, **solo per azioni dell'utente** (mai per i poll in background),
  scadenza delle azioni 8 s, **al più uno ogni 30 s per la stessa operazione**.

## 8. Font, licenze, lingua

- Font **vendorizzati** (`www/dist/fonts/*.woff2`, sottoinsiemi Latin non modificati); la licenza
  SIL OFL 1.1 viaggia nel pacchetto (`fonts/LICENSE.txt`) e in
  [THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md). Zero richieste di rete.
- **i18n IT/EN**: dizionario in `js/i18n.js`; la lingua arriva dalla proprietà *Language* del driver
  webview (il locale del progetto Control4), prima dalla lingua del dispositivo; fallback inglese.
  Orari sempre `HH:MM` 24 h, temperature in K. I testi italiani usano gli accenti veri.
