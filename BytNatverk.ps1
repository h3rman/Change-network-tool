#Requires -Version 5.1
<#
.SYNOPSIS
    Nätverkshanteraren: byter IPv4-inställningar på ett nätverkskort mellan fördefinierade profiler.

.DESCRIPTION
    Lägen:
      (inga parametrar)     Öppnar fönstret där användaren väljer profil. Startar om sig själv
                            som administratör vid behov.
      -Reset                Återställer kortet till standardprofilen, utan fönster. Körs av den
                            schemalagda aktiviteten vid utloggning och vid uppstart. Loggar till fil.
      -InstallLogoffTask    Skapar den schemalagda aktiviteten. Kräver administratörs-PowerShell.
      -UninstallLogoffTask  Tar bort den schemalagda aktiviteten.

    Konfiguration:
      default_config.json   Ligger bredvid skriptet. Endast administratörer ska kunna ändra den.
        InterfaceName       Nätverkskortets namn, t.ex. "Ethernet".
        DefaultProfile      Profilen som gäller efter utloggning och uppstart.
        ProfilesConfigPaths (Valfri) Lista med profilfiler, vanligtvis en global och en per användare.
                            Läses i listans ordning. Finns samma profilnamn i flera filer gäller
                            den första, så en användarfil kan inte skugga en global profil.
                            Filer som inte finns hoppas över tyst (noteras i loggen).
                            Standard: ["profiles_config.json"] bredvid skriptet.
        LogEnabled          (Valfri) true eller false. Standard: true.
        LogPath             (Valfri) Loggfilens sökväg. Använd en maskingemensam sökväg, eftersom
                            återställningen körs som SYSTEM.
                            Standard: %ProgramData%\Natverkshanteraren\natverkshanteraren.log

      Sökvägar: miljövariabler som %ProgramData% och %APPDATA% expanderas. En relativ sökväg
      räknas från skriptets mapp. Användarvariabler (%APPDATA%, %USERPROFILE% m.fl.) avser alltid
      den inloggade användaren, även när ett annat konto anges i UAC-dialogen.

      Profilfilerna     Behandlas enbart som data och valideras innan något används. Läses aldrig
                        vid -Reset, så en trasig eller manipulerad profilfil kan inte påverka
                        återställningen.
        Profiles        Lista med profiler.

    Profilformat:
      Name          Text som visas i listan. Måste vara unikt.
      Type          "DHCP" eller "Static".
      IPAddress     (Static) IPv4-adress, t.ex. "192.168.1.34".
      PrefixLength  (Static) 1-32. 24 motsvarar nätmask 255.255.255.0.
      Gateway       (Static, valfri) Standardgateway, IPv4-adress.
      DnsServers    (Static, valfri) Lista med IPv4-adresser till DNS-servrar.

    Loggning: styrs av LogEnabled och LogPath. Om default_config.json inte går att läsa skrivs
    felet ändå till standardsökvägen, eftersom det annars inte finns något spår av varför en
    återställning vid utloggning uteblev.

.EXAMPLE
    .\BytNatverk.ps1
    Öppnar fönstret.

.EXAMPLE
    .\BytNatverk.ps1 -InstallLogoffTask
    Körs en gång av en administratör för att aktivera återställning vid utloggning.
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Reset', Mandatory)]
    [switch]$Reset,

    [Parameter(ParameterSetName = 'Install', Mandatory)]
    [switch]$InstallLogoffTask,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch]$UninstallLogoffTask,

    # Intern: den inloggade användarens miljövariabler, skickade vid omstart som administratör.
    [Parameter(ParameterSetName = 'Gui', DontShow)]
    [string]$CallerEnvironment
)

# Alla fel stoppar körningen och fångas av en catch som loggar och visar dem.
# Där ett tomt resultat är normalt används -ErrorAction SilentlyContinue på just det anropet,
# med en kommentar om varför.
$ErrorActionPreference = 'Stop'

