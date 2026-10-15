# Contribuire a Control4-Daylight-Circadian

Grazie dell'interesse. Il progetto è open source (MIT) e punta a sostituire il
Daylight agent nativo di Control4 con una suite di driver affidabile.

## Prima di iniziare

1. Leggi [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (architettura, protocollo, state machine),
   [docs/EDGE_CASES.md](docs/EDGE_CASES.md) e, per la webview, [docs/DESIGN.md](docs/DESIGN.md).
2. Apri una issue prima di una modifica grande o di una nuova feature, per concordarla.
3. Lingua: **italiano tecnico** per documenti e commenti; **inglese** per tutto ciò che Control4
   vede (proprietà, comandi, eventi, variabili, binding), codice e identificatori.

## Regole clean-room (obbligatorie)

Altri driver di circadian lighting sono prodotti commerciali.

- **Non** decifrare, aprire o analizzare Lua cifrato (`driver.lua.encrypted` o simili).
- **Non** copiare codice, CSS, font, icone o asset di altri prodotti, nemmeno "riscritti a
  somiglianza".
- Sono ammessi solo materiali pubblici: `driver.xml`, manuali, changelog, screenshot.

Una PR che contiene codice o asset derivati da quel materiale verrà rifiutata.

## Sviluppo

### Test e build
- Test: `./tools/run_tests.ps1` (lint di `libs/` + tutti i test; opzione `-Filter <testo>`,
  `-Quiet`). Richiede **LuaJIT** (Lua 5.1, come il runtime di DriverWorks): su Windows
  `winget install --id DEVCOM.LuaJIT -e`. Se c'è `node` lancia anche `tests/js`. Deve essere verde
  prima di ogni PR.
- Build: `./tools/build.ps1` (controller) e `./tools/build.ps1 -Driver webview`, con Windows
  PowerShell 5.1. Output in `releases/<driver_name>.c4z` (ignorato da git). Il `.c4z` è uno zip con
  `driver.xml`, `driver.lua`, `libs/`, `www/` **nella radice**, solo file, separatore `/`.
  Il `<version>` (`YYMMDDNNN`) si incrementa a ogni build installata: Composer non ricarica un
  driver con la stessa versione. `-NoBump` per costruire senza incrementarla.
- Icone: `python tools/generate_icons.py` (richiede Pillow), solo se si cambia il disegno.
- Installazione per test: copia il `.c4z` in `Documents\Control4\Drivers`, aggiungi in Composer
  Pro (OS target 3.4.3), *Refresh Navigators*.

### Lua
- `driver.lua` è solo entrypoint (handler C4, wiring). La logica sta in `libs/`, caricata con
  `require "libs.<modulo>"`.
- `libs/` è **Lua 5.1 puro** e **non tocca il namespace `C4`**: niente `//`, `goto`, operatori bit a
  bit, `table.unpack`, `bit32`, `utf8`; ciò che serve di C4 si passa per iniezione (`env`). Lo
  verifica il lint di `run_tests.ps1`. Unit test per ogni modulo in `tests/`, fixture in
  `tests/fixtures/`.
- Nomi `snake_case`; costanti `UPPER_SNAKE_CASE`; gli handler obbligati dal framework mantengono
  il loro nome (`OnDriverInit`, `OnPropertyChanged`, `ExecuteCommand`, `ReceivedFromProxy`…).
- Ogni callback invocata da Director passa da un wrapper `pcall` che logga l'errore.
- Niente `sleep`: solo timer DriverWorks. Lo stato durevole passa da `PersistSetValue/GetValue`.
- Lua **non cifrato**: nel `<script>` sempre `encryption="0"`.
- Numeri letti da stringa robusti a `.` e `,`.
- Prima di usare un comando o un parametro Control4 controlla il nome esatto nella
  [documentazione ufficiale](https://control4.github.io/docs-driverworks-api/); niente nomi a memoria.

### `driver.xml`
- Proprietà: inglese, Title Case (`Scheduler Mode`, `SP 1 Brightness`).
- Comandi, eventi, variabili, conditionals e binding: `UPPER_SNAKE_CASE`; il testo leggibile sta in
  `<description>`. Le **azioni** (`<action><name>`) sono Title Case, col `<command>` in
  `UPPER_SNAKE_CASE`.
- Controller: `<consumer>True`; webview: `<consumer>False`, `<SINGLETON_ID>` solo sul webview.

### Webview
- **Vanilla JS**, HTML e CSS semplici; script classici con namespace `window.DC`; nessun bundler,
  nessuna risorsa remota (CDN, font online). Verifica sintassi: `node --check` sui file JS.
- Tutte le stringhe visibili passano dal dizionario i18n **IT + EN** (`js/i18n.js`).
- Il grafico disegna i campioni calcolati dal controller: **mai** una seconda implementazione della
  curva.
- Il canale col driver passa solo da `js/bridge.js` (regole in ARCHITECTURE §3b).
- Colori, spaziature e raggi vengono da `docs/DESIGN.md`: se manca un valore si aggiunge lì con la
  sua origine, non si inventa nel CSS.

### Debug
Entrambi i driver hanno **Log Mode** (`Off` / `Print` / `Log` / `Print and Log`, default `Off`) e
**Log Level** (`0 - Alert` … `5 - Debug`, default `3 - Info`): un messaggio di severità *S* è emesso
se *S* ≤ livello. I messaggi hanno un tag tra parentesi (`[LIFECYCLE]`, `[TICK]`, `[MONITOR]`,
`[SEND]`, `[HUB]`, `[COMMS]`…). Gli errori non gestiti sono sempre visibili.

## Pull request

- Una PR = un obiettivo; descrizione chiara e collegamento alla issue.
- Indica cosa hai provato e su quale hardware (Control4 OS, Composer Pro, modello di luci). Webview e
  `driver.lua` non si testano offline.
- La CI (GitHub Actions) lancia `tools/run_tests.ps1` su ogni push e PR; deve essere verde.
- Aggiorna la documentazione toccata (in particolare `docs/ARCHITECTURE.md` se cambi binding, state
  machine o flusso dati) e il [CHANGELOG](CHANGELOG.md) (`[Unreleased]`).
- Testi visibili all'utente in IT + EN.
- Contribuendo accetti che il tuo lavoro sia rilasciato con licenza MIT.

## Git workflow

- Branch da `main`: `feat/<slug>`, `fix/<slug>`, `docs/<slug>`. **Conventional commits**: `feat:`,
  `fix:`, `docs:`, `test:`, `build:`, `refactor:`, `chore:` (scope opzionale, es.
  `feat(controller): …`).
- **Mai push diretto su `main`**: `main` riceve solo merge.
- **Release**: tag `v<build>`, dove `<build>` è il `<version>` (`YYMMDDNNN`) **identico** nei due
  `driver.xml`; si costruiscono entrambi i `.c4z` con `-NoBump` e si allegano alla Release. I `.c4z`
  non si committano mai.
