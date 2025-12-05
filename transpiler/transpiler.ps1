# transpiler.ps1
# Version 0.18 (Prerelease)
# -------------------------------------------------------------------
# November 11 Build 0.10 - Started work. (This is gonna take me a while. (_ _") )
# November 12 Build 0.11 - Added builtin system info variables ($VER, $RAM.*, $CPU, etc)
#              Fuck cmd, Powershell is where we're at
# November 19 Build 0.16 - Fixed the fucking script
# December XX Build 0.18 - Imports, logging, print(), exit(n), stricter blocks, QoL improvements

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$InputFile,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$Run,

    [Parameter(Mandatory=$false)]
    [switch]$ShowOnly,

    [Parameter(Mandatory=$false)]
    [switch]$Help,

    [Parameter(Mandatory=$false)]
    [switch]$VerboseMode,   # renamed from $Verbose to avoid collision

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [switch]$Strict,        # Treat block mismatches as errors

    [Parameter(Mandatory=$false)]
    [switch]$NoBanner       # Do not emit transpiler banner in output
)

# --------------------------
# Help
# --------------------------
function Show-Help {
    Write-Host ".batp Transpiler v0.18" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Gray
    Write-Host "  .\transpiler.ps1 -InputFile <script.batp> [-OutputFile <out.bat>] [-Run] [-ShowOnly]" -ForegroundColor Gray
    Write-Host "                    [-VerboseMode] [-DryRun] [-Strict] [-NoBanner]" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Features:" -ForegroundColor Gray
    Write-Host "  - let VAR = expr | ""string""       (numeric -> set /a; strings escaped)"
    Write-Host "  - echo ""A"" + $b + ""C""            (concatenation with +)"
    Write-Host "  - implicit echo for bare quoted lines"
    Write-Host "  - if(...), else, endif               (==, != supported, otherwise raw)"
    Write-Host "  - while(...), endwhile               (labels generated)"
    Write-Host "  - for (var in items), endfor         (simple item iteration)"
    Write-Host "  - func name ... endfunc; call name   (function labels)"
    Write-Host "  - import path                        (inline import of .batp/.bat)"
    Write-Host "  - print(expr)                        (alias for echo)"
    Write-Host "  - exit(n)                            (set exit code)"
    Write-Host ""
    Write-Host "Builtins:" -ForegroundColor Gray
    Write-Host "  $RAM.TOTAL $RAM.FREE $RAM.USED $CPU $CPU.COUNT $EXITCODE $USER $HOST $DATE $TIME $VER $OS"
    Write-Host ""
}

if ($Help) { Show-Help; exit 0 }

if ($Run.IsPresent -and $ShowOnly.IsPresent) {
    Write-Host "Error: -Run and -ShowOnly cannot be used together." -ForegroundColor Red
    exit 1
}

# --------------------------
# Logging
# --------------------------
function Log {
    param([string]$msg, [ValidateSet('debug','info','warn','error')][string]$level = 'info')
    switch ($level) {
        'debug' { if ($VerboseMode) { Write-Host "[DEBUG] $msg" -ForegroundColor DarkGray } }
        'info'  { Write-Host "[INFO]  $msg" -ForegroundColor Gray }
        'warn'  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
        'error' { Write-Host "[ERROR] $msg" -ForegroundColor Red }
    }
}

# --------------------------
# Discovery
# --------------------------
function Find-BatpFiles {
    Get-ChildItem -Filter "*.batp" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
}

# --------------------------
# System info
# --------------------------
function Get-SystemInfo {
    try {
        $os  = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cs  = Get-CimInstance -ClassName Win32_ComputerSystem   -ErrorAction Stop
        $cpu = Get-CimInstance -ClassName Win32_Processor        -ErrorAction Stop

        $totalRamMB = [math]::Round($cs.TotalPhysicalMemory / 1MB)
        $freeRamMB  = [math]::Round(($os.FreePhysicalMemory / 1KB))
        $usedRamMB  = $totalRamMB - $freeRamMB

        $cpuName  = ($cpu | Select-Object -First 1).Name
        $cpuCount = ($cpu | Measure-Object).Count
        if ($cpuCount -eq 0) { $cpuCount = 1 }

        $ver = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).ProductName
        if (-not $ver) { $ver = [System.Environment]::OSVersion.VersionString }
    }
    catch {
        $totalRamMB = 0; $freeRamMB = 0; $usedRamMB = 0; $cpuName = "Unknown CPU"; $cpuCount = 1; $ver = [System.Environment]::OSVersion.VersionString
    }

    return @{
        Version   = $ver
        RAM_Total = $totalRamMB
        RAM_Free  = $freeRamMB
        RAM_Used  = $usedRamMB
        CPU       = $cpuName
        CPU_Count = $cpuCount
    }
}

