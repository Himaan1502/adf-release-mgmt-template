param (
    [string]$parameterFile = "parameters.json",
    [string]$variablesFile = "variable.txt",
    [string]$outputFile = "parameters.updated.json"
)

# --- Check input files ---
if (-not (Test-Path $parameterFile)) {
    Write-Error "Parameter file not found: $parameterFile"
    exit 1
}
if (-not (Test-Path $variablesFile)) {
    Write-Error "Variables file not found: $variablesFile"
    exit 1
}

# --- Load parameter.json ---
$paramJson = Get-Content $parameterFile -Raw | ConvertFrom-Json

# --- Dictionaries ---
$variables = @{}
$rawQuoted = @{}

# --- Read variable.txt line by line ---
$rawLines = Get-Content $variablesFile -Encoding UTF8

# Ensure we always have an array of lines, not a single string or char[]
if ($rawLines -is [string]) {
    # File has one long line or was read as a single string — split it manually
    $lines = $rawLines -split "`r?`n"
} elseif ($rawLines -is [System.Array]) {
    $lines = $rawLines
} else {
    Write-Error "Unexpected type for lines: $($rawLines.GetType().FullName)"
    exit 1
}

$i = 0
while ($i -lt $lines.Count) {
    $line = $lines[$i].Trim()
    if ($line -eq "") { $i++; continue }

    # Skip lines without '='
    if ($line -notmatch '=') {
        Write-Host "Skipping invalid line: $line"
        $i++
        continue
    }

    # Extract key/value safely
    $splitIndex = $line.IndexOf("=")
    $key = $line.Substring(0, $splitIndex).Trim()
    $value = $line.Substring($splitIndex + 1).Trim()

    # --- Multi-line JSON object ---
    if ($value.StartsWith("{")) {
        $block = $value
        $openBraces = ($block -split '{').Count - 1
        $closeBraces = ($block -split '}').Count - 1
        while ($openBraces -ne $closeBraces -and $i -lt $lines.Count - 1) {
            $i++
            $block += "`n" + $lines[$i]
            $openBraces = ($block -split '{').Count - 1
            $closeBraces = ($block -split '}').Count - 1
        }
        try { $variables[$key] = $block | ConvertFrom-Json } catch { $variables[$key] = $block }
    }
    # --- Multi-line JSON array ---
    elseif ($value.StartsWith("[")) {
        $block = $value
        $openBrackets = ($block -split '\[').Count - 1
        $closeBrackets = ($block -split '\]').Count - 1
        while ($openBrackets -ne $closeBrackets -and $i -lt $lines.Count - 1) {
            $i++
            $block += "`n" + $lines[$i]
            $openBrackets = ($block -split '\[').Count - 1
            $closeBrackets = ($block -split '\]').Count - 1
        }
        try { $variables[$key] = $block | ConvertFrom-Json } catch { $variables[$key] = $block }
    }
    # --- Quoted string ---
    elseif (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $inner = $value.Substring(1, $value.Length - 2)
        $variables[$key] = $inner
        $rawQuoted[$key] = $true
    }
    # --- Boolean ---
    elseif ($value -match '^(?i:true|false)$') {
        $variables[$key] = [System.Boolean]::Parse($value)
    }
    # --- Integer ---
    elseif ($value -match '^\d+$') {
        $variables[$key] = [int]$value
    }
    # --- Fallback string ---
    else {
        $variables[$key] = $value
    }

    $i++
}

# --- Update parameter JSON ---
foreach ($key in $variables.Keys) {
    if ($paramJson.parameters.PSObject.Properties.Name -contains $key) {
        $paramJson.parameters.$key.value = $variables[$key]
    }
}

# --- Convert to JSON ---
$json = $paramJson | ConvertTo-Json -Depth 50 -Compress

# --- Fix quoted strings to prevent double escaping ---
foreach ($key in $rawQuoted.Keys) {
    $raw = $variables[$key]
    $replacement = '"value": "' + $raw + '"'
    $json = $json -replace '("'+[regex]::Escape($key)+'"\s*:\s*{)[^}]+(})', "`$1$replacement`$2"
}

# --- Pretty-print final JSON ---
$json | ConvertFrom-Json | ConvertTo-Json -Depth 50 | Out-File -FilePath $outputFile -Encoding UTF8

Write-Host "✅ Updated parameters written to $outputFile"
