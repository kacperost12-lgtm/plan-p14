# Pobiera plan zajęć wszystkich sal budynku z USOSweb PWr i zapisuje go jako data.json.
# Działa w Windows PowerShell 5.1 i w PowerShell 7 (GitHub Actions, ubuntu-latest).
param(
  [string]$Building = 'P-14',
  [string]$OutFile    = 'site/data.json',
  [int]$WeeksBack     = 2,     # ile tygodni wstecz pobrać ponownie
  [int]$WeeksAhead    = 20,    # ile tygodni do przodu pobrać
  [string]$From       = '',    # opcjonalnie: pobierz od tej daty (np. początek semestru), yyyy-MM-dd
  [string[]]$Previous = @(),   # poprzednie pliki data.json: tygodnie spoza zakresu zostają z nich (pierwszy plik ma pierwszeństwo)
  [int]$KeepDays      = 400    # starsze tygodnie są usuwane
)
$ErrorActionPreference = 'Stop'
$base = 'https://web.usos.pwr.edu.pl/kontroler.php'

$ProgressPreference = 'SilentlyContinue'
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession   # USOS ustawia ciasteczko sesji i przekierowuje
function Get-Page([string]$url) {
  for ($try = 1; $try -le 3; $try++) {
    try {
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -WebSession $session -UserAgent 'Mozilla/5.0 (plan-sal)' -MaximumRedirection 10 -TimeoutSec 60
      return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } catch {
      if ($try -eq 3) { throw }
      Start-Sleep -Seconds (5 * $try)
    }
  }
}
function Dec([string]$s) { [System.Net.WebUtility]::HtmlDecode($s) }
function Strip([string]$s) { ((Dec ([regex]::Replace($s, '<[^>]+>', ''))) -replace '\s+', ' ').Trim() }
function First([string]$text, [string]$pattern) {
  $m = [regex]::Match($text, $pattern)
  if ($m.Success) { $m.Groups[1].Value } else { '' }
}

# Dzisiejsza data w czasie polskim -> poniedziałek bieżącego tygodnia
$tz = $null
foreach ($id in 'Europe/Warsaw', 'Central European Standard Time') {
  try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch {}
}
$now = if ($tz) { [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz) } else { [DateTime]::Now }
$monday = $now.Date.AddDays(-(([int]$now.DayOfWeek + 6) % 7))
$first = $monday.AddDays(-7 * $WeeksBack)
if ($From) {
  $f = [DateTime]::ParseExact($From, 'yyyy-MM-dd', $null)
  $first = $f.AddDays(-(([int]$f.DayOfWeek + 6) % 7))
}
$last = $monday.AddDays(7 * $WeeksAhead)
$weekList = @()
for ($w = $first; $w -le $last; $w = $w.AddDays(7)) { $weekList += $w.ToString('yyyy-MM-dd') }
Write-Host "Tygodnie do pobrania: $($weekList[0]) .. $($weekList[-1]) ($($weekList.Count))"

# Lista sal z karty budynku
$bud = Get-Page "$base`?_action=katalog2/jednostki/pokazBudynek&bud_kod=$([uri]::EscapeDataString($Building))"
$buildingName = Strip (First $bud '(?s)<h1[^>]*>(.*?)</h1>')
$rooms = @()
foreach ($m in [regex]::Matches($bud, "(?s)<tr[^>]*>\s*<td>([^<]*)</td>\s*<td[^>]*>([^<]*)</td>\s*<td[^>]*>.*?sala_id=(\d+)")) {
  $rooms += [pscustomobject]@{ id = $m.Groups[3].Value; name = (Dec $m.Groups[1].Value).Trim(); cap = (Dec $m.Groups[2].Value).Trim() }
}
if ($rooms.Count -eq 0) { throw "Nie znaleziono sal na stronie budynku $Building (zmienił się wygląd USOS?)" }
Write-Host "Budynek: $buildingName, sale: $(($rooms | ForEach-Object name) -join ', ')"