# --------------------------
# Escaping
# --------------------------
function Escape-BatchLiteral {
    param([string]$s)
    if ($null -eq $s) { return "" }
    $s = $s -replace '%','%%'
    $s = $s -replace '\^','^^'
    $s = $s -replace '&','^&'
    $s = $s -replace '\|','^|'
    $s = $s -replace '<','^<'
    $s = $s -replace '>','^>'
    return $s
}

# --------------------------
# Tokenizer
# --------------------------
function Tokenize {
    param([string]$line)
    $pattern = @'
"[^"]*"|'[^']*'|[^\s]+
'@
    $matches = [regex]::Matches($line, $pattern) | ForEach-Object { $_.Value }
    return $matches
}

# --------------------------
# Expression conversion
# --------------------------
function Convert-Expression {
    param([string]$expr)
    # Replace $var with !var! for delayed expansion
    $expr = $expr -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'
    return $expr
}

# --------------------------
# Import support
# --------------------------
$ImportedPaths = New-Object System.Collections.Generic.HashSet[string]

function Resolve-ImportPath {
    param([string]$importToken, [string]$baseDir)
    # Allows quoted or bare paths; relative to baseDir
    $p = $importToken.Trim()
    if ($p -match '^"(.*)"$') { $p = $matches[1] }
    elseif ($p -match "^'(.*)'$") { $p = $matches[1] }
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        return (Join-Path -Path $baseDir -ChildPath $p)
    }
    return $p
}

function Import-File {
    param(
        [string]$path,
        [hashtable]$sysInfo,
        [ref]$blockStack,
        [ref]$lineNumRef
    )
    $full = (Resolve-Path -Path $path -ErrorAction SilentlyContinue)
    if ($null -eq $full) {
        Log "Import failed: $path not found" "warn"
        return @("REM import failed: $path")
    }
    $fullPath = $full.Path
    if ($ImportedPaths.Contains($fullPath)) {
        Log "Import skipped (already imported): $fullPath" "debug"
        return @("REM import skipped: $fullPath")
    }
    $ImportedPaths.Add($fullPath) | Out-Null
    Log "Importing: $fullPath" "info"

    $content = Get-Content -Path $fullPath -Raw -Encoding UTF8
    $lines = $content -split "`r?`n"
    $out = @()
    foreach ($ln in $lines) {
        $lineNumRef.Value++
        $processed = Process-Line -line $ln -sysInfo $sysInfo -lineNum $lineNumRef.Value -blockStack ([ref]$blockStack)
        if ($null -ne $processed -and $processed -ne "") {
            if ($processed -is [string] -and $processed.Contains("`n")) {
                $out += $processed -split "`n"
            }
            else {
                $out += $processed
            }
        }
    }
    return $out
}

