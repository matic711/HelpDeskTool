# Opomnik

Preprost opomnik za dnevna opravila za Windows 10/11. Je pravi program (`Opomnik.exe`) z lastno ikono.
V upravitelju opravil se prikaže kot **Opomnik**, najdeš ga v meniju Start in na namizju, sam se
zažene ob prijavi v Windows in teče v ozadju.

Ko pride čas za opravilo, se prikaže **veliko rdeče okno** (privzeto spodaj desno), ki:

- je **vedno na vrhu** vseh oken in počasi utripa,
- se **ne zapre samo od sebe**. Klikniti moraš **OPRAVLJENO** ali ga **odložiti** (5 min / 15 min / 1 uro),
- **ne prekrije celega zaslona in ne vzame fokusa**: če tipkaš ali si na klicu, delaš normalno naprej,
- zazvoni s kratkim zvoncem, ki se ponovi vsaki 2 minuti, dokler ne potrdiš.

Če ti je okno v napoto, ga z miško povleci drugam. V glavnem oknu lahko izbereš, kje naj se pokaže.

## Namestitev

1. Prenesi ZIP in ga razpakiraj (desni klik → *Razširi vse*).
2. V mapi `Opomnik` dvoklikni **`Namesti.bat`**.
   Če Windows prikaže opozorilo »Windows je zaščitil vaš računalnik«, klikni *Več informacij* → *Vseeno zaženi*.
3. Odpre se črno okno, ki v nekaj sekundah pripravi program (uporabi prevajalnik, ki je že v Windows,
   nič se ne prenaša z interneta). Ko napiše »Opomnik je nameščen«, ga lahko zapreš.

Program se namesti v `%LOCALAPPDATA%\Programs\Opomnik`, zato lahko preneseno mapo potem izbrišeš.

Če je na računalniku še tekla stara PowerShell različica, jo nova sama ugasne. Opravila ostanejo.

**Posodobitev:** prenesi novo različico in spet zaženi `Namesti.bat`. Stari Opomnik se sam ugasne
in zamenja, opravila ostanejo.

**Odstranitev:** zaženi `Odstrani.bat`.

## Uporaba

- Izberi **dan** in **uro**, vpiši opravilo in pritisni **Enter** (ali *Dodaj*).
- Hitreje: v polje napiši kar `14:30 Pokliči stranko`, pa se ura nastavi sama.
- **Opravljeno**: označi izbrano opravilo kot opravljeno (ponoven klik ga vrne nazaj).
- **Izbriši**: izbriše izbrano opravilo (ali tipka Delete).
- **Preizkusi opomnik**: pokaže, kako izgleda opomnik.

Križec (X) okna programa **ne ugasne**, ampak ga samo skrije. Opomnik teče naprej v ozadju,
ikona (rdeč krog s klicajem) je spodaj desno ob uri. Za izhod: desni klik na ikono → *Izhod*.

Če računalnik ob času opravila ni bil prižgan, se opomnik prikaže takoj, ko se Opomnik spet zažene.
Če je na vrsti več opravil hkrati, se prikazujejo eno za drugim.

## Kje so podatki

`%APPDATA%\Opomnik\opomnik.json`. Opravljena opravila, starejša od 7 dni, se samodejno pobrišejo.
Morebitne napake se zapišejo v `%APPDATA%\Opomnik\napake.log`.
