## Cosa cambia / What changes

<!-- Un obiettivo per PR. Collega la issue: `Closes #…`. / One goal per PR. Link the issue: `Closes #…`. -->

## Come l'hai provato / How you tested it

<!-- Webview e `driver.lua` non si testano offline: indica Control4 OS, Composer Pro, modello di luci e pannello/app. -->
<!-- Webview and `driver.lua` cannot be tested offline: state the Control4 OS, Composer Pro, lights model and panel/app. -->

- Control4 OS / Composer Pro:
- Luci / Lights:
- Pannello o app / Panel or app:

## Checklist

- [ ] `./tools/run_tests.ps1` è verde. / `./tools/run_tests.ps1` is green.
- [ ] `libs/` resta Lua 5.1 puro, senza riferimenti a `C4`. / `libs/` stays pure Lua 5.1 with no `C4` reference.
- [ ] Testi visibili all'utente in IT + EN. / User-visible text in IT + EN.
- [ ] Documentazione aggiornata (`docs/ARCHITECTURE.md` se cambiano binding, state machine o flusso dati) e `CHANGELOG.md` (`[Unreleased]`). / Documentation updated and `CHANGELOG.md` (`[Unreleased]`).
- [ ] Nessun `.c4z` committato. / No `.c4z` committed.
- [ ] Il contributo non contiene codice, CSS, font, icone o asset di altri prodotti (regole clean-room). / The contribution contains no code, CSS, fonts, icons or assets from other products (clean-room rules).
- [ ] Accetto che il mio lavoro sia rilasciato con licenza MIT. / I agree my work is released under the MIT licence.