# --------------------------
# Line processor
# --------------------------
function Process-Line {
    param(
        [string]$line,
        [hashtable]$sysInfo,
        [int]$lineNum,
        [ref]$blockStack
    )

    if ($null -eq $line) { return $null }
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }

    $raw = $line
    $line = $line.Trim()

    # Comment lines (#) and inline trailing comments " ... # ... "
    if ($line.StartsWith("#")) { return $null }
    if ($line -match '^(.*?)(\s+#\s*.*)$') {
        $line = $matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    }

    # import path
    if ($line -match '^\s*import\s+(.+)$') {
        $importTok = $matches[1].Trim()
        $baseDir = (Get-Location).Path
        $path = Resolve-ImportPath -importToken $importTok -baseDir $baseDir
        # Allow importing .batp (transpile) or .bat (verbatim inclusion)
        if ($path.ToLower().EndsWith(".bat")) {
            if (-not (Test-Path $path)) {
                return "REM import failed: $path"
            }
            $batLines = Get-Content -Path $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue -ea SilentlyContinue
            if ($null -eq $batLines) { return "REM import failed: $path (read)" }
            return $batLines
        }
        else {
            # .batp or other text -> transpile inline
            return (Import-File -path $path -sysInfo $sysInfo -blockStack ([ref]$blockStack) -lineNumRef ([ref]([ref]$lineNum)))
        }
    }

    # let assignment
    if ($line -match '^\s*let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') {
        $name = $matches[1]
        $value = $matches[2].Trim()

        # Numeric expression? (digits, ops, parentheses, spaces, $vars, !vars)
        if ($value -match '^[0-9!\$\s\+\-\*\/\%\(\)]+$') {
            $expr = Convert-Expression -expr $value
            return "set /a $name=$expr"
        }

        # String: expand $var -> !var!, remove surrounding quotes, escape specials
        $value = $value -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'
        if ($value -match '^"(.*)"$') { $value = $matches[1] }
        elseif ($value -match "^'(.*)'$") { $value = $matches[1] }
        $escaped = Escape-BatchLiteral -s $value
        return "set `"$name=$escaped`""
    }

    # Builtin replacements
    $replacements = @{
        '$RAM.TOTAL' = [string]$sysInfo.RAM_Total
        '$RAM.FREE'  = [string]$sysInfo.RAM_Free
        '$RAM.USED'  = [string]$sysInfo.RAM_Used
        '$CPU.COUNT' = [string]$sysInfo.CPU_Count
        '$EXITCODE'  = '!ERRORLEVEL!'
        '$USER'      = $env:USERNAME
        '$HOST'      = $env:COMPUTERNAME
        '$DATE'      = (Get-Date -Format "yyyy-MM-dd")
        '$TIME'      = (Get-Date -Format "HH:mm:ss")
        '$VER'       = $sysInfo.Version
        '$OS'        = [System.Environment]::OSVersion.Platform.ToString()
        '$CPU'       = $sysInfo.CPU
    }
    foreach ($k in $replacements.Keys) {
        if ($line -like "*$k*") { $line = $line.Replace($k, $replacements[$k]) }
    }

    # print(expr) -> echo
    if ($line -match '^\s*print\s*\((.*)\)\s*$') {
        $content = $matches[1].Trim()
        # support "A" + $b + "C"
        $parts = $content -split '\s*\+\s*'
        $outParts = @()
        foreach ($p in $parts) {
            $t = $p.Trim()
            $t = $t -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'
            if ($t -match '^"(.*)"$') {
                $outParts += (Escape-BatchLiteral -s $matches[1])
            }
            elseif ($t -match "^'(.*)'$") {
                $outParts += (Escape-BatchLiteral -s $matches[1])
            }
            else {
                $outParts += $t
            }
        }
        return "echo " + ($outParts -join " ")
    }

    # exit(n)
    if ($line -match '^\s*exit\s*\((\d+)\)\s*$') {
        $code = [int]$matches[1]
        return "exit $code"
    }

    # explicit echo with concatenation
    if ($line -match '^\s*echo\s+(.*)$') {
        $rest = $matches[1].Trim()
        $parts = $rest -split '\s*\+\s*'
        $outParts = @()
        foreach ($p in $parts) {
            $t = $p.Trim()
            $t = $t -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'
            if ($t -match '^"(.*)"$') {
                $outParts += (Escape-BatchLiteral -s $matches[1])
            }
            elseif ($t -match "^'(.*)'$") {
                $outParts += (Escape-BatchLiteral -s $matches[1])
            }
            else {
                $outParts += $t
            }
        }
        return "echo " + ($outParts -join " ")
    }

    # implicit echo (any line with quotes and not "command arg")
    if ($line -match '^"' -or ($line -match '"' -and $line -notmatch '^\s*[A-Za-z]+\s+')) {
        $tokens = Tokenize -line $line
        $outParts = @()
        foreach ($t in $tokens) {
            $s = $t.Trim()
            if ($s -match '^"(.*)"$') {
                $outParts += (Escape-BatchLiteral -s $matches[1])
            }
            elseif ($s -match "^'(.*)'$") {
                $outParts += (Escape-BatchLiteral -s $matches[1])
            }
            else {
                $s = $s -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'
                $outParts += $s
            }
        }
        return "echo " + ($outParts -join " ")
    }

    # if (cond)
    if ($line -match '^\s*if\s*\((.*)\)\s*$') {
        $cond = $matches[1].Trim()
        $cond = $cond -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'
        if ($cond -match '^\s*([^\s]+)\s*==\s*([^\s]+)\s*$') {
            $left = $matches[1]; $right = $matches[2]
            return "if ""$left""==""$right"" ("
        }
        if ($cond -match '^\s*([^\s]+)\s*!=\s*([^\s]+)\s*$') {
            $left = $matches[1]; $right = $matches[2]
            return "if not ""$left""==""$right"" ("
        }
        return "if $cond ("
    }

    if ($line -match '^\s*else\s*$')  { return ") else (" }
    if ($line -match '^\s*endif\s*$') { return ")" }

    # while (cond)
    if ($line -match '^\s*while\s*\((.*)\)\s*$') {
        $cond = $matches[1].Trim()
        $label = "WHILE_$lineNum"
        $blockStack.Value.Push(@{type='while'; label=$label; line=$lineNum})
        $cond = $cond -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'
        $endLabel = "${label}_END"
        $out = ":$label`nif not $cond goto $endLabel"
        return $out
    }
    if ($line -match '^\s*endwhile\s*$') {
        if ($blockStack.Value.Count -gt 0) {
            $top = $blockStack.Value.Pop()
            if ($top.type -ne 'while') {
                if ($Strict) { return "exit /b 1" }
                return "REM endwhile (mismatched)"
            }
            $label = $top.label
            $endLabel = "${label}_END"
            return "goto $label`n:$endLabel"
        }
        else {
            if ($Strict) { return "exit /b 1" }
            return "REM endwhile (no matching while)"
        }
    }

    # for (var in items)
    if ($line -match '^\s*for\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.*)\)\s*$') {
        $var = $matches[1]
        $items = $matches[2].Trim()
        $label = "FOR_$lineNum"
        $blockStack.Value.Push(@{type='for'; label=$label})
        $listVar = "FORLIST_$lineNum"
        $items = $items -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'

        $linesOut = @()
        $linesOut += "set `"$listVar=$items`""
        $linesOut += "set `"$var=`""
        $linesOut += ":${label}_START"
        $linesOut += "for %%I in (!${listVar}!) do (set `"$var=%%I`" & goto ${label}_BODY)"
        $linesOut += ":${label}_BODY"

        return $linesOut -join "`n"
    }
    if ($line -match '^\s*endfor\s*$') {
        return "REM endfor (no-op)"
    }

    # func / endfunc
    if ($line -match '^\s*func\s+([A-Za-z_][A-Za-z0-9_]*)\s*(.*)$') {
        $funcName = $matches[1]
        $blockStack.Value.Push(@{type='func'; name=$funcName})
        return ":func_$funcName"
    }
    if ($line -match '^\s*endfunc\s*$') {
        if ($blockStack.Value.Count -gt 0) {
            $top = $blockStack.Value.Pop()
            if ($top.type -ne 'func') {
                if ($Strict) { return "exit /b 1" }
                return "REM endfunc (mismatched)"
            }
        }
        return "goto :eof"
    }

    # call function shorthand
    if ($line -match '^\s*call\s+([A-Za-z_][A-Za-z0-9_]*)(.*)$') {
        $name = $matches[1]
        $rest = $matches[2].Trim()
        if ($rest -ne "") { return "call :func_$name $rest" }
        else { return "call :func_$name" }
    }

    # generic command: replace $var with !var!
    $line = $line -replace '\$([A-Za-z_][A-Za-z0-9_]*)','!$1!'

    return $line
}

