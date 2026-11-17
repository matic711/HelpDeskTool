# Opomnik

Preprost opomnik za dnevna opravila za Windows. Ko pride čas za opravilo, se prikaže **veliko rdeče okno**
(privzeto spodaj desno), ki:

- je **vedno na vrhu** vseh oken in počasi utripa,
- se **ne zapre samo od sebe**. Klikniti moraš **OPRAVLJENO** ali ga **odložiti** (5 min / 15 min / 1 uro),
- **ne prekrije celega zaslona in ne vzame fokusa**: če tipkaš ali si na klicu, delaš normalno naprej,
- zazvoni s kratkim zvoncem (ne z dolgim alarmom), ki se ponovi vsaki 2 minuti, dokler ne potrdiš.

Če ti je okno v napoto, ga z miško povleci drugam. V glavnem oknu lahko izbereš, kje naj se pokaže
(spodaj desno / zgoraj desno / zgoraj na sredini / na sredini zaslona).

Namestitev ni potrebna, deluje na vsakem Windows 10/11 (uporablja vgrajeni PowerShell).

## Zagon

1. Prenesi ZIP in ga razpakiraj (desni klik → *Razširi vse*).
2. Mapo `Opomnik` kopiraj nekam na računalnik (npr. `Dokumenti\Opomnik`).
3. Dvoklikni **`Opomnik.bat`**.

Če Windows prikaže opozorilo »Windows je zaščitil vaš računalnik«, klikni *Več informacij* → *Vseeno zaženi*.

## Uporaba

- Izberi **dan** in **uro**, vpiši opravilo in pritisni **Enter** (ali *Dodaj*).
- Hitreje: v polje napiši kar `14:30 Pokliči stranko`, pa se ura nastavi sama.
- **Opravljeno**: označi izbrano opravilo kot opravljeno (ponoven klik ga vrne nazaj).
- **Izbriši**: izbriše izbrano opravilo (ali tipka Delete).
- **Preizkusi opomnik**: pokaže, kako izgleda opomnik.
- **Zaženi ob prijavi v Windows**: Opomnik se sam zažene, ko se prijaviš v Windows.

Križec (X) okna programa **ne ugasne**, ampak ga samo skrije. Opomnik teče naprej v ozadju,
ikona (rdeč krog s klicajem) je spodaj desno ob uri. Za izhod: desni klik na ikono → *Izhod*.

Če računalnik ob času opravila ni bil prižgan, se opomnik prikaže takoj, ko Opomnik spet zaženeš.
Če je na vrsti več opravil hkrati, se prikazujejo eno za drugim.

## Kje so podatki

`%APPDATA%\Opomnik\opomnik.json`. Opravljena opravila, starejša od 7 dni, se samodejno pobrišejo.
Morebitne napake se zapišejo v `%APPDATA%\Opomnik\napake.log`.