$script:AppName  = 'Natverkshanteraren'
$script:TaskName = 'Natverkshanteraren - Aterstall natverk'
$script:DefaultLogPath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "$script:AppName\natverkshanteraren.log"
# Gäller tills default_config.json har lästs, se Set-LogSettings. $null betyder avstängd loggning.
$script:LogPath = $script:DefaultLogPath

# Om UAC-dialogen fylls i med ett annat administratörskonto körs det upphöjda skriptet som det
# kontot, och %APPDATA% skulle då peka på fel användares mapp. Därför skickas den inloggade
# användarens värden för dessa variabler med vid omstarten, se Invoke-SelfElevation.
$script:CallerEnvironmentNames = 'APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'USERNAME', 'USERDOMAIN', 'OneDrive'
$script:CallerEnvValues = @{}

#region Loggning och behörighet

function Set-LogSettings {
    # Tar loggningsinställningarna från en inläst konfiguration (Get-AppConfig).
    param([Parameter(Mandatory)]$Config)
    $script:LogPath = $Config.LogPath
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if ([string]::IsNullOrEmpty($script:LogPath)) { return }   # Loggning avstängd i konfigurationen.
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] [{2}] {3}' -f (Get-Date), $Level, [Environment]::UserName, $Message
    try {
        $dir = Split-Path -Parent $script:LogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {
        # Ett loggfel får aldrig stoppa själva nätverksbytet.
        Write-Warning "Kunde inte skriva till loggen: $($_.Exception.Message)"
    }
}

function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-MessageBox {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information'
    )
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$Icon
    ) | Out-Null
}

