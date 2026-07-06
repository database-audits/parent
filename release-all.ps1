#Requires -Version 5.1
<#
.SYNOPSIS
    Coordinated release of the database-audits modules: parent -> core -> spring-boot.

.DESCRIPTION
    Drives the existing per-repo release mechanism across the three sibling repositories in
    dependency order. For each repo it:

      1. Adopts the freshly-released upstream version(s) as a `build(pom): Bump ...` commit
         (downstream only, and only for upstreams included in this run).
      2. Runs `release:prepare`, which runs `clean verify`, creates the v<version> tag plus the
         two [maven-release-plugin] commits, and pushes to origin.
      3. Waits for the released artifact to appear on Maven Central before releasing the module
         that depends on it.

    The signed deploy to Maven Central is performed by each repo's tag-triggered `release.yml`
    workflow -- `release:perform` is NOT run here.

    Release and next-development versions are prompted per module, defaulting to the values
    derived from each POM's current -SNAPSHOT.

.PARAMETER Modules
    Which modules to release. Defaults to all three. A subset is always run in dependency order,
    e.g. -Modules core,spring-boot. Adopt steps only bump references to upstreams that are
    themselves part of this run.

.PARAMETER DryRun
    Rehearse each repo's `release:prepare -DdryRun=true` (no commits, tags, or pushes), then
    `release:clean`. Still prompts for versions; skips adopt steps and Central waits, since the
    new upstream versions are not published during a rehearsal.

.PARAMETER Yes
    Skip only the final "Proceed?" confirmation after the pre-flight summary. The per-module
    version prompts still happen.

.EXAMPLE
    .\release-all.ps1 -DryRun
    Rehearse the whole chain without releasing anything.

.EXAMPLE
    .\release-all.ps1
    Release parent, core, and spring-boot in order.

.EXAMPLE
    .\release-all.ps1 -Modules core,spring-boot
    Release only core and spring-boot (e.g. parent was already released).
#>
[CmdletBinding()]
param(
    [ValidateSet('parent', 'core', 'spring-boot')]
    [string[]] $Modules = @('parent', 'core', 'spring-boot'),
    [switch] $DryRun,
    [switch] $Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# --- Configuration -------------------------------------------------------------------------

# Dependency order. Each downstream is released only after every upstream it adopts is on Central.
$Order = @('parent', 'core', 'spring-boot')

# On-disk sibling directory names (the 'spring-boot' dir holds the spring-boot-integration repo)
# and the Central artifactId used for the "is it published yet" gate.
$RepoConfig = @{
    'parent'      = @{ Dir = 'parent';      Artifact = 'database-audits-parent' }
    'core'        = @{ Dir = 'core';        Artifact = 'database-audits-core' }
    'spring-boot' = @{ Dir = 'spring-boot'; Artifact = 'database-audits-spring-boot-integration' }
}

$GroupPath    = 'io/github/database-audits'
$CentralBase  = 'https://repo1.maven.org/maven2'
$ContainerDir = Split-Path -Parent $PSScriptRoot   # parent's parent == the sibling container

# --- Output helpers ------------------------------------------------------------------------

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host ('=' * 76) -ForegroundColor Blue
    Write-Host "== $Text" -ForegroundColor Blue
    Write-Host ('=' * 76) -ForegroundColor Blue
}

function Write-Step {
    param([string] $Text)
    Write-Host "  -> $Text" -ForegroundColor Cyan
}

# --- Maven helpers -------------------------------------------------------------------------

function Invoke-Mvnw {
    param([string] $RepoPath, [string[]] $MvnArgs)
    $wrapper = Join-Path $RepoPath 'mvnw.cmd'
    if (-not (Test-Path $wrapper)) { throw "Maven wrapper not found: $wrapper" }
    Push-Location $RepoPath
    try {
        Write-Host "     mvnw $($MvnArgs -join ' ')" -ForegroundColor DarkGray
        & $wrapper @MvnArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Maven failed (exit $LASTEXITCODE) in ${RepoPath}: mvnw $($MvnArgs -join ' ')"
        }
    }
    finally { Pop-Location }
}

function Get-MvnwValue {
    param([string] $RepoPath, [string] $Expression)
    $wrapper = Join-Path $RepoPath 'mvnw.cmd'
    Push-Location $RepoPath
    try {
        $out = & $wrapper '-q' '-N' 'help:evaluate' "-Dexpression=$Expression" '-DforceStdout'
        if ($LASTEXITCODE -ne 0) { throw "Could not evaluate '$Expression' in $RepoPath." }
    }
    finally { Pop-Location }
    $lines = @($out | Where-Object { $_ -and $_.ToString().Trim() })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $candidate = $lines[$i].ToString().Trim()
        if ($candidate -match '^\d+\.\d+') { return $candidate }
    }
    throw "Could not parse '$Expression' for ${RepoPath}. Output:`n$out"
}

