# ARCHITECTURE — Control4-Daylight-Circadian

Descrizione architetturale della suite di driver `daylight_circadian_controller`
+ `daylight_circadian_webview`. Il design della UI è in [DESIGN.md](DESIGN.md); le guardie
sui casi limite, con i riferimenti `vNNN` (versioni del changelog pubblico di un prodotto
analogo), in [EDGE_CASES.md](EDGE_CASES.md).

> Convenzione del documento: ciò che è **verificato su hardware** (Composer Pro 3.4.3, pannello
> T4, app iOS/Android) è detto esplicitamente; ciò che la documentazione ufficiale Control4 non
> descrive è indicato come *non documentato*. Le parti marcate *(proposta)* sono scelte di design
> di questo documento.

## 1. Panoramica

Due driver DriverWorks che sostituiscono il Daylight agent nativo di Snap One
(`<agent>true</agent>`, singleton, 3 anchor + dial) con un controllo circadiano
di luminosità e CCT su luci Light V2 tunable white, configurabile da Composer e
da una WebView su touch panel/app.

| Driver | Ruolo | Istanze | Proxy |
|---|---|---|---|
| `daylight_circadian_controller` | Motore Lua: schedule, calcolo solare, curva, comandi alle luci, monitoring | **Multi-istanza** (1 per schedule / gruppo di luci) | proxy omonimo del driver |
| `daylight_circadian_webview` | UI web: elenco controller, grafico curva, editor switchpoint, preview | **Singleton** | `uibutton` |

## 2. Diagramma a blocchi

```
 ┌────────────────────────────────────────────────────────────────────────────┐
 │ Director Control4 (OS ≥ 3.3.0, testato 3.4.3)                              │
 │                                                                            │
 │  ┌──────────────────────────────┐        ┌────────────────────────────┐    │
 │  │ daylight_circadian_controller│        │ daylight_circadian_webview │    │
 │  │ (N istanze, Lua non cifrato) │        │ (singleton, proxy uibutton)│    │
 │  │                              │        │                            │    │
 │  │  driver.lua (entrypoint)     │        │  driver.lua                │    │
 │  │   ├ libs/sun.lua             │ binding│   └ enumera i controller   │    │
 │  │   ├ libs/curve.lua           │ custom │                            │    │
 │  │   ├ libs/monitor.lua         │◄──────►│  www/dist/index.html (JS)  │    │
 │  │   ├ libs/persist.lua         │ DAYLIGHT_CIRCADIAN_COMMS            │    │
 │  │   └ libs/debug.lua           │ (autobind)                          │    │
 │  │                              │  conn. id 1, type 1, facing 6       │    │
 │  │  consumer = True             │        │  consumer = False          │    │
 │  └──────┬───────────────────────┘        └──────────┬─────────────────┘    │
 │         │ SET_COLOR_TARGET                           │ conn. id 5001        │
 │         │ SET_BRIGHTNESS_TARGET                      │ type 2, UIBUTTON     │
 │         ▼                                            ▼                      │
 │  ┌──────────────┐                          ┌────────────────────┐          │
 │  │ Light V2     │                          │ Navigator (T4 /    │          │
 │  │ (CCT)        │─variabili 1000/1001─►        │ app mobile)        │          │
 │  └──────────────┘   (monitoring)           │ controller://driver│          │
 │                                            │ /…/dist/index.html │          │
 │                                            └────────────────────┘          │
 └────────────────────────────────────────────────────────────────────────────┘
```

Nessun componente esterno: niente cloud, niente licensing, niente server
esterno.

## 3. Binding `DAYLIGHT_CIRCADIAN_COMMS` (autobind)

Canale di comunicazione fra i controller e il webview.

| | `daylight_circadian_controller` | `daylight_circadian_webview` |
|---|---|---|
| `<id>` | 1 | 1 |
| `<type>` / `<facing>` | 1 / 6 | 1 / 6 |
| `<connectionname>` | `Interdriver Comms Interface` | `Interdriver Comms Interface` |
| `<consumer>` | `True` | `False` |
| `<classname>` | `DAYLIGHT_CIRCADIAN_COMMS` | `DAYLIGHT_CIRCADIAN_COMMS` |
| `<autobind>` | `True` | `True` |

Con `autobind` Composer collega automaticamente ogni controller (consumer) al
webview (provider): il webview **enumera i controller attraverso il binding**,
senza che l'installatore debba cablare nulla a mano.

Messaggi, canali JS ↔ Lua e proprietà come fonte di verità: sezione
[3b. Comms protocol](#3b-comms-protocol). Se nessun webview è legato i controller
funzionano come prima: `env.send_to_webview` non ha destinatari e i push sono no-op
(la UI è opzionale).

### 3b. Comms protocol

Implementazione: `libs/protocol.lua` (schema e validazione), `libs/json.lua` (codec
senza dipendenze dal locale), `libs/engine.lua` (lato controller), `libs/hub.lua`
(lato webview). Versione corrente: **v = 1**.

```
 pagina (JS)                 webview (hub)                          controller (engine)
 ───────────                 ─────────────                          ───────────────────
 C4.sendCommand("DC_CMD",    UIRequest/ExecuteCommand
   {controller, op, args}) ─►  valida (protocol)  ─ SendToDevice(id, "DC_REQUEST", {json}) ─►  ExecuteCommand
                                                                                             │ UpdateProperty(...) +
                                                                                             │ ricostruzione curva
 onDataToUi(...)         ◄─  C4:SendDataToUI("DC_EVENT", {json}) ◄─ ReceivedFromProxy(1, "DC_MESSAGE") ◄─ SendToProxy(1, "DC_MESSAGE", {json})
                                                                                      (ACK, STATE, PREVIEW, HELLO)
```

**Trasporto.** Ogni messaggio è un oggetto JSON in **un solo parametro stringa**
(`json`) dei comandi Control4 (i parametri dei comandi sono tabelle piatte di
stringhe: il JSON evita di perdere tipi e annidamento).

| Direzione | Meccanismo (documentato) | Ricezione |
|---|---|---|
| webview → controller | `C4:SendToDevice(id_controller, "DC_REQUEST", {json})` | `ExecuteCommand("DC_REQUEST", …)`; accettato anche `ReceivedFromProxy(1, "DC_REQUEST", …)` |
| controller → webview | `C4:SendToProxy(1, "DC_MESSAGE", {json})` sul binding comms | `ReceivedFromProxy(1, "DC_MESSAGE", …)` |
| pagina → webview | `C4.sendCommand(nome, params, async, true)` | `UIRequest(nome, params)` (sincrono, ritorna una stringa JSON) / `ExecuteCommand` (async) |
| webview → pagina | `C4:SendDataToUI("DC_EVENT", {json})` | `window.onDataToUi(risposta)` dopo `C4.subscribeToDataToUi(true)` (`true` = DATA_TO_UI del *protocollo*, cioè di `C4:SendDataToUI`) |

**Discovery.** Il webview (provider del binding) elenca i controller legati con
`C4:GetBoundConsumerDevices(0, 1)` (id → nome) all'avvio, a ogni `OnBindingChanged`
sul binding 1 e ogni 60 s; a ogni controller nuovo manda `GET_STATE`. In senso
inverso, il controller manda `HELLO` + `STATE` a fine `OnDriverLateInit` e quando il
binding si lega (`OnBindingChanged` con `bIsBound`).
`OnBindingChanged` fornisce anche `otherDeviceID`/`otherBindingID`.

**Richiesta** (webview → controller):
`{ v:1, id:"w12", op:"…", args:{…}, from:<id> }`

| `op` | `args` | Effetto |
|---|---|---|
| `GET_STATE` | — | ACK con lo snapshot completo |
| `SET_SWITCHPOINT` | `n` 1..10, e almeno uno fra: `type` (`Set Time`/`Astronomical`), `time` `HH:MM`, `astroRef` (`Sunrise`, `Solar Noon`, `Sunset`, `Solar Midnight`), `offset` −180..180, `brightness` 0..100, `cct` 1600..6500 | scrive le proprietà `SP n …` |
| `SET_CT_LIMITS` | `min`, `max` (1600..6500, min ≤ max) | `Minimum/Maximum Colour Temperature` |
| `SET_MODE` | `mode`: `Brightness + Colour Temperature` / `Brightness Only` / `Colour Temperature Only` (alias `both`/`brightness`/`cct`) | `Scheduler Mode` |
| `DELETE_SWITCHPOINT` | `n` 1..10 | elimina lo SP `n`: i successivi scalano di una posizione (le proprietà `SP n …` vengono riscritte) e `Number of Switchpoints` cala di 1; rifiutata se gli SP sono già 3 (minimo) |
| `SET_NUM_SP` | `count` 3..10 | `Number of Switchpoints` |
| `PAUSE`, `RESUME`, `PREVIEW`, `STOP_PREVIEW`, `FOLLOW` | — | come le azioni di Composer; transizioni vietate ⇒ ACK `ok:false` |

Validazione **sia nell'hub sia nel controller** (nessuna proprietà viene toccata se la
richiesta non è valida). Numeri accettati anche come stringa.