function Invoke-SelfElevation {
    # Startar om skriptet som administratör med samma läge. Den nuvarande processen avslutas efteråt.
    param([string]$ExtraArguments = '')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $ExtraArguments"
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs | Out-Null
    } catch {
        # Vanligaste orsaken: Nej i UAC-dialogen, eller att kontot inte kan bli administratör.
        Write-Log "Kunde inte starta som administratör: $($_.Exception.Message)" WARN
        Show-MessageBox -Text 'Nätverkshanteraren behöver administratörsbehörighet för att ändra nätverksinställningar.' `
                        -Title 'Behörighet saknas' -Icon Warning
    }
}

function ConvertTo-CallerEnvironmentArgument {
    # Packar den aktuella användarens värden för $CallerEnvironmentNames som base64-kodad JSON,
    # så att sökvägar med mellanslag och specialtecken överlever kommandoraden.
    $values = @{}
    foreach ($name in $script:CallerEnvironmentNames) {
        $values[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $json = $values | ConvertTo-Json -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function ConvertFrom-CallerEnvironmentArgument {
    # Motsatsen till ConvertTo-CallerEnvironmentArgument. Tar bara med kända variabelnamn med textvärden.
    param([string]$Encoded)
    $result = @{}
    if ([string]::IsNullOrEmpty($Encoded)) { return $result }
    try {
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded)) | ConvertFrom-Json
    } catch {
        throw 'Ogiltigt värde för -CallerEnvironment.'
    }
    foreach ($name in $script:CallerEnvironmentNames) {
        $value = $decoded.$name
        if ($value -is [string] -and $value -ne '') { $result[$name] = $value }
    }
    return $result
}

#endregion

#region Konfiguration och validering

function Expand-ConfigVariable {
    # Som [Environment]::ExpandEnvironmentVariables, men den inloggade användarens värden
    # (från -CallerEnvironment) går före processens egna. Okända variabler lämnas orörda.
    param([Parameter(Mandatory)][string]$Value)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        $name = $match.Groups[1].Value
        if ($script:CallerEnvValues.ContainsKey($name)) { return $script:CallerEnvValues[$name] }
        $processValue = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $processValue) { return $processValue }
        return $match.Value
    }
    return [regex]::Replace($Value, '%([^%]+)%', $evaluator)
}

function Test-IPv4String {
    param($Value)
    # Regexen krävs eftersom TryParse annars godtar t.ex. "1" som 0.0.0.1.
    if ($Value -isnot [string] -or $Value -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)
}

function Test-NetProfile {
    # Returnerar en lista med problem. Tom lista betyder att profilen är giltig.
    param($NetProfile)
    $problems = New-Object System.Collections.Generic.List[string]

    if ($null -eq $NetProfile) {
        $problems.Add('Profilen är tom.')
        return , $problems.ToArray()
    }
    if ($NetProfile.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($NetProfile.Name)) {
        $problems.Add('Name saknas.')
    }
    if ($NetProfile.Type -isnot [string] -or $NetProfile.Type -notin 'DHCP', 'Static') {
        $problems.Add("Type måste vara 'DHCP' eller 'Static', inte '$($NetProfile.Type)'.")
        return , $problems.ToArray()
    }

    if ($NetProfile.Type -eq 'Static') {
        if (-not (Test-IPv4String $NetProfile.IPAddress)) {
            $problems.Add("IPAddress '$($NetProfile.IPAddress)' är inte en giltig IPv4-adress.")
        }
        $prefix = 0
        if (-not [int]::TryParse([string]$NetProfile.PrefixLength, [ref]$prefix) -or $prefix -lt 1 -or $prefix -gt 32) {
            $problems.Add("PrefixLength '$($NetProfile.PrefixLength)' måste vara ett heltal 1-32.")
        }
        if ($null -ne $NetProfile.Gateway -and -not (Test-IPv4String $NetProfile.Gateway)) {
            $problems.Add("Gateway '$($NetProfile.Gateway)' är inte en giltig IPv4-adress.")
        }
        foreach ($dns in @($NetProfile.DnsServers)) {
            if ($null -ne $dns -and -not (Test-IPv4String $dns)) {
                $problems.Add("DNS-servern '$dns' är inte en giltig IPv4-adress.")
            }
        }
    }
    return , $problems.ToArray()
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        # -Encoding UTF8 behövs i Windows PowerShell 5.1, annars blir å/ä/ö fel i filer utan BOM.
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Filen är tom.' }
        return $raw | ConvertFrom-Json
    } catch {
        throw "Kunde inte läsa '$Path': $($_.Exception.Message)"
    }
}

function Resolve-ConfigPath {
    # Expanderar miljövariabler och gör relativa sökvägar relativa till konfigurationsmappen.
    # Returnerar $Fallback om värdet saknas och en fallback har angetts.
    param(
        $Value,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][string]$ConfigDirectory,
        [string]$Fallback
    )
    if ($null -eq $Value -and $Fallback) { return $Fallback }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Setting i default_config.json måste vara en sökväg."
    }
    $path = Expand-ConfigVariable $Value
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $ConfigDirectory $path }
    return $path
}

function Get-AppConfig {
    <#
        Läser default_config.json och, om -DefaultOnly inte anges, profilfilerna i ProfilesConfigPaths.
        Fel i default_config.json är fatala. Fel i en profilfil blir varningar, och de felaktiga
        profilerna eller filerna hoppas över så att resten fortfarande går att använda.
    #>
    param(
        [string]$ConfigDirectory = $PSScriptRoot,
        [switch]$DefaultOnly
    )
    $defaultPath = Join-Path $ConfigDirectory 'default_config.json'
    if (-not (Test-Path -LiteralPath $defaultPath)) { throw "Hittar inte '$defaultPath'." }

    $defaultConfig = Read-JsonFile $defaultPath
    if ($defaultConfig.InterfaceName -isnot [string] -or [string]::IsNullOrWhiteSpace($defaultConfig.InterfaceName)) {
        throw 'InterfaceName saknas i default_config.json.'
    }
    if ($null -eq $defaultConfig.DefaultProfile) {
        throw "DefaultProfile saknas i default_config.json. (Det äldre formatet med en 'Profiles'-lista används inte längre.)"
    }
    $problems = Test-NetProfile $defaultConfig.DefaultProfile
    if ($problems.Count -gt 0) {
        throw "Ogiltig DefaultProfile i default_config.json: $($problems -join ' ')"
    }

    $logEnabled = $defaultConfig.LogEnabled
    if ($null -eq $logEnabled) { $logEnabled = $true }
    if ($logEnabled -isnot [bool]) {
        throw "LogEnabled i default_config.json måste vara true eller false (utan citattecken), inte '$logEnabled'."
    }
    $logPath = Resolve-ConfigPath -Value $defaultConfig.LogPath -Setting 'LogPath' `
        -ConfigDirectory $ConfigDirectory -Fallback $script:DefaultLogPath
    if (-not $logEnabled) { $logPath = $null }

    if ($null -ne $defaultConfig.ProfilesConfigPath) {
        throw 'ProfilesConfigPath i default_config.json heter nu ProfilesConfigPaths och är en lista, t.ex. ["profiles_global.json"].'
    }
    if ($null -eq $defaultConfig.ProfilesConfigPaths) {
        $profilesPaths = @(Join-Path $ConfigDirectory 'profiles_config.json')
    } else {
        $profilesPaths = @(foreach ($value in @($defaultConfig.ProfilesConfigPaths)) {
            Resolve-ConfigPath -Value $value -Setting 'Varje post i ProfilesConfigPaths' -ConfigDirectory $ConfigDirectory
        })
    }

    # Källan används i fönstret för att visa vilken fil en profil kommer från.
    Add-Member -InputObject $defaultConfig.DefaultProfile -NotePropertyName Source -NotePropertyValue $defaultPath -Force
    $profiles = New-Object System.Collections.Generic.List[object]
    $profiles.Add($defaultConfig.DefaultProfile)
    $warnings = New-Object System.Collections.Generic.List[string]   # Visas för användaren.
    $notes = New-Object System.Collections.Generic.List[string]      # Skrivs bara till loggen.

    if (-not $DefaultOnly) {
        foreach ($profilesPath in $profilesPaths) {
            $fileName = Split-Path -Leaf $profilesPath
            if (-not (Test-Path -LiteralPath $profilesPath -PathType Leaf)) {
                # Normalt för t.ex. en användare som inte har skapat en egen fil ännu.
                $notes.Add("Profilfilen '$profilesPath' finns inte och hoppades över.")
                continue
            }
            try {
                $fileConfig = Read-JsonFile $profilesPath
            } catch {
                $warnings.Add("$($_.Exception.Message) Inga profiler från filen laddades.")
                continue
            }

            $number = 0
            foreach ($candidate in @($fileConfig.Profiles)) {
                $number++
                if ($null -eq $candidate) { continue }
                $problems = Test-NetProfile $candidate
                if ($problems.Count -gt 0) {
                    $warnings.Add("${fileName}, profil nr ${number} ('$($candidate.Name)') hoppades över: $($problems -join ' ')")
                    continue
                }
                $existing = $profiles | Where-Object { $_.Name -eq $candidate.Name } | Select-Object -First 1
                if ($existing) {
                    $warnings.Add("${fileName}, profil nr ${number}: namnet '$($candidate.Name)' finns redan i $(Split-Path -Leaf $existing.Source) och hoppades över.")
                    continue
                }
                Add-Member -InputObject $candidate -NotePropertyName Source -NotePropertyValue $profilesPath -Force
                $profiles.Add($candidate)
            }
        }
    }

    return [pscustomobject]@{
        InterfaceName       = $defaultConfig.InterfaceName
        DefaultProfile      = $defaultConfig.DefaultProfile
        Profiles            = $profiles.ToArray()
        ProfilesConfigPaths = $profilesPaths
        LogPath             = $logPath
        Warnings            = $warnings.ToArray()
        Notes               = $notes.ToArray()
    }
}

