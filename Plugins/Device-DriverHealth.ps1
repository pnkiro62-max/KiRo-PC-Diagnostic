# KiRo Plugin (v4.2) - Driver / Device Health
# Prikazuje uredjaje sa problemima u Device Manager-u (ConfigManagerErrorCode != 0).
# Read-only: samo prijavljuje, nista ne menja ni ne brise.
Register-KiRoPlugin -Name 'Driver / Device Health' -Author 'KiRo' -Version '1.0' -Description 'Nalazi uredjaje sa problemima u Device Manager-u (status razlicit od OK).' -ScanScript {
    try {
        $devs = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)
        $bad = @($devs | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.Present })
        $n = $bad.Count
        if ($n -eq 0) {
            Add-Finding 'INFO' 'Drajveri' ('Nema uredjaja sa problemima u Device Manager-u.') 'Sve je u redu.' '' $false
        } else {
            $sev = if ($n -gt 3) { 'UPOZORENJE' } else { 'INFO' }
            $primer = ($bad | Select-Object -First 5 | ForEach-Object { [string]$_.Name }) -join ', '
            Add-Finding $sev 'Drajveri' ("$n uredjaj(a) sa problemima u Device Manager-u.") ('Proveri uredjaje oznacene zutim upozorenjem i azuriraj drajvere. Primeri: ' + $primer) '' $false
        }
    } catch {
        Add-Finding 'INFO' 'Plugin' ('Driver Health plugin greska: ' + $_.Exception.Message) '' '' $false
    }
}