**Messaggi** (controller → webview), tutti con `v:1` e `controller:<id>`:

| `type` | Contenuto | Quando |
|---|---|---|
| `ACK` | `id`, `op`, `ok`, `error?`, `state?` (`GET_STATE`/stato dopo l'operazione) | risposta a ogni richiesta |
| `STATE` | snapshot (sotto) | a ogni ricostruzione della schedule (modifica da Composer **o** dalla webview, mezzanotte), cambio di stato, cambio dei flag di override, cambio delle luci; **mai ripetuto se identico** al precedente |
| `PREVIEW` | `active`, `minute`, `step`, `steps`, `duration_s`, `brightness`, `cct` | a ogni passo della preview (≈ 1.2 s) e alla chiusura (`active:false`). `brightness`/`cct` sono il target di quel passo (CCT già nei CT limits); `duration_s` è la durata reale della preview: **fattore di accelerazione = 86400 / duration_s** (720× con 120 s), mai un valore fisso |
| `HELLO` | `name` | avvio / binding |

**Snapshot `STATE`:**
`{ v, type:"STATE", controller, name, state ("IDLE"|"ACTIVE"|"PAUSED"|"PREVIEW"), preview:{active, minute?, duration_s}, monitoring,
mode, count, ct:{min,max}, switchpoints:[{n, type, time?, astroRef, offset, brightness, cct, t?, at?, label}],
warnings:[…], lights:[{id, level?, overridden}], astro?:{date, offset, sunrise, solar_noon, sunset, solar_midnight, polar?},
curve:{step:10, samples:[[t, brightness, cct], …144]} }`.
`time` è il valore della proprietà (Set Time); `t`/`at` l'istante **risolto** (minuti /
`HH:MM`, già con offset e arrotondato al minuto); `warnings` include le collisioni fra SP.

**Il codec e il locale.** `tostring`/`tonumber` dipendono dal locale del controller
(virgola decimale su un progetto italiano): `libs/json.lua` scrive e legge i numeri a
mano, sempre col punto.

