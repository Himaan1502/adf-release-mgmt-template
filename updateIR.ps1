Write-Host "Script started.."

function Replace-LinkedServiceNames {
    param (
        [string]$Directory,
        [string]$FilePattern,
        [string]$SourceIRName,
        [string]$TargetIRName
    )

    # Ensure the directory path is absolute (resolve relative path to absolute)
    $Directory = Resolve-Path $Directory

    # Get all matching files recursively
    Get-ChildItem -Path $Directory -Recurse -File |
    Where-Object { $_.Name.ToLower().StartsWith('armtemplate') -and $_.Name.EndsWith($FilePattern) } |
    ForEach-Object {
        $filePath = $_.FullName
        $content = Get-Content -Path $filePath -Raw

        # Perform the replacement
        $content = $content -replace [Regex]::Escape($SourceIRName), $TargetIRName

        Set-Content -Path $filePath -Value $content
        Write-Host "Updated: $filePath"
    }
}

# Parameters for source and target IR names passed via command line
param (
    [string]$SourceIRName,
    [string]$TargetIRName,
    [string]$SourceDirectory,  # Default value for the directory (relative path)
    [string]$FilePattern             # Default value for file pattern
)

# Ensure $SourceDirectory is resolved correctly
$SourceDirectory = Resolve-Path $SourceDirectory

# Calling the function to replace names
Replace-LinkedServiceNames -Directory $SourceDirectory -FilePattern $FilePattern -SourceIRName $SourceIRName -TargetIRName $TargetIRName

Write-Host "Script run successful.."