function ConvertTo-SubnetMask {
    param([ValidateRange(1, 32)][int]$PrefixLength)
    $all32 = [uint64]4294967295
    $bits = ($all32 -shl (32 - $PrefixLength)) -band $all32
    return (3..0 | ForEach-Object { ($bits -shr (8 * $_)) -band 255 }) -join '.'
}

function Format-ProfileDetails {
    param([Parameter(Mandatory)]$NetProfile)
    if ($NetProfile.Type -eq 'DHCP') {
        $lines = @(
            'Metod: Dynamisk (DHCP)'
            'IP-adress: Tilldelas automatiskt'
            'DNS: Tilldelas automatiskt'
        )
    } else {
        $gateway = if ($NetProfile.Gateway) { $NetProfile.Gateway } else { 'ingen' }
        $dns = if ($NetProfile.DnsServers) { @($NetProfile.DnsServers) -join ', ' } else { 'ingen' }
        $mask = ConvertTo-SubnetMask ([int]$NetProfile.PrefixLength)
        $lines = @(
            'Metod: Statisk IP'
            "IP-adress: $($NetProfile.IPAddress)/$($NetProfile.PrefixLength) ($mask)"
            "Gateway: $gateway"
            "DNS: $dns"
        )
    }
    if ($NetProfile.Source) { $lines += "Källa: $(Split-Path -Leaf $NetProfile.Source)" }
    return ($lines -join "`r`n")
}

