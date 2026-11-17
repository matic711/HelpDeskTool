# Opomnik

Preprost opomnik za dnevna opravila za Windows. Ko pride čas za opravilo, se **čez cel zaslon**
(na vseh monitorjih) prikaže velik rdeč opomnik z zvokom. Ne moreš ga zapreti z Alt+F4 ali Esc,
ampak moraš klikniti **OPRAVLJENO** ali pa ga **odložiti** (5 min / 15 min / 1 uro).

Namestitev ni potrebna, deluje na vsakem Windows 10/11 (uporablja vgrajeni PowerShell).

## Zagon

1. Kopiraj mapo `Opomnik` nekam na računalnik (npr. `Dokumenti\Opomnik`).
2. Dvoklikni **`Opomnik.bat`**.

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

## Kje so podatki

`%APPDATA%\Opomnik\opomnik.json`. Opravljena opravila, starejša od 7 dni, se samodejno pobrišejo.
Morebitne napake se zapišejo v `%APPDATA%\Opomnik\napake.log`.