**Canale JS ↔ Lua (documentato, proxy UI Button):** `C4.sendCommand(cmd, jsonParams,
async, sendToProtocol)` (sync ⇒ `UIRequest`, async ⇒ `ExecuteCommand`; **`sendToProtocol` deve essere `true`**: con `false` il comando va al proxy UI Button e `onDataToUi` riceve solo un ack `{name:"SendToDevice", result:1}` del Broker. Verificato su T4/app anche con `true`: Navigator invoca **sia `UIRequest` sia `ExecuteCommand`** per lo stesso comando, e il valore di ritorno di `UIRequest` **non** arriva alla pagina (l'ack ha `$t` vuoto). Per questo ogni risposta è inviata anche come `C4:SendDataToUI` e ogni richiesta porta un id `rid` (unico per pagina e ricaricamento) con cui il driver scarta il doppione — altrimenti un `DC_CMD` girerebbe due volte),
`C4.subscribeToDataToUi`, `C4.subscribeToVariable`; le risposte tornano **sempre** da
`onDataToUi`. Disponibile solo per pagine ospitate dal driver (`controller://…`), non per URL
esterni. Browser delle T4: Firefox 96 ⇒ JS in stile ES5/ES2015. **Verificato su T4/app:**
- `C4:SendDataToUI("DC_EVENT", {json=...})` arriva alla pagina come
  `{"devicecommand":{"command":"DC_EVENT","params":{"param":[{"name":"json","value":{"type":"string","static":"<JSON del messaggio>"}}]}}}`:
  il messaggio è una **stringa JSON annidata** (l'`extract()` della pagina la attraversa).
- **Gli oggetti annidati nei parametri di `C4.sendCommand` non arrivano integri al driver**
  (un `args:{n:1,…}` è arrivato senza `n`): gli argomenti viaggiano come **stringa JSON**
  (`args:"{\"n\":1,…}"`), decodificata dall'hub.
- Le risposte di errore dell'hub (`{ok:false,error}`) tornano alla pagina come push.
- Ogni risposta dell'hub riporta il `rid` scelto dalla pagina (`DC_CMD` → `{ok, queued, id, rid}`;
  l'`id` è quello che ritroverà nell'ACK del controller): così la pagina collega richiesta, risposta
  e ACK senza affidarsi al valore di ritorno di `UIRequest`, che non le arriva.

**Verificato su hardware:** `onDataToUi` consegna i push
(`SendDataToUI`) e la forma è quella sopra; il canale webview → controller
(`SendToDevice(id, "DC_REQUEST")` → `ExecuteCommand`, comando **non** dichiarato in
`<commands>`) e controller → webview (`SendToProxy(1, "DC_MESSAGE")`) funzionano.

### 3c. Proprietà Composer ↔ webview (decisione)

**Scelta: (1) le proprietà del controller sono la fonte di verità; la webview le
modifica tramite il controller.** Il controller riceve `SET_*`, scrive le **proprie**
proprietà con `C4:UpdateProperty`, ricostruisce la curva e pubblica lo `STATE`.

Motivazioni:
- Lo stesso schedule deve potersi configurare sia dalle proprietà (Composer) sia dalla webview:
  due viste dello stesso dato, con una sola fonte di verità.
- Un solo archivio ⇒ nessuna divergenza: la schedule persistita come copia (opzione 2)
  dovrebbe essere riconciliata con le proprietà a ogni modifica da Composer, e dopo un
  restart non si saprebbe quale delle due vince. Le proprietà le persiste già Director.
- Esiste anche `C4:SendToDevice(id, "UPDATE_PROPERTY", {Name=…, Value=…})`, documentato
  nelle Best Practices del Proxy Protocol: un driver può modificare le proprietà di un
  altro. Non lo usiamo per la webview perché il controller deve comunque validare,
  ricostruire la curva e rispondere con un ACK: passando dal controller c'è un solo punto
  di scrittura e un solo percorso di validazione. Per `COPY_SCHEDULE`, dove un controller
  scrive sui target, si usa invece `RECEIVE_SCHEDULE` (§11b); `UPDATE_PROPERTY` resta l'alternativa. `C4:UpdateProperty` è già
  usato su hardware reale per `Operational Mode` e `Driver Version`.
- **Attenzione (documentata):** `OnPropertyChanged` **non** viene chiamato quando la
  proprietà è cambiata da `UpdateProperty`; per questo il controller ricostruisce
  esplicitamente (una volta per richiesta) e pubblica lo `STATE`. Al contrario, una
  modifica da Composer chiama `OnPropertyChanged` ⇒ ricostruzione ⇒ push alla UI.
- `COPY_SCHEDULE` usa lo stesso meccanismo (invio ai target, che
  scrivono le proprie proprietà); la persistenza `schedule` resta uno snapshot di sola
  lettura per la UI, non una seconda fonte.

Verificato su hardware: una scrittura dalla webview (`SET_SWITCHPOINT` → `UpdateProperty`)
si riflette nella proprietà `SP 1 Brightness` del controller in Composer, e la curva si
ricostruisce.

### 3d. Rendering della curva e UI definitiva

La UI **non reimplementa la curva**. Il controller esporta `curve:samples(step_min)`
(`libs/curve.lua`): per default 144 campioni `{t, brightness, cct}` a passo 10 min,
ciascuno **identico** a `curve:evaluate(t)` (testato in `tests/test_curve.lua`; la CCT
è poi riportata nei CT Limits, come il target reale). Il campionamento viaggia nello
`STATE` (`curve.samples`, ≈ 3 KB) e la pagina li collega con un path SVG: motore e
UI non possono divergere. I marker degli SP usano `t`/`brightness` risolti dal
controller; le linee astronomiche usano `astro`. L'unico calcolo lato pagina è una
lettura *lineare* fra campioni per le etichette (ora, Kelvin): non rigenera mai la curva.

**Struttura della pagina** (`drivers/webview/www/dist/`, vanilla, script classici, zero CDN):
`css/` (`nocturne-tokens`, `layout`, `components`, `circadian`), `js/` (`i18n`, `icons`, `util`,
`widgets`, `glow-layer`, `bridge`, `curve-renderer`, `context-sheet`, `main`), `fonts/` (woff2
latin di Plus Jakarta Sans, Inter, JetBrains Mono; licenza OFL in `THIRD_PARTY_LICENSES.md`).
`bridge.js` è l'unico punto che parla col driver (regole verificate in §3b).

**Decisioni**
- **Token.** Accenti (`#adc6ff`, `#ffb95f`, `#4edea3`, errore), tipografia, raggi e spaziature dal
  front-matter di [DESIGN.md](DESIGN.md) (normativo); superfici/hairline/testo dai tier di superficie della prosa di DESIGN.md
  (`#0A0D14`, `#141A29`, `#1E283D`, `#273550`, `#2A3750`). Dot di connessione: `#10B981` live,
  `#EF4444` errore, `#FBBF24` in attesa — **solo** la connessione (mai preview o pausa).
- **Stati della pagina.** `loading` (skeleton, finché non arriva il primo messaggio), `empty` (card
  centrale con Refresh, solo dopo una `DC_LIST` che risponde senza controller), `app`. «Connessione
  persa» dopo 30 s senza messaggi: heartbeat `DC_PING` ogni 10 s e `DC_LIST` ogni 30 s (resync);
  i push portano il resto.
- **Drag di un marker.** Si muove il marker e compare un tooltip; `SET_SWITCHPOINT` parte **solo al
  rilascio** (a ogni movimento le luci reali si riallineerebbero). Orizzontale a passi di 5 min:
  SP *Set Time* → `time`; SP *Astronomical* → `offset` rispetto al riferimento (clamp ±180 min,
  il tipo non cambia); verticale → `brightness` (disattivato in *Colour Temperature Only*). Un tocco
  senza spostamento apre la ContextSheet. Solo i campi cambiati vengono inviati.
- **ContextSheet.** Lavora su una bozza e invia solo i campi modificati; *Elimina* usa
  `DELETE_SWITCHPOINT` con conferma al secondo tocco e solo se gli SP sono più di 3. Card flottante
  460 px (top 68 / right 12 / bottom 12) da 900 px, 960 px da 1920 px, bottom sheet sotto 900 px;
  superficie solida sotto 1920 px, `overscroll-behavior: contain`, `touch-action: none` sugli slider.
- **Preview.** Badge «ANTEPRIMA» in TopBar, banner nell'intestazione della curva
  («SIMULAZIONE IN CORSO · 720x» + «ora · luminosità · K»), callout sul marker (ora e luminosità),
  configurazione bloccata con overlay, Pausa/Riprendi attenuati. Il tempo simulato compare una volta
  nel banner e una nel callout, non una terza.
- **Glow.** Alone dietro la curva tinto dalla CCT corrente. Congelato durante drag di marker/slider
  e con la sheet aperta; un solo ricalcolo al rilascio; raggio e colore quantizzati a passi da 10
  unità. Verificato offline: 0 ricalcoli durante un drag.
- **Compatibilità.** Pensata per il browser dei T4 (Firefox 96): solo funzioni disponibili da FF 85
  (`ResizeObserver`, `PointerEvent`, `inset`, `:focus-visible`, `overscroll-behavior`), nessun
  `backdrop-filter` sotto 1920 px. CSS e JS portano `?v=<versione del driver>` (lo stampa
  `tools/build.ps1`): un aggiornamento non può lasciare file vecchi nella cache del pannello.
- **Limiti noti.** L'orologio dell'«ora» è quello del dispositivo che mostra la pagina (un telefono
  in un altro fuso mostra un'ora diversa dal controller); la lingua arriva dalla proprietà
  `Language` del driver webview.

### 3e. Diagnosi sul campo: un'azione senza risposta

Un'azione dell'utente (`DC_CMD`) ha **due conferme**, e la pagina avvisa solo se manca una delle due
entro 8 s: (1) la risposta dell'hub `{ok, queued, id, rid}` (il driver ha preso la richiesta) e
(2) l'ACK del controller `{type:"ACK", id}` (l'ha eseguita). Il percorso passa per **quattro salti**:

```
pagina ──(1)──► driver webview ──(2)──► controller ──(3)──► driver webview ──(4)──► pagina
        sendCommand      SendToDevice          SendToProxy          SendDataToUI
```

**Misure e garanzie.**
- `tests/test_ui_matrix.lua` fa passare **ogni** op che la pagina può inviare (estratte dal codice dei
  JS: se ne compare una nuova senza copertura il test fallisce) per il vero adattatore, hub e motore,
  su 4 percorsi di consegna (UIRequest da solo, ExecuteCommand da solo, i due ordini del doppione) e 2
  trasporti (sincrono: l'ACK precede la risposta dell'hub; differito: come fra due driver reali).
  Risultato: ogni op ha **una** risposta con `rid`, **un** ACK e **una** esecuzione; un ACK negativo
  (es. Riprendi mentre è attivo) è comunque una risposta.
- `tests/js/test_bridge.js` (Node, solo sviluppo) copre la pagina: iscrizione prima del primo invio,
  ACK **anticipato** rispetto alla risposta dell'hub (bufferizzato e collegato, non perso), scadenza a
  8 s con la fase mancante nel log, retry all'avvio, nessun avviso per i poll.
- Corretto: un ACK che arrivava in pagina **prima** della risposta dell'hub veniva scartato e
  l'azione scadeva pur essendo riuscita; all'avvio, se nessuno risponde entro 2 s, la pagina rimanda
  `DC_PING`/`DC_LIST` (su un T4 lento l'iscrizione ai DATA_TO_UI può non essere ancora attiva).

**Politica degli avvisi.** Toast solo per azioni dell'utente (Applica, Elimina, pulsanti, drag,
slider), **mai** per i poll (`DC_PING`, `DC_LIST`, `DC_GET_STATE`); scadenza 8 s; al più un toast
ogni 30 s per la stessa op. Dopo una scadenza la pagina chiede `DC_GET_STATE` per mostrare lo stato
vero. Gli errori dell'hub senza azione associata vanno solo nel log.

**Strumentazione** (non cambia il protocollo). Livello di log 3-Info per le azioni; i poll sono TRACE.

| Dove | Riga |
|---|---|
| pagina (`?debug=1`, o console) | `TX rid=… op=…` · `RX rid=… op=… ms=…` (risposta dell'hub) · `RX ack id=… rid=… op=… ms=…` · `ACK anticipato collegato` · `TIMEOUT rid=… op=… ms=… stage=…` · `avviso soppresso (dedupe 30 s)` · `avvio: nessuna risposta, riprovo` |
| driver webview | `[HUB] richiesta ricevuta rid=… op=… via=UIRequest\|ExecuteCommand` · `[HUB] doppione scartato …` · `[HUB] risposta inviata rid=… op=… ms=…` · `[HUB] -> controller <id> id=wN rid=… op=…` · `[HUB] <- controller ACK id=wN rid=… op=… ok=… ms=…` · `[HUB] ACK -> pagina id=wN rid=… op=… ms=…` |
| controller | `[COMMS] <- webview <op> id=wN` · `[COMMS] -> webview ACK id=wN op=… ok=…` |

`ms` usa `C4:GetTime()` (ms dall'epoch, documentata dal 3.2.3); `rid` lega pagina e driver, `id=wN`
lega driver e controller.

**Come leggerle** (il salto in cui muore la risposta):

| Pagina | Driver webview | Controller | Salto perso |
|---|---|---|---|
| `TX` senza `RX`, `stage=hub-reply-missing` | niente `richiesta ricevuta rid=…` | — | **1** pagina → driver (Navigator non ha invocato UIRequest/ExecuteCommand) |
| `TX` senza `RX`, `stage=hub-reply-missing` | `richiesta ricevuta` e `risposta inviata` presenti | — | **4** driver → pagina (la risposta dell'hub) |
| `RX` ok, `stage=ack-missing` | `-> controller … id=wN` ma niente `<- controller ACK id=wN` | niente `<- webview … id=wN` | **2** driver → controller |
| idem | idem | `<- webview … id=wN` e `-> webview ACK id=wN` presenti | **3** controller → driver |
| idem | `<- controller ACK id=wN` e `ACK -> pagina id=wN` presenti | idem | **4** driver → pagina (l'ACK) |
| idem | idem | `<- webview` presente ma **non** `-> webview ACK` | il controller non ha risposto (escluso dalla matrice di test) |

## 4. I due driver

### 4.1 `daylight_circadian_controller` — motore multi-istanza

Responsabile di tutta la logica; il webview è solo una vista.

- Una istanza = una schedule + un gruppo di luci (`Controlled Devices`,
  `DEVICE_SELECTOR` multiselect con whitelist `light.c4i` / `light_v2.c4i`).
- Proprietà: `Driver Version`, `Operational Mode` (read-only),
  `Controlled Devices`, `Smart Light Level Monitoring`,
  `Follow Lights when Schedule Resumed`, `Fade Time (s) to Re-align with Schedule`,
  `Debounce Time (s) on level changed`, `Preset Colour While Lights Are Off`, `Scheduler Mode`, `Update Interval (s)`,
  `Number of Switchpoints`, `Minimum/Maximum Colour Temperature`,
  blocchi `SP 1..10`, `Log Mode` / `Log Level`.
  I nomi seguono il manifest pubblico di un prodotto analogo (vedi [EDGE_CASES.md](EDGE_CASES.md));
  `Update Interval (s)` e `Preset Colour While Lights Are Off` sono nostre.
- Actions: Pause, Resume, Follow All Lights, Preview, Display Stored Schedule,
  Show Astronomical Data, Recalculate Astronomical Data, Copy Schedule
  (`DEVICE_SELECTOR` limitato ai controller nostri).
- Events (`<name>` in `UPPER_SNAKE_CASE`, `<description>` come label):
  `SCHEDULE_PAUSED`, `SCHEDULE_RESUMED`, `PREVIEW_STARTED`, `PREVIEW_STOPPED`.
- Conditionals + variabili: `SCHEDULE_ACTIVE`, `PREVIEW_ACTIVE`.
- Commands per programming: Pause, Resume, Follow All, Start Preview, Stop Preview.
- Script: `<script file="driver.lua" encryption="0" jit="1" />` (vedi §6).

### 4.2 `daylight_circadian_webview` — UI singleton

Driver sottile: ospita la WebView, enumera i controller via binding, non
contiene logica circadiana.

- Funzioni: elenco controller; grafico curva brightness; gradiente CCT
  (press&hold → curva CCT); marker Sunrise/Solar Noon/Sunset con orari; griglia
  2h; dialog Add/Edit Switchpoint; Set CT Limits; toggle Schedule Enabled /
  Include Brightness; Start/Stop Preview; i18n IT + EN.
- Actions: `Rebuild WebView`, `Clear Touchscreen Cache` (`DEVICE_SELECTOR` di
  pannelli: glassedge 7/10, T4 inwall/tabletop 8/10).
- Proprietà: `Driver Version`, `Operational Mode`, `Language` (read-only),
  `Log Mode` / `Log Level`.

## 5. Pattern WebView

Dichiarato nel `driver.xml` del webview:

```xml
<proxies qty="1">
  <proxy name="Daylight Circadian Webview" image_source="c4z"
         small_image="icons/icon_16.gif" large_image="icons/icon_32.gif">uibutton</proxy>
</proxies>

<config>
  <SINGLETON_ID>daylight_circadian_webview</SINGLETON_ID>
  ...
</config>

<capabilities>
  <web_view_url proxybindingid="5001">controller://driver/daylight_circadian_webview/dist/index.html</web_view_url>
  <mobile_web_view_enabled>true</mobile_web_view_enabled>
  <navigator_display_option proxybindingid="5001">
    <display_icons>
      <Icon width="300" height="300">controller://driver/daylight_circadian_webview/icons/icon_300.png</Icon>
      <Icon width="70"  height="70">controller://driver/daylight_circadian_webview/icons/icon_70.png</Icon>
      <Icon width="90"  height="90">controller://driver/daylight_circadian_webview/icons/icon_90.png</Icon>
    </display_icons>
  </navigator_display_option>
</capabilities>

<connections>
  <connection>
    <id>5001</id><type>2</type><facing>6</facing>
    <connectionname>UIBUTTON</connectionname>
    <consumer>False</consumer>
    <classes><class><classname>UIBUTTON</classname></class></classes>
  </connection>
</connections>
```

- Il frontend vive **dentro il `.c4z`** (`www/dist/`), servito dal controller
  via `controller://driver/<driver_name>/...`; `<driver_name>` in
  `<capabilities>` deve coincidere col nome file del `.c4z`.
- `mobile_web_view_enabled=true` abilita la WebView nell'app iOS/Android.
- Il proxy è dichiarato con `proxybindingid="5001"` (come nell'esempio della
  documentazione UI Button). `URL_CHANGED` (via `SendToProxy(5001, …)`) cambia
  l'URL a runtime, ma Navigator non cambia l'URL di una webview **già aperta**:
  le azioni `Rebuild WebView` e `Clear Touchscreen Cache` pubblicano un URL con
  query nuova (`?r=<versione>-<n>`) per forzare il ricaricamento. Non esiste un'API documentata
  per svuotare la cache di uno specifico pannello; questo è il meccanismo adottato. Poiché
  Navigator non ricarica da solo una webview aperta, il proxy manda l'URL anche come
  DATA_TO_UI e la pagina (iscritta con `subscribeToDataToUi(false)`) cerca `index.html?r=…`
  e si ricarica cambiando solo la query. Verificato su hardware per *Rebuild WebView*
  (app); `Clear Touchscreen Cache` usa lo stesso meccanismo ma non è stato provato a parte.
- Accesso da browser per debug (non verificato): `http://<ip_controller>/c4z/<driver>/www/dist/`;
  senza `C4` la pagina lo segnala.
- Le icone (300/70/90 px per il Navigator, 16/32 px per Composer) stanno in
  `www/icons/` (non accanto a `www/`): verificato su hardware con Composer Pro.
- Layout responsive/portrait obbligatorio (edge case Janus v104).

## 6. Singleton e Lua non cifrato

- **`<SINGLETON_ID>daylight_circadian_webview</SINGLETON_ID>` solo sul webview.**
  Composer avvisa se si prova ad aggiungere una seconda istanza (edge case
  Janus v111). Il controller **non** ha `SINGLETON_ID`: deve poter esistere in
  N istanze.
- **Lua non cifrato**: nel tag `<script>` sempre `encryption="0"` esplicito.
  I driver commerciali usano `encryption="2"`; noi no: progetto open source.
- `jit="1"` (LuaJIT) per i tick frequenti: verificato su OS 3.4.3; non verificato su 3.3.x.

## 7. State machine del controller (`libs/state_machine.lua`)

Stati: `IDLE`, `ACTIVE`, `PAUSED`, `PREVIEW`. Esposti in `Operational Mode`
(`Idle` / `Active` / `Paused` / `Preview: HH:MM`) e nelle variabili e
conditionals `SCHEDULE_ACTIVE` (vero se non `PAUSED` e non `IDLE`, quindi anche
in `PREVIEW`) e `PREVIEW_ACTIVE`. Evita il crash noto di Pause durante
Preview ([EDGE_CASES.md](EDGE_CASES.md), v207) con guardie esplicite.

```
   IDLE ──START──► ACTIVE ◄──RESUME── PAUSED
                    │  │                ▲
                    │  └────PAUSE───────┘
                    └─PREVIEW_START──► PREVIEW ──PREVIEW_STOP / fine ~120 s──► ACTIVE
```

| Transizione | Note |
|---|---|
| `IDLE → ACTIVE` | `START` all'avvio, se la schedule è valida **e** lat/long del progetto sono disponibili; altrimenti log Error e resta `IDLE` |
| `ACTIVE → PAUSED` | Pause. Evento `SCHEDULE_PAUSED`; il tick non invia più nulla |
| `PAUSED → ACTIVE` | Resume. Evento `SCHEDULE_RESUMED`. Legge `Follow Lights when Schedule Resumed` **al momento del resume** (Janus v204): `Yes` azzera gli override e riallinea |
| `ACTIVE → PREVIEW` | Preview. Evento `PREVIEW_STARTED` |
| `PREVIEW → ACTIVE` | Stop Preview o fine ciclo. Evento `PREVIEW_STOPPED`; le luci vengono riallineate alla schedule reale |
| `PREVIEW → PAUSED` | **vietata** (log Warning "stop the preview first") |
| `PAUSED → PREVIEW` | **vietata** (log Warning "resume the schedule first") |
| qualunque altra | rifiutata con Warning, stato e eventi invariati |

- **Restart:** `ACTIVE` e `PAUSED` si conservano; `PREVIEW` (volatile) e `IDLE`
  tornano `IDLE` e, se possibile, ripartono `ACTIVE`. Se a restart mancano
  schedule o lat/long, lo stato salvato è scartato (`IDLE`, log Error).
- **`IDLE`** = il controller è caricato ma non comanda le luci (schedule non
  valida, lat/long mancanti, o mai avviato).

## 8. Flusso dati

```
 lat/long progetto ─► libs/sun.lua (+ offset UTC da libs/clock.lua) ─► orari astronomici del giorno
                                       (Sunrise, Solar Noon, Sunset, Solar Midnight)
                                              │  ricalcolo a mezzanotte (+ action Recalculate)
                                              ▼
 SP 1..N (Set Time | Astronomical + offset) ─► libs/schedule.lua ─► punti {t, brightness, cct}
                                              │
                                              ▼
                  libs/curve.lua: interpolazione monotone cubic, giornata ciclica
                  (CCT riportata nei CT Limits)
                                              │  tick ogni Update Interval (10..600 s, def 60)
                                              ▼
         target (brightness, CCT) ─► libs/monitor.lua: piano per luce (delta, override, ON/OFF)
                                              │
                                              ▼
              libs/light_cmd.lua: SET_BRIGHTNESS_TARGET + SET_COLOR_TARGET, rate = Fade Time
                                              │  batch staggered (§11)
                                              ▼
                                    C4:SendToDevice(id_luce, ...)
```

1. **Lat/long**: `C4:GetProjectProperty("Latitude")` e `("Longitude")` (OS ≥ 3.0).
   Se mancanti o entrambi 0 → log Error, il controller resta `IDLE`.
2. **Offset UTC**: `libs/clock.lua` (§14) per la data locale, DST incluso.
3. **Calcolo solare giornaliero**: all'avvio, dal timer di mezzanotte (+5 s) e
   on demand (azione `RECALCULATE_ASTRONOMICAL_DATA`); rete di sicurezza nel tick
   se la data cambia. Persistito come `astro_today`.
4. **Curva**: `schedule.read_config` legge le proprietà (valori fuori range
   limitati con Warning; `.`/`,` accettati come separatore) e `schedule.resolve`
   risolve gli SP astronomici (offset ±180 min, riportati nel giorno) e li
   **arrotonda al minuto**; SP non risolvibili (es. alba in giorno polare) sono
   saltati con Warning. A ogni ricostruzione (init, mezzanotte, modifica di
   un SP o di `Number of Switchpoints`) il controller logga a Info la schedule
   risolta: `[SCHEDULE] SP1 00:30 (Solar Midnight+0) b=10 cct=2600 | SP2 …`.
   **Collisioni**: due SP allo stesso minuto producono un Warning (`SP n e SP m
   coincidono a HH:MM: l'ultimo vince`, ripetuto in `DISPLAY_SCHEDULE`) e nella
   curva vince quello con numero più alto. I default del `driver.xml` (4 SP
   astronomici: Solar Midnight 10 %/2600 K, Sunrise 70/4000, Solar Noon 100/5500,
   Sunset 40/3000; SP 5–10 a orari fissi distinti) non collidono, verificato da
   `tests/test_driver_xml.lua` su 8 località/date.
5. **Invio** (`monitor.plan`): brightness solo se `|target − livello| ≥ 1 %` (non se è uguale all'ultimo inviato e il livello
   riportato ne dista al più 1 %: quantizzazione della lampada);
   CCT solo se `|target − ultima inviata| ≥ 25 K`, arrotondata a 10 K
   (Janus v201). Mai brightness a luce spenta/sconosciuta (v117); target brightness
   0 con luce accesa la **spegne** (0 %), non accende mai. **Colore a luce spenta:** di
   default non si invia (v200); con `Preset Colour While Lights Are Off = On` si invia la
   sola CCT (rate 0) alle luci note come spente: il proxy Light V2 permette `SET_COLOR_TARGET`
   a luce spenta e il driver della luce deve **memorizzarlo senza accenderla** e applicarlo alla
   prossima accensione dal sistema (Proxy Protocol, *Setting Color while the Light is Off*).
   Opzione spenta di default perché dipende dal driver della singola luce: provarla su una luce.
6. **Comandi Light V2** (verificati nel
   [Proxy Protocol](https://control4.github.io/docs-driverworks-proxyprotocol/)):
   - `SET_BRIGHTNESS_TARGET { LIGHT_BRIGHTNESS_TARGET_PERCENT, RATE (ms) }`;
   - `SET_COLOR_TARGET` per la **CCT**: `{ LIGHT_COLOR_TARGET_MODE = 1,
     LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = <kelvin>, RATE (ms) }`,
     **senza X/Y**. La tabella ufficiale del comando elenca solo `X`, `Y`,
     `MODE` (0 colore pieno, 1 CCT) e `RATE` — nessun parametro HSV o kelvin: è
     il lato *protocollo* (ciò che il proxy inoltra al driver della lampada). Il
     formato che il proxy accetta da un client per la CCT (quello dell'app) non
     è nella tabella: lo documentano il client `pyControl4` (MODE 1 + chiave
     kelvin, senza X/Y; colore pieno = MODE 0 + X/Y) e due driver protocollo
     reali (finitelabs `tplink`/`esphome`) che leggono per prima proprio quella
     chiave. Il nostro primo payload (MODE 1 + X/Y, ricavati con
     `C4:ColorCCTtoXY`) veniva accettato dal proxy (evento 4002) ma la lampada
     non virava. La chiave della rate è `RATE` (come l'app; i driver leggono
     anche `LIGHT_COLOR_TARGET_RATE` / `..._COLOR_RATE`). La rate rispetta
     `color_rate_behavior` / `color_rate_min` / `color_rate_max` della lampada
     (behavior 0 ⇒ nessun `RATE`). Costruzione in `light_cmd.color_cct`
     (colore pieno: `light_cmd.color_xy`, non usato);
   - `SET_LEVEL` **non esiste** in Light V2 (è deprecato: `RAMP_TO_LEVEL`).
     Fallback per luci senza `supports_target` (letto dalla variabile 6661
     `DynamicCapabilities`): `RAMP_TO_LEVEL { LEVEL, TIME (ms) }`;
   - luci con `supports_color_correlated_temperature = False`: solo brightness;
     la CCT è limitata a `color_correlated_temperature_min/max` della luce.
   **Verificato su hardware** (Composer 3.4.3, lampada CCT): con questo payload il
   colore cambia a occhio durante la preview. La conferma è **visiva**, perché la
   tabella del protocollo non documenta la chiave kelvin: è un formato lato client
   (l'app), ricavato da `pyControl4` e dai driver protocollo di terze parti.
   - **Clamp ai limiti della lampada, non solo ai CT Limits del driver.** I limiti
     `color_correlated_temperature_min/max` si leggono dalla variabile 6661 e la CCT
     inviata è `clamp(CCT della curva, min lampada, max lampada)`: con CT Limits del
     driver 2200–6500 K e una lampada 2700–6500 K, una curva a 2600 K viene inviata
     come 2700 K (comportamento corretto, non un errore).
   - **Il clamp precede la soglia dei 25 K.** Il confronto con l'ultima CCT inviata
     usa il valore *già clampato* (`monitor.plan` riceve `cct_min/cct_max`): prima il
     confronto usava il valore pre-clamp (2602) contro l'ultimo inviato post-clamp
     (2700) e il colore veniva rimandato a ogni tick. Il canale brightness si
     comporta in modo simmetrico (confronta il valore finale col livello reale).
   - **Rate colore.** Alcuni driver non supportano la rampa colore
     (`color_rate_behavior = 0`, osservato sulla lampada di test: nel log `rate=-`):
     in quel caso il controller **omette `RATE`** dal comando. Con
     `color_rate_min/max` > 0 la rate è riportata in quell'intervallo. Non è un bug
     del controller.
   Log: i comandi sono loggati a `4 - Trace`: `[SEND] luce N SET_COLOR_TARGET mode=1
   {CCT=3024} rate=5000 (<chiavi esatte>)`. Per ogni luce aggiunta, a Info: dump
   completo delle capabilities (`[LIGHTS] … capabilities (tag)` e `(XML)`),
   identità del driver (`[LIGHTS] … driver:`) e, una volta, la tabella di
   `SET_COLOR_TARGET` (`[COLORDOC]`).
7. **Luci selezionate**: il `DEVICE_SELECTOR` dà già gli ID (stringa separata da
   virgole): non servono binding dinamici, si usa `C4:SendToDevice`.

## 9. Smart Light Level Monitoring (`libs/monitor.lua`)

Obiettivo: se l'utente cambia a mano il livello di una luce, il controller
smette di forzare la brightness (la CCT continua a seguire la curva).

- **Sorgente del livello**: variabili del proxy Light V2, ascoltate con
  `C4:RegisterVariableListener` e ricevute in `OnWatchedVariableChanged`: `1001` (Light
  Brightness Percent, 0..100) e `1000` (Light State). **Notificano solo i cambi**: il livello
  iniziale di ogni luce si legge alla registrazione con `C4:GetDeviceVariable` (log
  `[LIGHTS] luce N livello iniziale X`); senza, una luce spenta all'avvio resterebbe sconosciuta e
  la sua prima accensione non sarebbe riconosciuta come tale. Gli **eventi** del proxy (4000–4003,
  5100/5101) non portano il valore: sono registrati con `C4:RegisterDeviceEvent` solo come
  **sonda** (`OnDeviceEvent`, `[PROBE]`); nei 15 s dopo un'accensione il log riporta i millisecondi
  trascorsi. Verificato su hardware (OS 3.4.3, luci CCT): le variabili 1000 e 1001 arrivano
  sempre; 4002 (*Light Color Changing*) e 5100/5101 (*Light On/Off*) arrivano, 4001 e 4003 no, e
  nessun evento è una conferma affidabile di un cambio colore. **Le variabili sono la fonte di
  verità.**
- **Feedback della CCT: non esiste.** Le variabili documentate del proxy Light
  V2 sono 1000–1010 (stato, brightness, rate, preset, limiti, cold start), 1300 e
  1301 (preset colore, solo UI) e 6661 (capabilities): **nessuna riporta il
  colore/CCT correnti** (la 1002 è *Click Rate Up*). L'unico segnale lato colore
  sono gli eventi 4002/4003 (*Light Color Changing/Changed*), che non portano il
  valore. Di conseguenza la conferma di un cambio di CCT è **solo lato comando
  inviato**: il controller ricorda l'ultima CCT *inviata* per luce
  (`last_sent.cct`) e la soglia dei 25 K è calcolata su quella, non su un valore
  letto dalla luce.
- **Self-sent vs esterno**: ogni invio registra `{da, a, tempo, rate}`. Un cambio
  è *self* se arriva entro `rate + 2·debounce + 2 s` dall'invio e il livello sta
  fra `da` e `a` (± 2 %): durante una rampa arrivano anche i livelli intermedi,
  che col solo confronto con il target sembrerebbero cambi esterni.
- **Debounce** (0..30 s, default 1; `0` ammesso, v111): un cambio esterno marca
  la luce `overridden` solo dopo che il livello è rimasto stabile per il debounce.
- **Re-align automatico**: (a) OFF → ON esterno azzera il flag e riallinea
  subito (v109); (b) livello uguale al circadiano (± 2 %, v106) → nessun
  override, o flag azzerato. Il riallineamento invia brightness + CCT con il
  `Fade Time (s) to Re-align with Schedule` (1..10 s, default 5).
- **Colore all'accensione.** A ogni accensione dal sistema il proxy applica il preset *Default On
  Color* della luce, e il nostro comando corre contro di esso (eventi 4002, 5100, 4002 entro
  ~100 ms): la lampada può accendersi al suo colore e restarci fino al comando successivo. Con
  `Preset Colour While Lights Are Off = On` la CCT delle luci spente è tenuta aggiornata e la luce si
  accende già al colore giusto (verificato su hardware). Con `Off` il colore è rimandato 3 s e 8 s
  dopo l'accensione (`RECOLOUR_AFTER_ON_MS` in `libs/engine.lua`).
- Monitoring **Off** ⇒ si comanda sempre (v203). In `PAUSED`/`PREVIEW` i cambi
  esterni non marcano override.
- Mentre una luce è `overridden` riceve solo la CCT (`Follow All Lights` e
  `Follow Lights when Schedule Resumed = Yes` azzerano i flag). La CCT segue
  la sua soglia (25 K dall'ultima inviata) **indipendentemente** dalla
  brightness: con una schedule lenta ci possono volere alcuni minuti fra due
  invii (a ~5 K/min, circa 5 minuti), ed è il comportamento atteso; verificato in
  `tests/test_engine.lua` (override + delta CCT > 25 K ⇒ solo `SET_COLOR_TARGET`).
- **Log**: «modificata a mano» è a Info solo quando la luce *entra* in override;
  i ritocchi successivi (es. un dimmeraggio a passi) restano a Trace finché la
  luce non torna a seguire la schedule.
- Il flag è **per luce** e persistito (`overridden`).

## 10. Persistenza (`libs/persist.lua`)

Tutto lo stato passa da `C4:PersistSetValue` / `C4:PersistGetValue`, non solo
`PersistData`: da OS 3.2 le variabili vengono re-inizializzate (v205) e
dopo un restart Director lo stato deve tornare completo.

| Chiave | Contenuto |
|---|---|
| `state` | `IDLE` / `ACTIVE` / `PAUSED` / `PREVIEW` (quest'ultimo viene scartato al restart) |
| `overridden` | `{ [device_id] = true }` per le luci in override |
| `astro_today` | `{ date, offset, lat, lon, sunrise, solar_noon, sunset, solar_midnight, polar }` |
| `schedule` | snapshot della configurazione (per la webview): **non** viene riletto al restart |

Le **proprietà** del driver restano la fonte di verità della schedule (le
persiste già Director): ripristinare una copia potrebbe resuscitare valori
vecchi. `persist.set` ripulisce le tabelle dai tipi non persistibili.
L'init tollera chiavi mancanti o corrotte e non dipende da nulla di remoto
(Janus v115).

## 11. Staggered fixture control

Con più di 10 luci i comandi del tick partono a **batch da 5 con 50 ms** fra un
batch e il successivo (Janus v115), con `C4:SetTimer`: in DriverWorks non esiste
`sleep`. Fino a 10 luci partono tutte insieme.

## 11b. Struttura del codice del controller

`driver.lua` è un adattatore: costruisce la tabella `env` (funzioni C4 iniettate
nell'engine) e inoltra le callback di Director. Tutta la logica sta in
`libs/engine.lua`, testabile offline con `tests/support/fake_env.lua`
(`tests/test_engine.lua`): lo schema di `env` è documentato in testa a `engine.lua`.

| Modulo | Ruolo |
|---|---|
| `libs/engine.lua` | orchestrazione: avvio/restart, tick, mezzanotte, luci, comandi, preview |
| `libs/state_machine.lua` | stati e transizioni |
| `libs/schedule.lua` | proprietà → switchpoint → target |
| `libs/monitor.lua` | override per luce, debounce, self-sent, piano di invio |
| `libs/light_cmd.lua` | comandi Light V2, parser capabilities, batch staggered |
| `libs/persist.lua` | wrapper di persistenza |
| `libs/sun.lua`, `curve.lua`, `clock.lua`, `debug.lua` | calcolo solare, curva, offset UTC, log |

### Preview

Timer da 1.2 s su 100 step (≈ 120 s): a ogni step `t = step/100 · 1440 min`,
brightness e CCT con rate di 1 s, `Operational Mode` = `Preview: HH:MM`. Le luci
in override ricevono solo la CCT. Al termine (o con `STOP_PREVIEW`) la schedule
reale viene riapplicata con il Fade Time.

### Azioni e comandi

`ExecuteCommand` riceve sia i comandi di programmazione sia le azioni di Composer
(`LUA_ACTION` con `ACTION`); il nome è normalizzato (`Pause Schedule` e
`PAUSE_SCHEDULE` sono equivalenti): `PAUSE_SCHEDULE`, `RESUME_SCHEDULE`,
`START_PREVIEW` / `PREVIEW_SCHEDULE`, `STOP_PREVIEW`, `FOLLOW_ALL_LIGHTS` /
`FOLLOW_LIGHTS`, `DISPLAY_SCHEDULE`, `SHOW_ASTRONOMICAL_DATA`,
`RECALCULATE_ASTRONOMICAL_DATA` / `RETRIEVE_ASTRONOMICAL_DATA`, `COPY_SCHEDULE`.

`COPY_SCHEDULE`: la schedule viene inviata con `C4:SendToDevice(id, "RECEIVE_SCHEDULE",
{...})` e il controller ricevente aggiorna le **proprie** proprietà con
`C4:UpdateProperty` (come per le richieste della webview). Un comando **non** dichiarato
in `<commands>` arriva a `ExecuteCommand` del destinatario: verificato su hardware
con `DC_REQUEST`. Il flusso di `COPY_SCHEDULE` è coperto da test offline (`tests/test_engine.lua`);
non è stato provato su hardware fra due controller. (Alternativa documentata: `UPDATE_PROPERTY`, vedi §3c.)

## 12. Debug

Pattern comune a entrambi i driver, in `libs/debug.lua`: `Log Mode` (Off /
Print / Log / Print and Log) e `Log Level` (`0 - Alert` … `5 - Debug`, default
`3 - Info`; un messaggio di severità S è emesso se S ≤ Log Level). Vedi [CONTRIBUTING.md](../CONTRIBUTING.md).

## 13. Fuori scope v1

Cloud/autoupdate/licensing; luci RGB; dimmer legacy non CT; bridge KNX/Lutron;
UI Composer grafica custom.

## 14. Algorithm references

Moduli puri in `libs/` (Lua 5.1, nessun `C4`).

### `libs/sun.lua` — calcolo solare

- **Algoritmo:** NOAA Solar Calculator, basato su Jean Meeus,
  *Astronomical Algorithms* (2a ed.).
  - Dettagli: <https://gml.noaa.gov/grad/solcalc/calcdetails.html>
  - Formule: <https://gml.noaa.gov/grad/solcalc/solareqns.PDF>
- **Passi:** giorno giuliano → declinazione solare → equazione del tempo →
  angolo orario a zenith 90.833° (rifrazione 34' + raggio solare 16') →
  mezzogiorno / alba / tramonto, con 2–3 iterazioni per ricalcolare
  declinazione e equazione del tempo all'istante dell'evento.
  Mezzanotte solare = mezzogiorno − 720 min (+1440 se negativo).
- **API:** `sun.calculate(lat, lon, year, month, day [, utc_offset_hours])` →
  `{ sunrise, solar_noon, sunset, solar_midnight, polar }` in minuti da
  mezzanotte.
- **Convenzione sull'orario:**
  - `sun.calculate(lat, lon, anno, mese, giorno)`: *tempo solare medio del
    sito* (offset = lon/15), senza fuso né DST; mezzogiorno solare ≈ 12:00.
  - `sun.calculate(lat, lon, anno, mese, giorno, utc_offset_hours)`: **ora
    dell'orologio locale** (fuso + DST di quel giorno, ore anche frazionarie).
    È la modalità che il controller deve usare, perché gli orari devono
    coincidere con l'orologio del sistema Control4. Senza offset gli SP
    astronomici sarebbero sfasati (~30 min a Milano, ~90 min d'estate).
  - Un offset `0` significa UTC, non "nessun offset": per il tempo solare medio
    si omette l'argomento.
  - Se un evento supera la mezzanotte dell'orologio (es. tramonto delle 24:04 a
    Reykjavík in giugno con UTC+0) il valore è riportato nel giorno (00:04); la
    curva è ciclica e ordina i punti da sé.
- **Casi polari:** `sunrise`/`sunset` sono `nil` e `polar` vale `"day"` (sole di
  mezzanotte, da ~65.7°N al solstizio d'estate) o `"night"` (notte polare, da
  ~67.4°N al solstizio d'inverno); il chiamante deve gestirlo (gli SP astronomici non
  risolvibili sono saltati con un Warning, §8). Reykjavík (64.1°N) **non** è
  un caso polare: il sole tramonta alle 24:04.
- **Verifica:** `tests/test_sun.lua` contro l'API USNO Astronomical Applications
  (<https://aa.usno.navy.mil/data/api>), fixture in
  `tests/fixtures/sun_reference.lua`: Milano (lat 45.0, lon 9.0) agli
  equinozi/solstizi (anche con offset UTC+2), Sydney, New York, Reykjavík
  (UTC+0, tramonto dopo mezzanotte) e Auckland (UTC+13 con DST). Tolleranza 1 min (riferimenti arrotondati
  al minuto); richiesta di progetto ±2 min.

### `libs/clock.lua` — offset UTC del sistema

Il controller ricava l'offset da passare a `sun.calculate` dall'orologio
del sistema Control4: `os.date` usa il fuso del sistema, quindi **DST incluso**.

```lua
local clock = require "libs.clock"
local offset = clock.utc_offset_hours_for_date(year, month, day) -- offset a mezzogiorno locale di quel giorno
local day = sun.calculate(lat, lon, year, month, day, offset)
```

Internamente confronta data e ora **complete** dello stesso istante visto
dall'orologio locale e da quello UTC (`os.date("*t", t)` e `os.date("!*t", t)`).

**Perché non la formula con le sole ore** `(local_hour - utc_hour + 36) % 24 - 12`:
restituisce valori in [−12, +11], quindi per UTC+12 / +13 / +14 (Nuova
Zelanda, Fiji, Kiribati) dà −12 / −11 / −10 — l'Auckland in DST (UTC+13) di
`tests/fixtures/sun_reference.lua` verrebbe letta come −11, ed è
verificato in `tests/test_clock.lua` — e perde i mezzi fusi (India +5:30, Nepal
+5:45). Usa inoltre l'ora "adesso", non quella del giorno calcolato (diversa nei
giorni di cambio ora).

Il log `[ASTRO] … UTC+n` mostra l'offset usato: deve coincidere col fuso del progetto
(Italia: +1 d'inverno, +2 d'estate), non con UTC.

### `libs/curve.lua` — interpolazione monotone cubic

- **Metodo:** interpolazione cubica di Hermite monotona di Fritsch–Carlson
  (F. N. Fritsch, R. E. Carlson, *Monotone Piecewise Cubic Interpolation*,
  SIAM J. Numer. Anal. 17(2), 1980;
  <https://en.wikipedia.org/wiki/Monotone_cubic_interpolation>).
- **Giornata ciclica:** l'ultimo switchpoint si collega al primo del giorno dopo
  (+1440 min); le tangenti si calcolano su tre copie dei nodi, quindi un
  massimo/minimo locale vicino alla mezzanotte resta piatto e non c'è scatto.
- **API:** `curve.prepare(points)` (una volta, es. a ogni ricalcolo
  giornaliero) → `curve:evaluate(t)`; `curve.evaluate(points, t)` per chiamate
  singole. Switchpoint `{ t, brightness, cct }`, `t` in minuti da mezzanotte.
  Punti non ordinati → ordinati internamente; stesso `t` → vince l'ultimo.
  Output clampato a brightness 0..100 e CCT 1600..6500 (i CT Limits
  dell'istanza si applicano sopra, nel controller).