#endregion

#region Nätverkskortet

function Get-TargetAdapter {
    param([Parameter(Mandatory)][string]$Name)
    $adapter = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
    if (-not $adapter) {
        $available = (Get-NetAdapter | Select-Object -ExpandProperty Name) -join ', '
        throw "Hittar inget nätverkskort som heter '$Name'. Tillgängliga kort: $available"
    }
    return $adapter
}

function Get-AdapterIPv4Summary {
    param([Parameter(Mandatory)]$Adapter)
    $index = $Adapter.ifIndex
    $iface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4

    # SilentlyContinue: inga adresser eller rutter är ett normalt läge, t.ex. direkt efter byte till DHCP.
    $addresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
    $gateways = @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.NextHop })
    $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4).ServerAddresses)

    $addressText = if ($addresses.Count) { $addresses -join ', ' } else { 'ingen ännu' }
    if ($addresses | Where-Object { $_ -like '169.254.*' }) { $addressText += ' (ingen DHCP-server svarade)' }

    return (@(
        "Status: $($Adapter.Status)    Metod: $(if ($iface.Dhcp -eq 'Enabled') { 'DHCP' } else { 'Statisk' })"
        "IP-adress: $addressText"
        "Gateway: $(if ($gateways.Count) { $gateways -join ', ' } else { 'ingen' })"
        "DNS: $(if ($dnsServers.Count) { $dnsServers -join ', ' } else { 'ingen' })"
    ) -join "`r`n")
}

function Clear-AdapterIPv4 {
    # Tar bort alla IPv4-adresser och standardrutter, både aktiva och sparade.
    # Rester i PersistentStore är den vanligaste orsaken till att New-NetIPAddress misslyckas.
    # IPv6 lämnas orört.
    param([Parameter(Mandatory)][int]$InterfaceIndex)
    foreach ($store in 'ActiveStore', 'PersistentStore') {
        # SilentlyContinue på Get: att det inte finns något att ta bort är inget fel.
        Get-NetRoute -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore $store -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false
        Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -PolicyStore $store -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false
    }
}