function Get-PomVersion {
    param([string] $RepoPath)
    return Get-MvnwValue $RepoPath 'project.version'
}

function Get-CorePropertyVersion {
    param([string] $SpringBootPath)
    $pom = Join-Path $SpringBootPath 'integration\pom.xml'
    $text = Get-Content -Path $pom -Raw
    if ($text -match '<database-audits-core\.version>\s*([^<]+?)\s*</database-audits-core\.version>') {
        return $Matches[1]
    }
    throw "Could not find <database-audits-core.version> in $pom."
}

# --- Version prompting ---------------------------------------------------------------------

function Get-NextDevelopmentVersion {
    param([string] $ReleaseVersion)
    $parts = $ReleaseVersion -split '\.'
    $parts[-1] = ([int] $parts[-1] + 1).ToString()
    return ($parts -join '.') + '-SNAPSHOT'
}

function Read-WithDefault {
    param([string] $Prompt, [string] $Default)
    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-ReleaseVersion {
    param([string] $Name, [string] $Default)
    while ($true) {
        $value = Read-WithDefault "  [$Name] release version" $Default
        if ($value -match '-SNAPSHOT$') {
            Write-Host "      Release version must not end with -SNAPSHOT." -ForegroundColor Red
            continue
        }
        if ($value -notmatch '^\d+(\.\d+)+$') {
            Write-Host "      Expected a numeric version like 1.2.3." -ForegroundColor Red
            continue
        }
        return $value
    }
}

function Read-DevelopmentVersion {
    param([string] $Name, [string] $Default)
    while ($true) {
        $value = Read-WithDefault "  [$Name] next development version" $Default
        if ($value -notmatch '^\d+(\.\d+)+-SNAPSHOT$') {
            Write-Host "      Expected a numeric next-development version like 1.2.3-SNAPSHOT." -ForegroundColor Red
            continue
        }
        return $value
    }
}

# --- Git / environment guards --------------------------------------------------------------

function Assert-Releasable {
    param([string] $RepoPath, [string] $Name)
    # No uncommitted *tracked* changes. Untracked/loose files are ignored -- they are not part
    # of what release:prepare commits, so they need not block a release.
    $dirty = & git -C $RepoPath status --porcelain --untracked-files=no
    if ($dirty) {
        throw "[$Name] has uncommitted tracked changes (commit or stash these first):`n$dirty"
    }
    # The release tag must be cut from commits that already exist on origin, so confirm the
    # current branch is level with its origin counterpart. Releases must be cut from 'main':
    # release.yml refuses to publish a tag whose commit is not on origin/main.
    $branch = (& git -C $RepoPath rev-parse --abbrev-ref HEAD).Trim()
    if ($branch -eq 'HEAD') {
        throw "[$Name] is in detached HEAD state. Check out 'main' to release."
    }
    if ($branch -ne 'main') {
        throw "[$Name] is on '$branch', but releases must be cut from 'main' (release.yml refuses to publish a tag whose commit is not on origin/main). Merge to main and check it out first."
    }
    & git -C $RepoPath fetch origin --quiet | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "[$Name] could not fetch origin. Fix the Git/network error, then re-run."
    }
    $remoteRef = & git -C $RepoPath rev-parse --verify --quiet "refs/remotes/origin/$branch"
    if (-not $remoteRef) {
        throw "[$Name] branch '$branch' has no origin/$branch -- push it to origin first."
    }
    $localRef = (& git -C $RepoPath rev-parse 'HEAD').Trim()
    if ($localRef -ne $remoteRef.Trim()) {
        throw "[$Name] branch '$branch' is not level with origin/$branch. Pull/push so they match, then re-run."
    }
    return $branch
}

function Test-RemoteTagExists {
    param([string] $RepoPath, [string] $Tag)
    $refs = & git -C $RepoPath ls-remote --tags origin "refs/tags/$Tag"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not query origin for tag '$Tag' (git ls-remote failed). Fix the Git/network error, then re-run."
    }
    return [bool] $refs
}

function Assert-Docker {
    # Route docker through cmd so the OS discards its stderr. On Rancher Desktop/WSL2 `docker info`
    # prints harmless "No blkio throttle... support" warnings to stderr, which PowerShell 5.1 wraps
    # in a NativeCommandError that $ErrorActionPreference = 'Stop' would turn into a terminating error.
    & cmd /c 'docker info > NUL 2>&1'
    if ($LASTEXITCODE -ne 0) {
        throw "Docker is not running. Start Rancher Desktop -- release:prepare runs integration tests via Testcontainers."
    }
}

