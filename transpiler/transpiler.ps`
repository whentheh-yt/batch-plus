# transpiler.bat
# Prerelease 0.16
# -------------------------------------------------------------------
# 11/11/2025 - Started work. (This is gonna take me a while. (_ _") )
# 11/12/2025 - Added builtin system info variables ($VER, $RAM.*, $CPU, etc)
#              Fuck cmd, Powershell is where we're at

param(
    [Parameter(Mandatory=$false)]
    [string]$InputFile,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$Run,                 # if set, execute the translated batch (temporary file if no OutputFile)

    [Parameter(Mandatory=$false)]
    [switch]$ShowOnly             # if set, only print the translated batch to console
)

if ($Run.IsPresent -and $ShowOnly.IsPresent) {
    Write-Host "Error: -Run and -ShowOnly cannot be used together as they conflict." -ForegroundColor Red
    Show-Help
    exit 1
}

function Show-Help {
    Write-Host "BATP Transpiler v0.16 Prerelease" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\transpiler.ps1 -InputFile <script.batp> [-OutputFile <out.bat>] [-Run] [-ShowOnly]" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Features:" -ForegroundColor Green
    Write-Host "  - Variable assignment: let myvar = value"
    Write-Host "  - String concatenation: echo `\"text`\" + variable"
    Write-Host "  - Comments: # comment text"
    Write-Host "  - Conditionals: if (...) / else / endif"
    Write-Host "  - Loops: for (...) / endfor ; while (...) / endwhile"
    Write-Host "  - Functions: func name / endfunc"
    Write-Host "  - Builtin vars: $USER, $HOST, $DATE, $TIME, $VER, $OS"
    Write-Host "  - System vars: $RAM.TOTAL, $RAM.FREE, $RAM.USED, $CPU, $CPU.COUNT, $EXITCODE"
    Write-Host ""
}

function Find-BatpFiles {
    Get-ChildItem -Filter "*.batp" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
}

function Get-SystemInfo {
    try {
        $osVersion = [System.Environment]::OSVersion.VersionString
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totalRamMB = [math]::Round($cs.TotalPhysicalMemory / 1MB)
        # FreePhysicalMemory is in KB
        $freeRamMB = [math]::Round(($os.FreePhysicalMemory / 1KB))
        $usedRamMB = $totalRamMB - $freeRamMB
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
        $cpuName = ($cpu | Select-Object -First 1).Name
        $cpuCount = ($cpu | Measure-Object).Count
        if ($cpuCount -eq 0) { $cpuCount = 1 }
    }
    catch {
        # Fallbacks if CIM queries fail
        $osVersion = [System.Environment]::OSVersion.VersionString
        $totalRamMB = 0
        $freeRamMB = 0
        $usedRamMB = 0
        $cpuName = "UnknownCPU"
        $cpuCount = 1
    }

    return @{
        Version = $osVersion
        RAM_Total = $totalRamMB
        RAM_Free = $freeRamMB
        RAM_Used = $usedRamMB
        CPU = $cpuName
        CPU_Count = $cpuCount
    }
}

function Process-Line {
    param(
        [string]$line,
        [hashtable]$sysInfo,
        [int]$lineNum
    )

    if ($null -eq $line) { return $null }

    # Skip empty lines and comments
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
        return $null
    }

    $line = $line.Trim()

    # Variable assignment: let name = value  -> set name=value
    if ($line -match '^\s*let\s+') {
        $line = $line -replace '^\s*let\s+','set '
        $line = $line -replace '\s*=\s*','='
        return $line
    }

    # Prepare replacements (longer keys first)
    $replacements = @(
        @{ From = '$RAM.TOTAL'; To = [string]$sysInfo.RAM_Total },
        @{ From = '$RAM.FREE'; To = [string]$sysInfo.RAM_Free },
        @{ From = '$RAM.USED'; To = [string]$sysInfo.RAM_Used },
        @{ From = '$CPU.COUNT'; To = [string]$sysInfo.CPU_Count },
        @{ From = '$EXITCODE'; To = '!ERRORLEVEL!' },
        @{ From = '$USER'; To = $env:USERNAME },
        @{ From = '$HOST'; To = $env:COMPUTERNAME },
        @{ From = '$DATE'; To = (Get-Date -Format "yyyy-MM-dd") },
        @{ From = '$TIME'; To = (Get-Date -Format "HH:mm:ss") },
        @{ From = '$VER'; To = $sysInfo.Version },
        @{ From = '$OS'; To = [System.Environment]::OSVersion.Platform.ToString() },
        @{ From = '$CPU'; To = $sysInfo.CPU }
    )

    foreach ($r in $replacements) {
        if ($line -like "*$($r.From)*") {
            $line = $line.Replace($r.From, $r.To)
        }
    }

    # Helper to build an echo from tokens: removes surrounding quotes, keeps spaces
    function Build-EchoFromTokens {
        param([string[]]$tokens)
        $parts = @()
        foreach ($t in $tokens) {
            $s = $t.Trim()
            # strip surrounding double quotes if present
            if ($s -match '^"(.*)"$') { $s = $matches[1] }
            # if token is a bare word or a %VAR% reference, keep as-is
            $parts += $s
        }
        return "echo " + ($parts -join " ")
    }

    # If line already starts with echo, handle concatenation operators (+)
    if ($line -match '^\s*echo\s+') {
        $rest = $line -replace '^\s*echo\s+',''
        # support either + concatenation or space-separated tokens
        $tokens = $rest -split '\s*\+\s*'
        return Build-EchoFromTokens -tokens $tokens
    }

    # If the line looks like a quoted string or a mix of quoted and tokens without 'echo',
    # treat it as an implicit echo: e.g., "Hi," NAME "there"
    if ($line -match '^\s*"' -or ($line -match '"' -and $line -notmatch '^\s*[A-Za-z]+\s+')) {
        # split on whitespace while preserving quoted phrases as tokens
        # simple tokenizer: match either "..." or contiguous non-space sequences
        $tokenMatches = [regex]::Matches($line, '"[^"]*"|[^"\s]+') | ForEach-Object { $_.Value }
        return Build-EchoFromTokens -tokens $tokenMatches
    }

    # Handle if statements: if (condition) -> if condition (
    if ($line -match '^\s*if\s*\(.*\)\s*$') {
        if ($line -match '^\s*if\s*\((.*)\)\s*$') {
            $cond = $matches[1].Trim()
            $cond = $cond -replace '==',' EQU '
            $cond = $cond -replace '!=',' NEQ '
            return "if $cond ("
        }
    }

    if ($line -match '^\s*else\s*$') { return ") else (" }
    if ($line -match '^\s*endif\s*$') { return ")" }

    # while / endwhile
    if ($line -match '^\s*while\s*\(.*\)\s*$') {
        if ($line -match '^\s*while\s*\((.*)\)\s*$') {
            $cond = $matches[1].Trim()
            $label = "while_$lineNum"
            return ":$label`nif $cond ("
        }
    }
    if ($line -match '^\s*endwhile\s*$') {
        return "goto while_$lineNum"
    }

    # for / endfor (kept simple)
    if ($line -match '^\s*for\s*\(.*\)\s*$') {
        $label = "for_$lineNum"
        return ":$label  REM original: $line"
    }
    if ($line -match '^\s*endfor\s*$') {
        return "REM endfor (no-op)"
    }

    # functions
    if ($line -match '^\s*func\s+\S+') {
        $funcName = ($line -replace '^\s*func\s+','').Trim()
        $funcLabel = $funcName -replace '[^A-Za-z0-9_]','_'
        return ":func_$funcLabel"
    }
    if ($line -match '^\s*endfunc\s*$') {
        return "exit /b"
    }

    # Default: return line unchanged
    return $line
}