function Set-AdapterIPv4Config {
    <#
        Tillämpar en profil på nätverkskortet. Kastar ett undantag om något steg misslyckas;
        anroparen ansvarar för att visa felet. Visar aldrig något fönster själv, eftersom den
        också körs som SYSTEM vid utloggning där ingen kan klicka bort en dialog.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$InterfaceName,
        [Parameter(Mandatory)]$NetProfile
    )
    $problems = Test-NetProfile $NetProfile
    if ($problems.Count -gt 0) { throw "Ogiltig profil: $($problems -join ' ')" }

    $index = (Get-TargetAdapter -Name $InterfaceName).ifIndex
    if (-not $PSCmdlet.ShouldProcess($InterfaceName, "Tillämpa profilen '$($NetProfile.Name)'")) { return }

    switch ($NetProfile.Type) {
        'DHCP' {
            Clear-AdapterIPv4 -InterfaceIndex $index
            Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Enabled
            Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses
        }
        'Static' {
            Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
            Clear-AdapterIPv4 -InterfaceIndex $index

            $ipParams = @{
                InterfaceIndex = $index
                AddressFamily  = 'IPv4'
                IPAddress      = $NetProfile.IPAddress
                PrefixLength   = [byte]$NetProfile.PrefixLength
            }
            if ($NetProfile.Gateway) { $ipParams.DefaultGateway = $NetProfile.Gateway }
            New-NetIPAddress @ipParams | Out-Null

            if ($NetProfile.DnsServers) {
                Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses @($NetProfile.DnsServers)
            } else {
                # Rensar DNS-servrar som ligger kvar från en tidigare profil.
                Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses
            }
        }
        default { throw "Okänd profiltyp '$($NetProfile.Type)'." }
    }
    Write-Log "Profilen '$($NetProfile.Name)' tillämpades på '$InterfaceName'."
}

#endregion

#region Schemalagd återställning vid utloggning

function Get-UserWritablePath {
    <#
        Returnerar de sökvägar som vanliga användare kan skriva till eller ändra behörigheter på.
        Kontrollerar grupperna Alla, Autentiserade användare, Användare och INTERACTIVE via SID,
        så att det fungerar oavsett språk på Windows. Upptäcker inte rättigheter som getts till
        enskilda användarkonton.
    #>
    param([Parameter(Mandatory)][string[]]$Path)
    $untrustedSids = 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4'
    # CreateFiles/WriteData, AppendData, WRITE_DAC, WRITE_OWNER, GENERIC_ALL, GENERIC_WRITE
    $writeMask = [int64](0x2 -bor 0x4 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000)

    foreach ($item in $Path) {
        $rules = (Get-Acl -LiteralPath $item).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            $appliesHere = -not ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)
            if ($appliesHere -and
                $rule.AccessControlType -eq 'Allow' -and
                $untrustedSids -contains $rule.IdentityReference.Value -and
                (([int64]$rule.FileSystemRights) -band $writeMask) -ne 0) {
                $item
                break
            }
        }
    }
}

function Register-LogoffResetTask {
    # Aktiviteten körs som SYSTEM. Kan en vanlig användare ändra skriptet blir det ett sätt att
    # köra valfri kod som SYSTEM, så installationen vägrar i så fall.
    $protectedPaths = @($PSScriptRoot, $PSCommandPath, (Join-Path $PSScriptRoot 'default_config.json'))
    $unsafe = @(Get-UserWritablePath -Path $protectedPaths)
    if ($unsafe.Count -gt 0) {
        throw ("Avbryter: vanliga användare kan ändra $($unsafe -join ', '). " +
               "Lägg skriptet och default_config.json i en mapp där bara administratörer har skrivrätt, " +
               "t.ex. C:\Program Files\Natverkshanteraren, och peka ut profilfilen med ProfilesConfigPath.")
    }
    Get-AppConfig -DefaultOnly | Out-Null   # Installera inte med en trasig standardkonfiguration.

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Reset"
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    # Aktivitetsschemaläggaren saknar utloggningsutlösare. Händelse 4 i User Profile Service-loggen
    # ("Finished processing user logoff notification") skrivs vid varje utloggning och loggen är
    # påslagen som standard.
    $logoffTrigger = Get-CimClass -Namespace 'ROOT\Microsoft\Windows\TaskScheduler' -ClassName 'MSFT_TaskEventTrigger' |
        New-CimInstance -ClientOnly
    $logoffTrigger.Enabled = $true
    $logoffTrigger.Subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-User Profile Service/Operational"><Select Path="Microsoft-Windows-User Profile Service/Operational">*[System[(EventID=4)]]</Select></Query></QueryList>
'@
    # Uppstart täcker strömavbrott och krascher, där ingen utloggning sker.
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Principal $principal -Settings $settings `
        -Trigger @($logoffTrigger, $startupTrigger) -Force `
        -Description 'Återställer nätverkskortet till standardprofilen i default_config.json vid utloggning och uppstart.' |
        Out-Null
    Write-Log "Schemalagd aktivitet '$script:TaskName' installerad."
}