function Wait-CentralArtifact {
    param([string] $Artifact, [string] $Version, [int] $TimeoutMinutes = 30)
    $url = "$CentralBase/$GroupPath/$Artifact/$Version/$Artifact-$Version.pom"
    Write-Step "Waiting for $Artifact`:$Version on Maven Central"
    Write-Host "     $url" -ForegroundColor DarkGray
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20
            if ($resp.StatusCode -eq 200) {
                Write-Host "     published." -ForegroundColor Green
                return
            }
        }
        catch {
            # Not published yet (404) or a transient error -- keep polling.
        }
        Start-Sleep -Seconds 30
    }
    throw "Timed out after $TimeoutMinutes min waiting for $Artifact`:$Version on Central. Check the repo's 'Release to Maven Central' workflow run, then resume with -Modules starting at the next module."
}

# --- Adopt (bump upstream references) ------------------------------------------------------

function Commit-AdoptBump {
    param(
        [string] $RepoPath,
        [string] $CommitMessage,
        [string] $WhatDescription,
        [string] $ActualValue,
        [string] $ExpectedValue
    )
    if ($ActualValue -ne $ExpectedValue) {
        throw "Adopt failed: expected $WhatDescription to be '$ExpectedValue' but the POM shows '$ActualValue'. Is the upstream published and resolvable through your Maven settings (mirror/Nexus)?"
    }
    $dirty = & git -C $RepoPath status --porcelain --untracked-files=no
    if ($dirty) {
        & git -C $RepoPath commit -am $CommitMessage | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git commit failed in $RepoPath" }
        Write-Host "     committed: $CommitMessage" -ForegroundColor Green
    }
    else {
        Write-Host "     already at $ExpectedValue (no commit needed)" -ForegroundColor DarkGray
    }
}

function Invoke-Adopt {
    param([hashtable] $Plan, [string] $Name, [string[]] $Selected)
    $repo = $Plan[$Name]
    if ($Name -eq 'core') {
        if ($Selected -contains 'parent') {
            $parentVersion = $Plan['parent'].ReleaseVersion
            Write-Step "Adopt parent $parentVersion"
            Invoke-Mvnw $repo.Path @('-B', 'versions:update-parent', "-DparentVersion=$parentVersion", '-DallowSnapshots=false', '-DgenerateBackupPoms=false')
            $actual = Get-MvnwValue $repo.Path 'project.parent.version'
            Commit-AdoptBump $repo.Path "build(pom): Bump database-audits-parent to $parentVersion" 'the parent version' $actual $parentVersion
        }
    }
    elseif ($Name -eq 'spring-boot') {
        if ($Selected -contains 'parent') {
            $parentVersion = $Plan['parent'].ReleaseVersion
            Write-Step "Adopt parent $parentVersion"
            Invoke-Mvnw $repo.Path @('-B', 'versions:update-parent', "-DparentVersion=$parentVersion", '-DprocessAllModules=true', '-DallowSnapshots=false', '-DgenerateBackupPoms=false')
            $actual = Get-MvnwValue $repo.Path 'project.parent.version'
            Commit-AdoptBump $repo.Path "build(pom): Bump database-audits-parent to $parentVersion" 'the parent version' $actual $parentVersion
        }
        if ($Selected -contains 'core') {
            $coreVersion = $Plan['core'].ReleaseVersion
            Write-Step "Adopt core $coreVersion"
            Invoke-Mvnw $repo.Path @('-B', 'versions:set-property', '-Dproperty=database-audits-core.version', "-DnewVersion=$coreVersion", '-DprocessAllModules=true', '-DgenerateBackupPoms=false')
            $actual = Get-CorePropertyVersion $repo.Path
            Commit-AdoptBump $repo.Path "build(pom): Bump database-audits-core to $coreVersion" 'the database-audits-core.version property' $actual $coreVersion
        }
    }
}

function Test-DownstreamNeeds {
    param([string] $Name, [string[]] $Selected)
    if ($Name -eq 'parent') {
        return (($Selected -contains 'core') -or ($Selected -contains 'spring-boot'))
    }
    if ($Name -eq 'core') {
        return ($Selected -contains 'spring-boot')
    }
    return $false
}

# --- Pre-flight ----------------------------------------------------------------------------

$selected = @($Order | Where-Object { $Modules -contains $_ })
if ($selected.Count -eq 0) { throw "No modules selected." }

Write-Section ("Pre-flight" + $(if ($DryRun) { "   (DRY RUN)" } else { "" }))

# Resolve each repo and confirm it is releasable -- no uncommitted tracked changes and the current
# branch level with origin -- before prompting for versions, so any environment problem fails fast.
$paths = @{}
foreach ($name in $selected) {
    $path = Join-Path $ContainerDir $RepoConfig[$name].Dir
    if (-not (Test-Path $path)) { throw "Repository directory not found: $path" }
    $paths[$name] = $path
    $branch = Assert-Releasable $path $name
    Write-Host "  [$name] releasable: no tracked changes, '$branch' level with origin." -ForegroundColor Green
}

