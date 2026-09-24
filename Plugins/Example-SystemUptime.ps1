# KiRo Plugin (v4.2 primer)
# Svaki .ps1 fajl u folderu Plugins/ se automatski ucitava na startu.
# Ovaj primer prijavljuje uptime sistema i savetuje restart ako je predugo.
Register-KiRoPlugin -Name 'System Uptime' -Author 'KiRo' -Version '1.0' -Description 'Prijavljuje uptime sistema i savetuje restart ako je predugo.' -ScanScript {
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $up = (Get-Date) - $boot
        $days = [math]::Round($up.TotalDays, 1)
        if ($days -ge 14) {
            Add-Finding 'UPOZORENJE' 'Odrzavanje' ("Sistem radi bez restarta $days dana.") 'Razmisli o restartu da osvezis drajvere i oslobodis memoriju.' '' $false
        } else {
            Add-Finding 'INFO' 'Odrzavanje' ("Sistem uptime: $days dana.") 'Sve je u redu; povremeni restart pomaze.' '' $false
        }
    } catch {
        Add-Finding 'INFO' 'Plugin' ('Uptime plugin greska: ' + $_.Exception.Message) '' '' $false
    }
}