function Unregister-LogoffResetTask {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        Write-Log "Schemalagd aktivitet '$script:TaskName' borttagen."
    }
}

#endregion

#region Fönster

function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    try {
        $config = Get-AppConfig
    } catch {
        Write-Log $_.Exception.Message ERROR
        Show-MessageBox -Text $_.Exception.Message -Title 'Konfigurationsfel' -Icon Error
        return
    }
    $config.Notes | ForEach-Object { Write-Log $_ INFO }
    if ($config.Warnings.Count -gt 0) {
        $config.Warnings | ForEach-Object { Write-Log $_ WARN }
        Show-MessageBox -Text ("Profilfilerna innehåller fel:`n`n" + ($config.Warnings -join "`n`n")) -Title 'Varning' -Icon Warning
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Nätverkshanteraren'
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.ClientSize = New-Object System.Drawing.Size(350, 355)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $lblChoose = New-Object System.Windows.Forms.Label
    $lblChoose.Text = "Välj nätverksprofil för '$($config.InterfaceName)':"
    $lblChoose.Location = New-Object System.Drawing.Point(20, 15)
    $lblChoose.Size = New-Object System.Drawing.Size(310, 20)

    $comboProfiles = New-Object System.Windows.Forms.ComboBox
    $comboProfiles.Location = New-Object System.Drawing.Point(20, 38)
    $comboProfiles.Size = New-Object System.Drawing.Size(310, 24)
    $comboProfiles.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $comboProfiles.DropDownWidth = 450

    $grpSelected = New-Object System.Windows.Forms.GroupBox
    $grpSelected.Text = 'Vald profil'
    $grpSelected.Location = New-Object System.Drawing.Point(20, 72)
    $grpSelected.Size = New-Object System.Drawing.Size(310, 110)
    $lblSelected = New-Object System.Windows.Forms.Label
    $lblSelected.Dock = 'Fill'
    $grpSelected.Controls.Add($lblSelected)

    $grpCurrent = New-Object System.Windows.Forms.GroupBox
    $grpCurrent.Text = 'Nuvarande inställning'
    $grpCurrent.Location = New-Object System.Drawing.Point(20, 190)
    $grpCurrent.Size = New-Object System.Drawing.Size(310, 100)
    $lblCurrent = New-Object System.Windows.Forms.Label
    $lblCurrent.Dock = 'Fill'
    $grpCurrent.Controls.Add($lblCurrent)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = 'Verkställ'
    $btnApply.Location = New-Object System.Drawing.Point(20, 303)
    $btnApply.Size = New-Object System.Drawing.Size(150, 36)

    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = 'Återställ standard'
    $btnReset.Location = New-Object System.Drawing.Point(180, 303)
    $btnReset.Size = New-Object System.Drawing.Size(150, 36)

    $form.Controls.AddRange(@($lblChoose, $comboProfiles, $grpSelected, $grpCurrent, $btnApply, $btnReset))

    $refreshCurrent = {
        try {
            $adapter = Get-TargetAdapter -Name $config.InterfaceName
            $lblCurrent.Text = Get-AdapterIPv4Summary -Adapter $adapter
        } catch {
            $lblCurrent.Text = "Kunde inte läsa nätverkskortet:`r`n$($_.Exception.Message)"
        }
    }

    $applyProfile = {
        param($NetProfile)
        $form.UseWaitCursor = $true
        $btnApply.Enabled = $false
        $btnReset.Enabled = $false
        try {
            Set-AdapterIPv4Config -InterfaceName $config.InterfaceName -NetProfile $NetProfile
            & $refreshCurrent
            $note = if ($NetProfile.Type -eq 'DHCP') { "`n`nDet kan ta några sekunder innan DHCP-adressen syns." } else { '' }
            Show-MessageBox -Text "Profilen '$($NetProfile.Name)' är tillämpad.$note" -Title 'Nätverk uppdaterat'
        } catch {
            $message = $_.Exception.Message
            Write-Log "Kunde inte tillämpa '$($NetProfile.Name)': $message" ERROR
            & $refreshCurrent
            Show-MessageBox -Text "Det gick inte att tillämpa '$($NetProfile.Name)'.`n`n$message" -Title 'Fel' -Icon Error
        } finally {
            $form.UseWaitCursor = $false
            $btnApply.Enabled = $true
            $btnReset.Enabled = $true
        }
    }

    $comboProfiles.Add_SelectedIndexChanged({
        $lblSelected.Text = Format-ProfileDetails -NetProfile $config.Profiles[$comboProfiles.SelectedIndex]
    })
    $btnApply.Add_Click({ & $applyProfile $config.Profiles[$comboProfiles.SelectedIndex] })
    $btnReset.Add_Click({
        $comboProfiles.SelectedIndex = 0   # Standardprofilen ligger alltid först.
        & $applyProfile $config.DefaultProfile
    })

    # Listan och $config.Profiles har samma ordning, så valt index pekar alltid på rätt profil.
    foreach ($netProfile in $config.Profiles) { [void]$comboProfiles.Items.Add($netProfile.Name) }
    $comboProfiles.SelectedIndex = 0
    & $refreshCurrent

    [void]$form.ShowDialog()
}

