# Nätverkshanteraren

Ett litet Windows-verktyg för att växla IPv4-inställningar på ett nätverkskort mellan fördefinierade profiler, t.ex. en statisk adress för att prata med en maskin och DHCP för vanligt nätverk.

- Användaren väljer profil i ett enkelt fönster.
- Vid utloggning och vid uppstart återställs kortet automatiskt till standardprofilen.
- Profilerna ligger i JSON-filer: en global som administratören äger och en per användare som användaren själv redigerar.

## Filer

| Fil | Vem ändrar den | Innehåll |
|---|---|---|
| `BytNatverk.ps1` | Administratör | Skriptet. Fönster, återställning och installation av den schemalagda aktiviteten. |
| `default_config.json` | Administratör | Nätverkskort, standardprofil, var profilfilerna ligger och loggning. |
| `profiles_global.json` | Administratör | Profiler som alla användare ser. |
| `profiles_user.json` | Användaren | Användarens egna profiler. Valfri, ligger normalt i `%APPDATA%\Natverkshanteraren\`. |

## Krav

- Windows 10/11 eller Windows Server 2016 och senare.
- Windows PowerShell 5.1 (finns i Windows).
- Administratörsbehörighet för att tillämpa en profil. Fönstret ber om det via UAC.

## Installation

Kör stegen i en PowerShell som administratör.

**1. Kopiera filerna till en mapp som bara administratörer kan ändra.**

```powershell
$dir = 'C:\Program Files\Natverkshanteraren'
New-Item -ItemType Directory -Path $dir -Force
Copy-Item .\BytNatverk.ps1, .\default_config.json, .\profiles_global.json -Destination $dir
```

`C:\Program Files` har rätt behörigheter från början. Lägg **inte** skriptet på skrivbordet, en USB-sticka eller en delad mapp, se [Säkerhet](#säkerhet).

**2. Skapa loggmappen och lås den.**

Loggen skrivs av SYSTEM vid utloggning, så vanliga användare ska bara kunna läsa i mappen. Kommandot använder SID:ar och fungerar därför även på svenskspråkig Windows.

```powershell
$log = 'C:\ProgramData\Natverkshanteraren'
New-Item -ItemType Directory -Path $log -Force
icacls $log /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
```

**3. Anpassa `default_config.json`.** Kontrollera framför allt `InterfaceName`. Namnet på kortet visas med:

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status
```

**4. Aktivera återställning vid utloggning.**

```powershell
& 'C:\Program Files\Natverkshanteraren\BytNatverk.ps1' -InstallLogoffTask
```

Installationen vägrar om vanliga användare kan ändra skriptet eller `default_config.json`.

