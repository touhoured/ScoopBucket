#Requires -Version 5.1
<#
.SYNOPSIS
    Reorder manifest keys to this bucket's canonical field order.
.DESCRIPTION
    Runs as a dry-run by default and only prints what would change. Pass
    -Apply to actually write the reordered manifests.
.PARAMETER App
    Manifest name to reorder. Wildcards are supported. Defaults to all manifests.
.PARAMETER Apply
    Write the reordered manifests instead of only reporting.
.EXAMPLE
    PS BUCKETROOT> .\bin\reorder.ps1
    Preview key-order changes for every manifest.
.EXAMPLE
    PS BUCKETROOT> .\bin\reorder.ps1 -Apply
    Reorder every manifest in the bucket directory.
.EXAMPLE
    PS BUCKETROOT> .\bin\reorder.ps1 7zip -Apply
    Reorder the '7zip' manifest.
#>
param(
    [String] $App = '*',
    [Switch] $Apply
)

$TopOrder = @(
    'version', 'description', 'homepage', 'license', 'notes', 'depends',
    'suggest', 'architecture', 'url', 'hash', 'innosetup', 'extract_dir',
    'extract_to', 'pre_install', 'installer', 'post_install', 'env_add_path',
    'env_set', 'bin', 'shortcuts', 'persist', 'pre_uninstall', 'uninstaller',
    'post_uninstall', 'checkver', 'autoupdate'
)
$ArchOrder = @(
    'url', 'hash', 'innosetup', 'extract_dir', 'extract_to', 'pre_install',
    'installer', 'post_install', 'env_add_path', 'env_set', 'bin', 'shortcuts',
    'persist', 'pre_uninstall', 'uninstaller', 'post_uninstall'
)

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }
. "$env:SCOOP_HOME\lib\core.ps1"
. "$env:SCOOP_HOME\lib\manifest.ps1"
. "$env:SCOOP_HOME\lib\json.ps1"

$Dir = Convert-Path "$PSScriptRoot\..\bucket"

function Reorder-Object {
    param(
        [Parameter(Mandatory = $true)][psobject] $Object,
        [Parameter(Mandatory = $true)][string[]] $Order
    )
    $Values = @{}
    foreach ($Prop in $Object.PSObject.Properties) {
        $Values[$Prop.Name] = $Prop.Value
    }
    $Ordered = [ordered]@{}
    foreach ($Key in $Order) {
        if ($Values.ContainsKey($Key)) { $Ordered[$Key] = $Values[$Key] }
    }
    foreach ($Prop in $Object.PSObject.Properties) {
        if ($Order -notcontains $Prop.Name) { $Ordered[$Prop.Name] = $Prop.Value }
    }
    return [pscustomobject]$Ordered
}

function Normalize-Text([string]$Text) {
    return ($Text -replace "`r`n", "`n").TrimEnd()
}

function Get-LineDiff([string]$Old, [string]$New) {
    $a = @((Normalize-Text $Old) -split "`n")
    $b = @((Normalize-Text $New) -split "`n")
    $n = $a.Count
    $m = $b.Count
    $w = $m + 1
    $lcs = New-Object int[] (($n + 1) * $w)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            $idx = $i * $w + $j
            $diag = ($i + 1) * $w + ($j + 1)
            $down = ($i + 1) * $w + $j
            $right = $i * $w + ($j + 1)
            if ($a[$i] -ceq $b[$j]) {
                $lcs[$idx] = $lcs[$diag] + 1
            } else {
                $dl = $lcs[$down]
                $dr = $lcs[$right]
                $lcs[$idx] = [Math]::Max($dl, $dr)
            }
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    $j = 0
    while ($i -lt $n -and $j -lt $m) {
        $down = ($i + 1) * $w + $j
        $right = $i * $w + ($j + 1)
        if ($a[$i] -ceq $b[$j]) {
            $out.Add("  " + $a[$i])
            $i++
            $j++
        } elseif ($lcs[$down] -ge $lcs[$right]) {
            $out.Add("- " + $a[$i])
            $i++
        } else {
            $out.Add("+ " + $b[$j])
            $j++
        }
    }
    while ($i -lt $n) { $out.Add("- " + $a[$i]); $i++ }
    while ($j -lt $m) { $out.Add("+ " + $b[$j]); $j++ }
    return ($out -join "`n")
}

$Changed = 0
$Total = 0

Get-ChildItem $Dir -Filter "$App.json" | ForEach-Object {
    $Total++
    $File = $_.FullName
    $Json = parse_json $File
    if (!$Json) { return }
    $OriginalNames = @($Json.PSObject.Properties.Name)

    if ($Json.architecture) {
        $Arch = [ordered]@{}
        foreach ($Entry in $Json.architecture.PSObject.Properties) {
            $Arch[$Entry.Name] = Reorder-Object $Entry.Value $ArchOrder
        }
        $Json.architecture = [pscustomobject]$Arch
    }

    if ($Json.autoupdate -and $Json.autoupdate.architecture) {
        $AuArch = [ordered]@{}
        foreach ($Entry in $Json.autoupdate.architecture.PSObject.Properties) {
            $AuArch[$Entry.Name] = Reorder-Object $Entry.Value $ArchOrder
        }
        $Json.autoupdate.architecture = [pscustomobject]$AuArch
    }

    $Json = Reorder-Object $Json $TopOrder
    $Pretty = $Json | ConvertToPrettyJson
    $Pretty = $Pretty -replace "`t", '    '

    # Safety: refuse to write if the round-trip dropped or changed any top-level key.
    $Rechecked = $Pretty | ConvertFrom-Json
    $RecheckedNames = @($Rechecked.PSObject.Properties.Name)
    if ((($OriginalNames | Sort-Object) -join "`n") -ne (($RecheckedNames | Sort-Object) -join "`n")) {
        Write-Host "SKIPPED (key mismatch): $($_.BaseName)" -ForegroundColor Yellow
        return
    }

    $Current = [System.IO.File]::ReadAllText($File)
    $New = $Pretty + "`r`n"

    if ((Normalize-Text $Current) -ceq (Normalize-Text $New)) {
        if ($Apply) { Write-Host "unchanged: $($_.BaseName)" }
        return
    }

    $Changed++
    if ($Apply) {
        [System.IO.File]::WriteAllText($File, $New, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "reordered: $($_.BaseName)"
    } else {
        Write-Host "would reorder: $($_.BaseName)"
        Get-LineDiff $Current $New | ForEach-Object { Write-Host $_ }
    }
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "$Changed of $Total manifests would change (dry-run)."
}