# Docker is required by core/spring-boot release:prepare (Testcontainers integration tests).
if (($selected -contains 'core') -or ($selected -contains 'spring-boot')) {
    Assert-Docker
    Write-Host "  Docker is running." -ForegroundColor Green
}

# --- Plan the release (prompt for versions) ------------------------------------------------

Write-Section "Plan the release"

$plan = @{}
foreach ($name in $selected) {
    $path = $paths[$name]
    $current = Get-PomVersion $path
    if ($current -notmatch '-SNAPSHOT$') {
        throw "[$name] current version '$current' is not a -SNAPSHOT. Expected a development version to release from."
    }

    Write-Host ""
    Write-Host "  [$name] current $current" -ForegroundColor White
    $release = Read-ReleaseVersion $name ($current -replace '-SNAPSHOT$', '')
    $next = Read-DevelopmentVersion $name (Get-NextDevelopmentVersion $release)

    $plan[$name] = @{
        Name           = $name
        Path           = $path
        Artifact       = $RepoConfig[$name].Artifact
        CurrentVersion = $current
        ReleaseVersion = $release
        NextVersion    = $next
    }
}

Write-Host ""
Write-Host "Release plan:" -ForegroundColor White
foreach ($name in $selected) {
    $module = $plan[$name]
    $adopt = @()
    if ($name -eq 'core' -and ($selected -contains 'parent')) {
        $adopt += "parent->$($plan['parent'].ReleaseVersion)"
    }
    if ($name -eq 'spring-boot') {
        if ($selected -contains 'parent') { $adopt += "parent->$($plan['parent'].ReleaseVersion)" }
        if ($selected -contains 'core')   { $adopt += "core->$($plan['core'].ReleaseVersion)" }
    }
    $adoptText = if ($adopt.Count) { "  (adopt " + ($adopt -join ', ') + ")" } else { "" }
    Write-Host ("  {0,-12} {1}  ->  next {2}{3}" -f $module.Name, $module.ReleaseVersion, $module.NextVersion, $adoptText)
}

if (-not $Yes) {
    Write-Host ""
    $answer = Read-Host "Proceed with the release? [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "Aborted -- nothing was changed." -ForegroundColor Yellow
        return
    }
}

# --- Release loop --------------------------------------------------------------------------

foreach ($name in $selected) {
    $module = $plan[$name]
    Write-Section ("Release $($module.Name) $($module.ReleaseVersion)" + $(if ($DryRun) { "   (DRY RUN)" } else { "" }))
    $tag = "v$($module.ReleaseVersion)"

    $alreadyTagged = (-not $DryRun) -and (Test-RemoteTagExists $module.Path $tag)
    if ($alreadyTagged) {
        Write-Host "  Tag $tag already on origin -- skipping adopt + release:prepare (resuming)." -ForegroundColor Yellow
    }
    else {
        if (-not $DryRun) {
            Invoke-Adopt $plan $name $selected
        }
        else {
            Write-Host "  (dry run: skipping adopt -- upstream $($module.ReleaseVersion) is not published during a rehearsal)" -ForegroundColor DarkGray
        }

        $prepareArgs = @('-B', 'release:clean', 'release:prepare',
            "-DreleaseVersion=$($module.ReleaseVersion)",
            "-DdevelopmentVersion=$($module.NextVersion)",
            "-Dtag=$tag")
        if ($DryRun) { $prepareArgs += '-DdryRun=true' }

        Write-Step "release:prepare"
        Invoke-Mvnw $module.Path $prepareArgs

        if ($DryRun) {
            Invoke-Mvnw $module.Path @('-B', 'release:clean')
        }
    }

    if (-not $DryRun -and (Test-DownstreamNeeds $name $selected)) {
        Wait-CentralArtifact $module.Artifact $module.ReleaseVersion
    }
}

# --- Done ----------------------------------------------------------------------------------

Write-Section ("Done" + $(if ($DryRun) { "   (DRY RUN)" } else { "" }))
if ($DryRun) {
    Write-Host "Rehearsal complete. No commits, tags, or deploys were made." -ForegroundColor Green
}
else {
    Write-Host "Released: " -NoNewline -ForegroundColor Green
    Write-Host (($selected | ForEach-Object { "$_ $($plan[$_].ReleaseVersion)" }) -join ', ')
    Write-Host ""
    Write-Host "Each repo's tag-triggered 'Release to Maven Central' workflow performs the signed deploy." -ForegroundColor White
    Write-Host "Verify the GitHub Releases and the artifacts on Maven Central to finish." -ForegroundColor White
}
