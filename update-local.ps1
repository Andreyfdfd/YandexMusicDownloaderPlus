[CmdletBinding()]
param(
    [switch]$BuildInstaller
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$targetBranch = 'feature/installer-in-place-upgrade'

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) {
    throw "Не найден Git-репозиторий в $repoRoot"
}

$dirty = git -C $repoRoot status --porcelain
if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить Git-статус.' }
if ($dirty) {
    throw ('В локальной копии есть незакоммиченные изменения. Сначала сохрани их (commit/stash), затем повтори обновление.' + [Environment]::NewLine + $dirty)
}

git -C $repoRoot fetch origin --prune
if ($LASTEXITCODE -ne 0) { throw 'git fetch завершился с ошибкой.' }

$branchExists = git -C $repoRoot branch --list $targetBranch
if ($branchExists) {
    git -C $repoRoot switch $targetBranch
    if ($LASTEXITCODE -ne 0) { throw "Не удалось переключиться на $targetBranch." }
} else {
    git -C $repoRoot switch --track -c $targetBranch "origin/$targetBranch"
    if ($LASTEXITCODE -ne 0) { throw "Не удалось создать локальную ветку $targetBranch." }
}

git -C $repoRoot pull --ff-only origin $targetBranch
if ($LASTEXITCODE -ne 0) { throw 'git pull --ff-only завершился с ошибкой.' }

Write-Host "Обновление исходников завершено: $targetBranch" -ForegroundColor Green

if ($BuildInstaller) {
    $buildScript = Join-Path $repoRoot 'installer\build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) { throw "Скрипт сборки не найден: $buildScript" }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $buildScript
    if ($LASTEXITCODE -ne 0) { throw 'Локальная сборка установщика завершилась с ошибкой.' }
}