**5. Skapa en genväg åt användarna**, t.ex. på det gemensamma skrivbordet, med målet:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Program Files\Natverkshanteraren\BytNatverk.ps1"
```

## Användning

Starta genvägen och godkänn UAC-dialogen. Fönstret visar:

- **Vald profil**: inställningarna i den profil som är vald i listan och vilken fil den kommer från.
- **Nuvarande inställning**: det som faktiskt är inställt på kortet just nu.

**Verkställ** tillämpar den valda profilen. **Återställ standard** tillämpar standardprofilen direkt. Efter ett byte läses kortet av igen, så "Nuvarande inställning" visar resultatet. Vid byte till DHCP kan det ta några sekunder innan adressen syns.

Om något går fel visas felet i en dialog och skrivs till loggen. Fönstret visar aldrig "klart" om bytet misslyckades.

### Lägga till egna profiler

Användaren skapar filen `%APPDATA%\Natverkshanteraren\profiles_user.json` (skriv in sökvägen i Utforskarens adressfält) med samma format som `profiles_global.json`:

```json
{
  "Profiles": [
    {
      "Name": "Min testuppställning",
      "Type": "Static",
      "IPAddress": "192.168.10.50",
      "PrefixLength": 24
    }
  ]
}
```

Ändringarna syns nästa gång fönstret öppnas. Felaktiga profiler hoppas över och visas i en varning, de övriga fungerar som vanligt.

## Konfiguration

### `default_config.json`

```json
{
  "InterfaceName": "Ethernet",
  "ProfilesConfigPaths": [
    "profiles_global.json",
    "%APPDATA%\\Natverkshanteraren\\profiles_user.json"
  ],
  "LogEnabled": true,
  "LogPath": "%ProgramData%\\Natverkshanteraren\\natverkshanteraren.log",
  "DefaultProfile": {
    "Name": "Standard (DHCP)",
    "Type": "DHCP"
  }
}
```

| Fält | Krävs | Beskrivning |
|---|---|---|
| `InterfaceName` | Ja | Nätverkskortets namn enligt `Get-NetAdapter`. |
| `DefaultProfile` | Ja | Profilen som gäller efter utloggning och uppstart. Visas alltid först i listan. Kan vara DHCP eller statisk. |
| `ProfilesConfigPaths` | Nej | Lista med profilfiler, läses i ordning. Standard: `["profiles_config.json"]` bredvid skriptet. |
| `LogEnabled` | Nej | `true` eller `false`, utan citattecken. Standard: `true`. |
| `LogPath` | Nej | Loggfilens sökväg. Standard: `%ProgramData%\Natverkshanteraren\natverkshanteraren.log`. |

**Sökvägar**

- Miljövariabler som `%ProgramData%` och `%APPDATA%` expanderas.
- En relativ sökväg räknas från skriptets mapp.
- `%APPDATA%`, `%LOCALAPPDATA%` och `%USERPROFILE%` avser alltid den inloggade användaren, även om en administratör skriver in sitt eget konto i UAC-dialogen.
- Använd en maskingemensam sökväg för `LogPath`, eftersom återställningen körs som SYSTEM.
- Ska alla användare dela en och samma användarfil, peka den till `%ProgramData%` i stället för `%APPDATA%` och ge gruppen Användare skrivrätt på just den filen.

**Flera profilfiler**

- Finns samma profilnamn i flera filer gäller det som står först i listan. En användarfil kan alltså inte ersätta en global profil.
- Filer som inte finns hoppas över tyst och noteras i loggen.
- En trasig fil påverkar bara sina egna profiler.

### Profilformat

| Fält | Gäller | Krävs | Beskrivning |
|---|---|---|---|
| `Name` | Alla | Ja | Texten i listan. Måste vara unik. |
| `Type` | Alla | Ja | `"DHCP"` eller `"Static"`. |
| `IPAddress` | Static | Ja | IPv4-adress, t.ex. `"192.168.1.34"`. |
| `PrefixLength` | Static | Ja | 1–32. `24` motsvarar nätmask 255.255.255.0. |
| `Gateway` | Static | Nej | Standardgateway. Utelämnas för isolerade maskinnätverk. |
| `DnsServers` | Static | Nej | Lista, t.ex. `["10.0.0.1", "10.0.0.2"]`. Utan den rensas DNS-servrarna. |

Vid byte rensas kortets alla IPv4-adresser, standardrutter och DNS-servrar innan den nya profilen tillämpas, så inget ligger kvar från föregående profil. IPv6 lämnas orört.

## Återställning vid utloggning

`-InstallLogoffTask` skapar den schemalagda aktiviteten **Natverkshanteraren - Aterstall natverk**. Den körs som SYSTEM och kör `BytNatverk.ps1 -Reset`:

- **vid utloggning**, utlöst av händelse 4 i loggen *Microsoft-Windows-User Profile Service/Operational*, och
- **vid uppstart**, för fall där ingen utloggning skedde, t.ex. strömavbrott.

Återställningen läser bara `default_config.json`, aldrig profilfilerna, och visar inga fönster. Resultatet skrivs till loggen.

**Kontrollera att det fungerar** efter installationen: logga ut och in igen och titta i loggen efter en rad med `Profilen 'Standard (DHCP)' tillämpades`. Aktivitetens senaste körning visas också med:

```powershell
Get-ScheduledTaskInfo -TaskName 'Natverkshanteraren - Aterstall natverk'
```

**Ta bort aktiviteten:**

```powershell
& 'C:\Program Files\Natverkshanteraren\BytNatverk.ps1' -UninstallLogoffTask
```

## Loggning

Loggen innehåller tidpunkt, nivå (INFO/WARN/ERROR), användarnamn och händelse, t.ex. vilka profiler som tillämpades, misslyckade byten och fel i profilfilerna.

Stäng av den med `"LogEnabled": false`. Undantag: om `default_config.json` inte går att läsa skrivs felet ändå till standardsökvägen, eftersom skriptet inte kan veta vad inställningen är utan att läsa filen och en misslyckad återställning annars inte skulle lämna något spår.

## Säkerhet

- **Skriptmappen måste vara skyddad.** Den schemalagda aktiviteten kör skriptet som SYSTEM. Kan en vanlig användare ändra skriptet kan hen köra valfri kod som SYSTEM. `-InstallLogoffTask` kontrollerar detta och vägrar installera.
- **Profilfilerna är bara data.** Allt i dem valideras (IP-adresser, prefixlängd, typ) innan det används och de körs aldrig som kod. De påverkar inte återställningen.
- **Loggmappen ska inte vara skrivbar för användare**, eftersom SYSTEM skriver där.
- `-ExecutionPolicy Bypass` används för att slippa signera skriptet. I miljöer som kräver signerade skript: signera `BytNatverk.ps1` och ta bort flaggan från genvägen och aktiviteten.

## Felsökning

| Problem | Åtgärd |
|---|---|
| "Hittar inget nätverkskort som heter …" | Felet listar de kort som finns. Rätta `InterfaceName`. |
| En profil syns inte i listan | Läs varningen när fönstret öppnas, eller loggen. Kontrollera stavning av `Type` och att IP-adressen är giltig. |
| Användarens egna profiler syns inte | Kontrollera att filen ligger i `%APPDATA%\Natverkshanteraren\` och heter exakt som i `ProfilesConfigPaths`. En rad om saknad fil finns i loggen. |
| Å, ä, ö visas fel i fönstret | Spara `BytNatverk.ps1` som *UTF-8 med BOM*. JSON-filerna kan vara UTF-8 med eller utan BOM. |
| Fönstret öppnas inte alls | Användaren tryckte Nej i UAC-dialogen eller saknar administratörskonto. Se loggen. |
| Nätverket återställs inte vid utloggning | Kontrollera `Get-ScheduledTaskInfo` och loggen. Kontrollera i Loggboken att händelse 4 skrivs under *Program- och tjänstloggar → Microsoft → Windows → User Profile Service → Operational*. |

## Utveckling och test

Skriptet kan läsas in med punkt utan att något fönster öppnas eller någon behörighet efterfrågas. Funktionerna kan då testas var för sig:

```powershell
. .\BytNatverk.ps1

Test-NetProfile ('{"Name":"x","Type":"Static","IPAddress":"10.0.0.5","PrefixLength":33}' | ConvertFrom-Json)
Get-AppConfig -ConfigDirectory .\testconfig

# Visar vad som skulle göras utan att ändra något:
Set-AdapterIPv4Config -InterfaceName 'Ethernet' -NetProfile (Get-AppConfig).Profiles[1] -WhatIf
```