# --------------------------
# Input selection
# --------------------------
if ($PSBoundParameters.Count -eq 0 -and [string]::IsNullOrWhiteSpace($InputFile)) {
    $files = Find-BatpFiles
    if ($files.Count -eq 0) {
        Write-Host "No .batp files found in current directory." -ForegroundColor Red
        exit 1
    }
    if ($files.Count -eq 1) {
        $InputFile = $files[0]
    }
    else {
        Write-Host "Found $($files.Count) .batp files:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $files.Count; $i++) {
            Write-Host "[$($i+1)] $($files[$i])"
        }
        $selection = Read-Host "Select (number)"
        if (-not [int]::TryParse($selection, [ref]$null)) {
            Write-Host "Invalid selection." -ForegroundColor Red
            exit 1
        }
        $index = [int]$selection - 1
        if ($index -lt 0 -or $index -ge $files.Count) {
            Write-Host "Invalid selection." -ForegroundColor Red
            exit 1
        }
        $InputFile = $files[$index]
    }
}

if ([string]::IsNullOrWhiteSpace($InputFile)) {
    Write-Host "Invalid input file: '$InputFile'." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $InputFile)) {
    Write-Host "Error: File not found - $InputFile" -ForegroundColor Red
    exit 1
}

# --------------------------
# Read input
# --------------------------
try {
    $fileText = Get-Content -Path $InputFile -ErrorAction Stop -Raw -Encoding UTF8
    $lines = $fileText -split "`r?`n"
}
catch {
    Write-Host "Failed to read input file: $InputFile" -ForegroundColor Red
    exit 1
}