#endregion

#region Start

# Inläst med punkt (". .\BytNatverk.ps1"), t.ex. från tester: definiera bara funktionerna.
if ($MyInvocation.InvocationName -eq '.') { return }

# Läs loggningsinställningarna först, så att även tidiga meddelanden (t.ex. nekad UAC) följer dem.
# Om default_config.json inte går att läsa behålls standardsökvägen. Felet tystas här medvetet:
# varje läge nedan läser konfigurationen igen och loggar och visar felet där.
try { Set-LogSettings -Config (Get-AppConfig -DefaultOnly) } catch { }

switch ($PSCmdlet.ParameterSetName) {
    'Reset' {
        if (-not (Test-IsAdmin)) { Invoke-SelfElevation -ExtraArguments '-Reset'; exit }
        try {
            # Läser bara default_config.json. Profilfilerna påverkar aldrig återställningen.
            $config = Get-AppConfig -DefaultOnly
            Set-AdapterIPv4Config -InterfaceName $config.InterfaceName -NetProfile $config.DefaultProfile
            exit 0
        } catch {
            Write-Log "Återställning misslyckades: $($_.Exception.Message)" ERROR
            exit 1
        }
    }
    { $_ -in 'Install', 'Uninstall' } {
        if (-not (Test-IsAdmin)) {
            Write-Host 'Kör kommandot från en PowerShell som administratör.' -ForegroundColor Red
            exit 1
        }
        try {
            if ($InstallLogoffTask) {
                Register-LogoffResetTask
                Write-Host "Klart. '$script:TaskName' återställer nätverket vid utloggning och uppstart." -ForegroundColor Green
            } else {
                Unregister-LogoffResetTask
                Write-Host "Klart. '$script:TaskName' är borttagen." -ForegroundColor Green
            }
            exit 0
        } catch {
            Write-Log $_.Exception.Message ERROR
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
        }
    }
    'Gui' {
        if (-not (Test-IsAdmin)) {
            Invoke-SelfElevation -ExtraArguments "-CallerEnvironment $(ConvertTo-CallerEnvironmentArgument)"
            exit
        }
        try {
            # Saknas -CallerEnvironment (skriptet startades direkt som administratör) används
            # processens egna miljövariabler, vilka då redan tillhör rätt användare.
            $script:CallerEnvValues = ConvertFrom-CallerEnvironmentArgument $CallerEnvironment
            Start-Gui
        } catch {
            Write-Log "Oväntat fel: $($_.Exception.Message)" ERROR
            Show-MessageBox -Text "Oväntat fel:`n`n$($_.Exception.Message)" -Title 'Fel' -Icon Error
        }
    }
}

#endregion
