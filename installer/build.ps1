param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\output')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$payload = Join-Path $repoRoot 'artifacts\payload'
$runtime = Join-Path $payload 'runtime'
$baseSite = Join-Path $runtime 'Lib\site-packages'
$optionalSite = Join-Path $runtime 'Optional\Lib\site-packages'
$runtimeScripts = Join-Path $runtime 'Scripts'

if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Recurse -Force }
New-Item -ItemType Directory -Force -Path $runtime, $baseSite, $optionalSite, $runtimeScripts, $OutputDirectory | Out-Null

$pythonVersion = (& python -c "import platform; print(platform.python_version())").Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pythonVersion)) {
    throw 'Python из actions/setup-python не найден.'
}

$embedName = "python-$pythonVersion-embed-amd64.zip"
$embedUrl = "https://www.python.org/ftp/python/$pythonVersion/$embedName"
$embedZip = Join-Path $env:RUNNER_TEMP $embedName
Write-Host "Скачиваю официальный embeddable CPython $pythonVersion..."
Invoke-WebRequest -Uri $embedUrl -OutFile $embedZip
Expand-Archive -LiteralPath $embedZip -DestinationPath $runtime -Force

$pthFile = Get-ChildItem -LiteralPath $runtime -Filter 'python*._pth' -File | Select-Object -First 1
if ($null -eq $pthFile) { throw 'В embeddable Python не найден файл python*._pth.' }
@(
    'python314.zip'
    '.'
    'Lib\site-packages'
    'Optional\Lib\site-packages'
    'import site'
) | Set-Content -LiteralPath $pthFile.FullName -Encoding ASCII

Write-Host 'Устанавливаю основной загрузчик и зависимости во встроенный runtime...'
python -m pip install --disable-pip-version-check --no-warn-script-location --upgrade --target $baseSite pip
if ($LASTEXITCODE -ne 0) { throw 'Не удалось подготовить pip во встроенном Python.' }

python -m pip install --disable-pip-version-check --no-warn-script-location --upgrade --target $baseSite 'https://github.com/llistochek/yandex-music-downloader/archive/main.zip' 'mutagen>=1.47.0'
if ($LASTEXITCODE -ne 0) { throw 'Не удалось установить основной yandex-music-downloader и его зависимости.' }

Write-Host 'Устанавливаю необязательный резервный backend yt-dlp...'
python -m pip install --disable-pip-version-check --no-warn-script-location --upgrade --target $optionalSite 'yt-dlp[default]' 'yt-dlp-yandex-music'
if ($LASTEXITCODE -ne 0) { throw 'Не удалось подготовить необязательный компонент yt-dlp.' }

# Make sure the embedded Python itself can import the CLI and helper modules.
$embeddedPython = Join-Path $runtime 'python.exe'
& $embeddedPython -c "import ymd.cli, yandex_music, mutagen, pip; print('Embedded Python runtime: OK')"
if ($LASTEXITCODE -ne 0) { throw 'Проверка импортов встроенного Python завершилась ошибкой.' }

Push-Location (Join-Path $repoRoot 'tools\launcher')
try {
    $env:GO111MODULE = 'on'
    go build -trimpath -ldflags='-s -w' -o (Join-Path $runtimeScripts 'yandex-music-downloader.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось собрать launcher.exe.' }
} finally {
    Pop-Location
    Remove-Item Env:\GO111MODULE -ErrorAction SilentlyContinue
}

# Include only the files required by the Windows installer.
Copy-Item -LiteralPath (Join-Path $repoRoot 'YandexMusicDownloader.ps1') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repoRoot 'Запустить_загрузку.bat') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repoRoot 'ПРОЧТИ_МЕНЯ.txt') -Destination $payload
New-Item -ItemType Directory -Force -Path (Join-Path $payload 'tools') | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\source_inventory.py') -Destination (Join-Path $payload 'tools')

$innosetupUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe'
$innosetupInstaller = Join-Path $env:RUNNER_TEMP 'innosetup-7.1.1-x64.exe'
Invoke-WebRequest -Uri $innosetupUrl -OutFile $innosetupInstaller
$signature = Get-AuthenticodeSignature -FilePath $innosetupInstaller
if ($signature.Status -ne 'Valid') { throw "Подпись установщика Inno Setup не прошла проверку: $($signature.Status)" }

$install = Start-Process -FilePath $innosetupInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-') -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "Установка Inno Setup завершилась с кодом $($install.ExitCode)." }

$isccCandidates = @(
    (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe')
)
$iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iscc) { throw 'ISCC.exe Inno Setup 7 не найден после установки.' }

$installerScript = Join-Path $PSScriptRoot 'YandexMusicDownloaderPlus.iss'
& $iscc "/DPayloadDir=$payload" "/DOutputDir=$OutputDirectory" $installerScript
if ($LASTEXITCODE -ne 0) { throw "Компиляция установщика завершилась с кодом $LASTEXITCODE." }

$setupExe = Join-Path $OutputDirectory 'YandexMusicDownloaderPlus-Setup-0.2.0-preview.2.exe'
if (-not (Test-Path -LiteralPath $setupExe -PathType Leaf)) { throw "Итоговый EXE не найден: $setupExe" }

# Install the just-built setup silently on the Windows runner and invoke the
# bundled CLI. This validates extraction, the embedded runtime, and the launcher.
$smokeDir = Join-Path $env:RUNNER_TEMP 'YMDPlus-Installer-Smoke'
if (Test-Path -LiteralPath $smokeDir) { Remove-Item -LiteralPath $smokeDir -Recurse -Force }
$smokeLog = Join-Path $env:RUNNER_TEMP 'YMDPlus-Installer-Smoke.log'
$smokeArgs = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/LOG=$smokeLog",("/DIR=" + $smokeDir))
$smokeInstall = Start-Process -FilePath $setupExe -ArgumentList $smokeArgs -Wait -PassThru
if ($smokeInstall.ExitCode -ne 0) {
    $setupDetails = if (Test-Path -LiteralPath $smokeLog) { (Get-Content -LiteralPath $smokeLog -Tail 100) -join "`n" } else { 'Журнал Inno Setup не был создан.' }
    throw "Тестовая установка завершилась с кодом $($smokeInstall.ExitCode). Журнал Inno Setup:`n$setupDetails"
}

$installedLauncher = Join-Path $smokeDir 'runtime\Scripts\yandex-music-downloader.exe'
$installedPython = Join-Path $smokeDir 'runtime\python.exe'
$installedScript = Join-Path $smokeDir 'YandexMusicDownloader.ps1'
$installedInventory = Join-Path $smokeDir 'tools\source_inventory.py'
foreach ($requiredFile in @($installedLauncher,$installedPython,$installedScript,$installedInventory)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "После тестовой установки отсутствует обязательный файл: $requiredFile"
    }
}

$cliHelp = (& $installedLauncher --help 2>&1 | Out-String)
$launcherExit = $LASTEXITCODE
if ($launcherExit -ne 0 -or $cliHelp -notmatch '--token' -or $cliHelp -notmatch '--url') {
    throw "Тест встроенного CLI завершился с кодом $launcherExit или не вернул ожидаемые параметры --token/--url.\n$cliHelp"
}

$settingsFile = Join-Path (Join-Path $env:APPDATA 'YandexMusicDownloaderPlus') 'music-path.txt'
if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
    throw 'Тестовая установка не сохранила выбранную музыкальную папку в AppData.'
}
Write-Host 'Smoke test: установщик, встроенный Python, CLI launcher и настройка Music — OK.' -ForegroundColor Green
Remove-Item -LiteralPath $smokeDir -Recurse -Force
Remove-Item -LiteralPath $settingsFile -Force -ErrorAction SilentlyContinue

$hash = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($setupExe))" | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Готово: $setupExe" -ForegroundColor Green
Write-Host "SHA-256: $hash" -ForegroundColor Green
