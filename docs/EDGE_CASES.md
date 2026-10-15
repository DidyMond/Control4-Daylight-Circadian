# Casi limite e guardie

Elenco numerato dei casi limite che il codice gestisce esplicitamente, con dove sono implementati
e testati. I riferimenti `vNNN` nel codice e nei documenti sono le **versioni del changelog
pubblico di un driver commerciale di circadian lighting per Control4** (v100–v208, 2020–2022), usato
come prior art: ne ricaviamo i problemi già incontrati, non il codice. Per questo progetto è stato
usato solo materiale pubblico (manifest `driver.xml`, manuale utente, changelog, screenshot); il Lua
di quel prodotto è cifrato e non è stato letto.

## Lifecycle e stati

| # | Guardia | Dove |
|---|---|---|
| 1 | **Pause durante la preview** (v207, crash nel prodotto di riferimento): preview e pause sono mutuamente esclusivi, transizioni vietate con motivo esplicito | `libs/state_machine.lua`, `tests/test_state_machine.lua` |
| 2 | **OS ≥ 3.2 re-inizializza le variabili** (v205): lo stato durevole passa da `PersistSetValue/GetValue`, non solo da `PersistData` | `libs/persist.lua` |
| 3 | **Nessuna dipendenza da cloud** all'avvio (v115): l'init tollera chiavi mancanti o corrotte | `libs/persist.lua`, `libs/engine.lua` |
| 4 | **Restart del processore** (v104): ripristino completo dello stato (`ACTIVE`/`PAUSED`, override, dati astronomici) | `libs/engine.lua` (`[STATE] stato ripristinato`) |
| 5 | **Singleton del webview** (v111): `<SINGLETON_ID>` nel manifest, Composer avvisa se si aggiunge una seconda istanza | `drivers/webview/driver.xml` |

## Controllo delle luci

| # | Guardia | Dove |
|---|---|---|
| 6 | **Luce spenta a basso brightness non si riaccende** (v117): mai brightness a una luce spenta o sconosciuta; un target 0 % con luce accesa la spegne ma non accende mai | `libs/monitor.lua` (`plan`) |
| 7 | **Colore a luce spenta** (v200): di default non si invia. Con la proprietà `Preset Colour While Lights Are Off = On` si invia la sola CCT alle luci note come spente: il proxy Light V2 la accetta e il driver della luce deve memorizzarla senza accenderla (Proxy Protocol, *Setting Color while the Light is Off*). Opzione spenta di default perché dipende dal driver di ogni luce | `libs/monitor.lua`, `libs/engine.lua` |
| 8 | **Dimmer con scala invertita** (v201): non applicabile, la CCT si invia in kelvin; i dimmer legacy non CT sono fuori scope | — |
| 9 | **CCT a multipli di 10 K** (v201): evita scatti | `libs/monitor.lua` (`round_cct`) |
| 10 | **Invio a batch** con molte luci (v115): oltre 10 luci, batch da 5 con 50 ms di ritardo | `libs/light_cmd.lua` (`stagger`) |

## Smart Light Level Monitoring

| # | Guardia | Dove |
|---|---|---|
| 11 | **Tolleranza sul re-align** (v106): livello della luce uguale al circadiano entro ±2 % ⇒ nessun override | `libs/monitor.lua` |
| 12 | **OFF → ON azzera l'override** (v109), con riallineamento forzato di brightness e CCT | `libs/monitor.lua`, `libs/engine.lua` (`turned_on`) |
| 13 | **Monitoring Off ⇒ si comanda sempre** (v203) | `libs/monitor.lua` (`plan`) |
| 14 | **`Follow Lights when Schedule Resumed` letta al momento del resume** (v204), non memorizzata | `libs/engine.lua` |
| 15 | **Debounce = 0 s ammesso** (v111): range `0..30` | `drivers/controller/driver.xml`, `libs/monitor.lua` |

Aggiunte dai test su hardware (non derivano dal prodotto di riferimento):
- **Livello iniziale delle luci** letto alla registrazione: le variabili notificano solo i cambi, senza
  lettura una luce spenta all'avvio resterebbe sconosciuta e la sua prima accensione non sarebbe un
  `turned_on` (`Engine:seed_level`).
- **Colore all'accensione**: la lampada può applicare il suo *Default On Color* dopo il nostro
  comando; con l'opzione del punto 7 su `Off`, il colore è rimandato 3 s e 8 s dopo l'accensione
  (`RECOLOUR_AFTER_ON_MS`).
- **Lampade che riportano 1 % in meno** del comandato: la brightness non è rimandata a ogni tick se
  il valore è uguale all'ultimo inviato e il livello riportato ne dista al più 1 % (`monitor.plan`).
- **CCT sotto il minimo della lampada**: il clamp ai limiti dichiarati dalla lampada precede la
  soglia dei 25 K, altrimenti il colore verrebbe rimandato a ogni tick.

## UI / WebView

| # | Guardia | Dove |
|---|---|---|
| 16 | **Slider CT assente con Scheduler Mode = Colour Temperature Only** (v116): la configurazione mostra solo ciò che la modalità usa, la parte non usata si attenua | `drivers/webview/www/dist/js/main.js` |
| 17 | **Layout verticale** su tablet e app (v104): responsive mobile-first, bottom sheet sotto 900 px | `drivers/webview/www/dist/css/layout.css` |
| 18 | **Locale europeo** (v114): numeri letti e scritti sempre col punto nel JSON e accettati con `.` o `,` nelle proprietà | `libs/json.lua`, `libs/schedule.lua` (`parse_number`) |

## Astronomico

| # | Guardia | Dove |
|---|---|---|
| 19 | **Ora legale** (v110): gli orari astronomici usano l'offset UTC del sistema alla data calcolata, anche per fusi frazionari e UTC+13 | `libs/clock.lua`, `tests/test_clock.lua` |
| 20 | **Ricalcolo a mezzanotte**, non solo all'avvio; rete di sicurezza nel tick se la data cambia | `libs/engine.lua` |
| 21 | **Giorno e notte polari**: alba e tramonto assenti; gli SP astronomici non risolvibili sono saltati con un Warning | `libs/sun.lua`, `libs/schedule.lua` |

## Scelte di design che ne derivano

- Stato esplicito `IDLE / ACTIVE / PAUSED / PREVIEW` (1).
- Proprietà del driver come unica fonte di verità della schedule; la webview scrive passando dal
  controller ([ARCHITECTURE.md §3c](ARCHITECTURE.md)).
- Test offline per curva, calcoli solari e i casi 6, 7, 11, 12, 14, 15, 18, 19 (`./tools/run_tests.ps1`).