$entries = New-Object System.Collections.ArrayList
foreach ($week in $weekList) {
  foreach ($room in $rooms) {
    $html = Get-Page "$base`?_action=katalog2/jednostki/pokazSale&sala_id=$($room.id)&plan_division=week&plan_week_sel_week=$week"
    $i = $html.IndexOf('<usos-timetable')
    if ($i -lt 0) { throw "Brak planu w odpowiedzi dla sali $($room.name), tydzień $week" }
    $html = $html.Substring($i)
    foreach ($d in [regex]::Matches($html, '(?s)<h4>(.*?)</h4>\s*</div>\s*<timetable-day>(.*?)</timetable-day>')) {
      $day = Strip $d.Groups[1].Value
      foreach ($e in [regex]::Matches($d.Groups[2].Value, '(?s)<timetable-entry(.*?)</timetable-entry>')) {
        $t = $e.Groups[1].Value
        $ev = Strip (First $t '(?s)slot="dialog-event">(.*?)</span>')
        $tm = [regex]::Match($ev, '(\d{1,2}:\d{2})\D+(\d{1,2}:\d{2})')
        if (-not $tm.Success) { continue }
        $people = @([regex]::Matches((First $t '(?s)slot="dialog-person">(.*?)</div>'), '>([^<]+)</a>') | ForEach-Object { (Dec $_.Groups[1].Value).Trim() })
        [void]$entries.Add([pscustomobject]@{
          week   = $week
          room   = $room.name
          day    = $day
          start  = $tm.Groups[1].Value
          end    = $tm.Groups[2].Value
          name   = Dec (First $t 'name="([^"]*)"')
          code   = First $t 'name-id="([^"]*)"'
          info   = Strip (First $t '(?s)slot="info">(.*?)</div>')
          type   = Strip (First $t '(?s)slot="dialog-info">(.*?)</span>')
          people = $people
          link   = Dec (First $t "slot=`"dialog-info`"><a href='([^']*)'")
        })
      }
    }
    Start-Sleep -Milliseconds 300
  }
  Write-Host "Tydzień ${week}: $(@($entries | Where-Object week -eq $week).Count) zajęć"
}

# Dołącz tygodnie z poprzednich danych, których teraz nie pobieraliśmy
$allWeeks = New-Object System.Collections.Generic.SortedSet[string]
foreach ($w in $weekList) { [void]$allWeeks.Add($w) }
$cutoff = $monday.AddDays(-$KeepDays).ToString('yyyy-MM-dd')
$taken = New-Object System.Collections.Generic.HashSet[string]
foreach ($w in $weekList) { [void]$taken.Add($w) }
foreach ($p in $Previous) {
  if (-not $p -or -not (Test-Path $p)) { continue }
  try {
    $prev = [System.IO.File]::ReadAllText((Resolve-Path $p).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $fresh = @($prev.weeks | Where-Object { -not $taken.Contains($_) -and $_ -ge $cutoff })
    $kept = 0
    foreach ($e in $prev.entries) {
      if ($fresh -contains $e.week) { [void]$entries.Add($e); $kept++ }
    }
    foreach ($w in $fresh) { [void]$allWeeks.Add($w); [void]$taken.Add($w) }
    Write-Host "Z $p zachowano $($fresh.Count) tygodni ($kept zajęć)"
  } catch { Write-Host "Nie udało się odczytać ${p}: $_" }
}
$weekList = @($allWeeks)
$entries = [System.Collections.ArrayList]@($entries | Sort-Object week, room, day, { [int]($_.start -replace ':','') })

$out = [pscustomobject]@{
  building     = $Building
  buildingName = $buildingName
  source       = "$base`?_action=katalog2/jednostki/pokazBudynek&bud_kod=$Building"
  generated    = $now.ToString('yyyy-MM-dd HH:mm')
  weeks        = $weekList
  rooms        = @($rooms | ForEach-Object { [pscustomobject]@{ name = $_.name; cap = $_.cap } })
  entries      = $entries.ToArray()
}
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$json = ConvertTo-Json -InputObject $out -Depth 5 -Compress
[System.IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile), $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Zapisano $OutFile ($($entries.Count) zajęć)"
