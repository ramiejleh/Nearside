# Phase 3 check, run in the VM: set up from Windows (pass the pair arguments), copy text in
# Windows and see it in the engine's history, then restart and see it reconnect without a code.
# Prints only sources and lengths, never clipboard text.
param([string]$PairArgs)
Set-Location "$HOME\nearside\windows\Spike"
function Run($a, $out) {
    Remove-Item $out -ErrorAction SilentlyContinue
    if ($a) { $p = Start-Process .build\debug\nearside-engine.exe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $out }
    else { $p = Start-Process .build\debug\nearside-engine.exe -NoNewWindow -PassThru -RedirectStandardOutput $out }
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep 1
        $t = Get-Content $out -Raw -ErrorAction SilentlyContinue
        if ($t -match "linked|failed") { break }
    }
    return $p
}
$p = Run $PairArgs "setup.txt"
"== setup"; Get-Content setup.txt | Select-String "state|failed"
Start-Sleep 3
Set-Clipboard -Value "Nearside test from Windows"
Start-Sleep 4
"== history"
$h = Get-ChildItem -Recurse -Filter history.json "$env:LOCALAPPDATA\Nearside" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($h) { (Get-Content $h.FullName -Raw | ConvertFrom-Json).items | ForEach-Object { "$($_.source) $($_.text.Length) chars" } } else { "no history" }
$p.Kill(); Start-Sleep 2
$p = Run "" "restart.txt"
"== restart"; Get-Content restart.txt | Select-String "state"
$p.Kill()