# Main script flow

if ($PSBoundParameters.Count -eq 0 -and [string]::IsNullOrWhiteSpace($InputFile)) {
    $files = Find-BatpFiles
    if ($files.Count -eq 0) {
        Write-Host "No .batp files found in current directory." -ForegroundColor Red
        Show-Help
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
    Write-Host "Invalid input file: '$InputFile'. Please provide a .batp file." -ForegroundColor Red
    Show-Help
    exit 1
}

if (-not (Test-Path $InputFile)) {
    Write-Host "Error: File not found - $InputFile" -ForegroundColor Red
    exit 1
}

# Read input
try {
    $lines = Get-Content -Path $InputFile -ErrorAction Stop
}
catch {
    Write-Host "Failed to read input file: $InputFile" -ForegroundColor Red
    exit 1
}

$sysInfo = Get-SystemInfo

# Build output batch lines
$output = @(
    "@echo off",
    "setlocal enabledelayedexpansion"
)

$lineNum = 0
foreach ($line in $lines) {
    $lineNum++
    $processed = Process-Line -line $line -sysInfo $sysInfo -lineNum $lineNum
    if ($null -ne $processed -and $processed -ne "") {
        # Preserve multi-line returns from Process-Line (e.g., labels + if on separate lines)
        if ($processed -is [string] -and $processed.Contains("`n")) {
            $output += $processed -split "`n"
        }
        else {
            $output += $processed
        }
    }
}

$output += "endlocal"

# Combine into single text
$batText = $output -join "`r`n"

if ($ShowOnly) {
    Write-Host "----- Translated .bat content -----" -ForegroundColor Cyan
    Write-Host $batText
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    try {
        $batText | Set-Content -Path $OutputFile -Encoding ASCII -ErrorAction Stop
        Write-Host "Transpiled to: $OutputFile" -ForegroundColor Green
        if ($Run) {
            Write-Host "Executing: $OutputFile" -ForegroundColor Yellow
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$OutputFile`"" -NoNewWindow -Wait
        }
        exit 0
    }
    catch {
        Write-Host "Failed to write output file: $OutputFile" -ForegroundColor Red
        exit 1
    }
}

# No output file specified -> print to console
Write-Host "--------------- Translated .bat (display only) ---------------" -ForegroundColor Cyan
Write-Host $batText

if ($Run) {
    # Create a temporary .bat file, execute, then delete
    $tempPath = [System.IO.Path]::GetTempFileName()
    $tempBat = [System.IO.Path]::ChangeExtension($tempPath, ".bat")
    Move-Item -Path $tempPath -Destination $tempBat -Force

    try {
        $batText | Set-Content -Path $tempBat -Encoding ASCII -ErrorAction Stop
        Write-Host "----------------Executing temporary batch: $tempBat----------------" -ForegroundColor Yellow
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$tempBat`"" -NoNewWindow -Wait
    }
    catch {
        Write-Host "Execution failed: $_" -ForegroundColor Red
    }
    finally {
        if (Test-Path $tempBat) {
            Remove-Item -Path $tempBat -Force -ErrorAction SilentlyContinue
        }
    }
}
