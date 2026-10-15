# Esempio di schedule · Example schedule

Due profili di partenza per luci tunable white con range **2700–6500 K**: **Living** e **Camera**
(*Bedroom*), con 6 switchpoint tutti astronomici, quindi seguono le stagioni. Sono valori di
partenza basati sulla pratica comune dell'illuminazione circadiana (caldo e basso la sera, più
freddo e pieno a mezzogiorno), **non** validati su altri impianti. Gli orari qui sotto sono
calcolati con le librerie del progetto (`libs/sun.lua` e `libs/curve.lua`) per **Milano**
(45,46 N; 9,19 E); con la tua latitudine cambiano gli orari, non la forma.

*Two starting profiles for tunable-white lights with a **2700–6500 K** range: **Living** and
**Bedroom**, with 6 astronomical switchpoints, so they follow the seasons. They are starting values
based on common circadian-lighting practice (warm and dim in the evening, cooler and full at
midday), **not** validated on other installations. Times below are computed with the project's
libraries for **Milan**; at another latitude the times change, not the shape.*

## Impostazioni generali · General settings

| Proprietà · Property | Valore · Value |
|---|---|
| Scheduler Mode | Brightness + Colour Temperature |
| Number of Switchpoints | 6 |
| Minimum / Maximum Colour Temperature | 2700 / 6500 (usa il range reale delle tue lampade · use your lamps' real range) |
| Update Interval (s) | 60 |
| Smart Light Level Monitoring | On |
| Follow Lights when Schedule Resumed | Yes |
| Fade Time (s) to Re-align with Schedule | 5 |
| Debounce Time (s) on level changed | 1 (3–5 se le lampade sono lente a stabilizzarsi · if lamps are slow to settle) |
| Preset Colour While Lights Are Off | Off (vedi la nota sotto · see the note below) |

Con questi valori la variazione massima è circa 0,8 %/min di luminosità e 20 K/min, sotto le
soglie del controller (1 % e 25 K): un tick da 60 s va bene.

## Profilo Living

Tutti gli `SP n Type` sono `Astronomical` (il campo Time è ignorato).

| SP | Riferimento · Reference | Offset (min) | Brightness (%) | Colour Temp (K) | Ruolo · Role |
|---|---|---|---|---|---|
| 1 | Solar Midnight | 0 | 5 | 2700 | livello notturno · night level |
| 2 | Sunrise | −30 | 10 | 2700 | pre-alba, ancora calda · pre-dawn, still warm |
| 3 | Sunrise | +90 | 80 | 4500 | salita del mattino · morning rise |
| 4 | Solar Noon | 0 | 100 | 5500 | picco · peak |
| 5 | Sunset | −120 | 80 | 4200 | calo pomeridiano · afternoon decline |
| 6 | Sunset | +30 | 35 | 2700 | serata · evening |

Valori risultanti (luminosità / CCT) · Resulting values (brightness / CCT):

| Data · Date | 08:00 | 12:00 | 18:00 | 22:00 |
|---|---|---|---|---|
| 21/12 | 20% / 2923 K | 100% / 5482 K | 27% / 2700 K | 7% / 2700 K |
| 12/10 | 79% / 4447 K | 100% / 5499 K | 38% / 2724 K | 8% / 2700 K |
| 21/6 | 87% / 4874 K | 100% / 5489 K | 90% / 4671 K | 32% / 2700 K |

## Profilo Camera · Bedroom profile

Stessi riferimenti e offset del Living · Same references and offsets as Living.

| SP | Brightness (%) | Colour Temp (K) |
|---|---|---|
| 1 | 3 | 2700 |
| 2 | 8 | 2700 |
| 3 | 60 | 4000 |
| 4 | 80 | 4800 |
| 5 | 60 | 3800 |
| 6 | 25 | 2700 |

| Data · Date | 08:00 | 12:00 | 18:00 | 22:00 |
|---|---|---|---|---|
| 21/12 | 15% / 2859 K | 80% / 4784 K | 19% / 2700 K | 4% / 2700 K |
| 21/6 | 67% / 4300 K | 80% / 4791 K | 69% / 4154 K | 23% / 2700 K |

## Note · Notes

- **Livello notturno (SP 1).** Il controller non accende mai le luci da solo: SP 1 è il livello a
  cui sale una luce accesa di notte. Se a 5 % (3 % in Camera) una lampada sfarfalla o non parte,
  alzalo a 8–10 %.
  *The controller never turns lights on by itself: SP 1 is the level a light turned on at night
  comes up at. If a lamp flickers or does not start at 5 % (3 % in Bedroom), raise it to 8–10 %.*
- **Sera e notte a 2700 K.** Con il limite inferiore a 2700 K la CCT arriva al minimo poco dopo il
  tramonto e resta piatta fino all'alba: il calo serale si vede solo sulla luminosità.
  *With the lower limit at 2700 K the colour temperature reaches the minimum shortly after sunset
  and stays flat until dawn: the evening decline shows in brightness only.*
- **Più freddo a mezzogiorno.** Per un bianco più «diurno» alza SP 4 a 6000 K e SP 3 a 4800 K.
  *For a more "daylight" white at midday, raise SP 4 to 6000 K and SP 3 to 4800 K.*
- **Colore all'accensione e preset del driver della luce.** Molte lampade si accendono al loro
  colore predefinito (*Default On Color*) e solo dopo passano a quello della schedule. L'opzione
  `Preset Colour While Lights Are Off = On` invia la CCT anche alle luci spente: il proxy Light V2
  la memorizza e la applica all'accensione, senza accendere la luce, così la luce parte già al
  colore giusto. **Dipende dal driver di ogni luce**: alcuni driver di terze parti potrebbero
  accendere la luce quando ricevono un colore a luce spenta. Provala prima su **una** luce, di
  giorno, e controlla che resti spenta; poi accendila a mano.
  *Many lamps turn on at their own default colour and only then move to the schedule colour.
  `Preset Colour While Lights Are Off = On` sends the colour temperature to switched-off lights
  too: the Light V2 proxy stores it and applies it at turn-on without turning the light on, so the
  light comes up already at the right colour. **It depends on each light's driver**: some
  third-party drivers may turn the light on when they receive a colour while it is off. Try it on
  **one** light first, in daytime, and check that it stays off; then switch it on by hand.*
- **Luminosità all'accensione.** La luce parte dal livello di accensione configurato sulla lampada e
  raggiunge il target in *Fade Time* secondi; abbassare *Fade Time* rende la correzione più rapida.
  *Brightness at turn-on: the light starts from the lamp's configured on-level and reaches the target
  in Fade Time seconds; lowering Fade Time makes the correction faster.*
- **Come provarla.** Il primo giorno usa *Preview* (24 ore in circa 2 minuti) e guarda mattino,
  picco e serata. Nei giorni seguenti, con *Log Level* `3 - Info`, controlla che la riga
  `[SCHEDULE]` al riavvio coincida con la tabella; di solito si ritoccano SP 3, 5 e 6.
  *To try it: on day one use Preview (24 hours in about 2 minutes) and look at morning, peak and
  evening. In the following days, with Log Level `3 - Info`, check that the `[SCHEDULE]` line at
  restart matches the table; SP 3, 5 and 6 are usually the ones to tweak.*