$sysInfo = Get-SystemInfo

# --------------------------
# Transpile
# --------------------------
$output = @()
if (-not $NoBanner) {
    $output += "@echo off"
    $output += "setlocal enabledelayedexpansion"
    $output += "rem Transpiled from $InputFile on $(Get-Date -Format o)"
    $output += "rem Generated by transpiler.ps1 v0.18"
}
else {
    $output += "@echo off"
    $output += "setlocal enabledelayedexpansion"
}

$blockStack = New-Object System.Collections.Stack
$lineNum = 0

foreach ($line in $lines) {
    $lineNum++
    $processed = Process-Line -line $line -sysInfo $sysInfo -lineNum $lineNum -blockStack ([ref]$blockStack)
    if ($null -ne $processed -and $processed -ne "") {
        if ($processed -is [string] -and $processed.Contains("`n")) {
            $output += $processed -split "`n"
        }
        else {
            $output += $processed
        }
    }
}

while ($blockStack.Count -gt 0) {
    $top = $blockStack.Pop()
    switch ($top.type) {
        'while' {
            if ($Strict) {
                $output += "REM auto-closing while block (Strict -> error)"
                $output += "exit /b 1"
            }
            else {
                $output += "REM auto-closing while block"
                $output += "goto ${($top.label)}"
                $output += ":${($top.label)}_END"
            }
        }
        'for'   {
            if ($Strict) {
                $output += "REM auto-closing for block (Strict -> error)"
                $output += "exit /b 1"
            }
            else {
                $output += "REM auto-closing for block"
            }
        }
        'func'  {
            if ($Strict) {
                $output += "REM auto-closing func block (Strict -> error)"
                $output += "exit /b 1"
            }
            else {
                $output += "REM auto-closing func block"
                $output += "goto :eof"
            }
        }
        default { $output += "REM auto-closing unknown block" }
    }
}

$output += "endlocal"
$batText = $output -join "`r`n"

# --------------------------
# Output / Run
# --------------------------
if ($ShowOnly) {
    Write-Host "----- Translated .bat content -----" -ForegroundColor Cyan
    Write-Host $batText
    exit 0
}

# Default OutputFile
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $OutputFile = "$baseName.transpiled.bat"
}

try {
    $utf8bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText((Resolve-Path (Split-Path -Leaf $OutputFile)).Path, $batText, $utf8bom)
    Write-Host "Transpiled to: $OutputFile" -ForegroundColor Green
}
catch {
    # If Resolve-Path fails for a new file, write directly
    try {
        $utf8bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($OutputFile, $batText, $utf8bom)
        Write-Host "Transpiled to: $OutputFile" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to write output file: $OutputFile" -ForegroundColor Red
        exit 1
    }
}

if ($Run) {
    if ($DryRun) {
        Write-Host "DryRun: would execute $OutputFile" -ForegroundColor Yellow
        exit 0
    }
    Write-Host "Executing: $OutputFile" -ForegroundColor Yellow
    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$OutputFile`"" -NoNewWindow -Wait
    }
    catch {
        Write-Host "Execution failed: $_" -ForegroundColor Red
        exit 1
    }
}
