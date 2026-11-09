param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\\artifacts\\output')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$payload = Join-Path $repoRoot 'artifacts\\payload'
$runtime = Join-Path $payload 'runtime'
$baseSite = Join-Path $runtime 'Lib\\site-packages'
$optionalSite = Join-Path $runtime 'Optional\\Lib\\site-packages'
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
    'Lib\\site-packages'
    'Optional\\Lib\\site-packages'
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

Push-Location (Join-Path $repoRoot 'tools\\launcher')
try {
    $env:GO111MODULE = 'on'
    go build -trimpath -ldflags='-s -w' -o (Join-Path $runtimeScripts 'yandex-music-downloader.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось собрать launcher.exe.' }
} finally {
    Pop-Location
    Remove-Item Env:\\GO111MODULE -ErrorAction SilentlyContinue
}

# Include only the files required by the Windows installer.
Copy-Item -LiteralPath (Join-Path $repoRoot 'YandexMusicDownloader.ps1') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repoRoot 'Запустить_загрузку.bat') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repoRoot 'ПРОЧТИ_МЕНЯ.txt') -Destination $payload
New-Item -ItemType Directory -Force -Path (Join-Path $payload 'tools') | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\\source_inventory.py') -Destination (Join-Path $payload 'tools')

$innosetupUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe'
$innosetupInstaller = Join-Path $env:RUNNER_TEMP 'innosetup-7.1.1-x64.exe'
Invoke-WebRequest -Uri $innosetupUrl -OutFile $innosetupInstaller
$signature = Get-AuthenticodeSignature -FilePath $innosetupInstaller
if ($signature.Status -ne 'Valid') { throw "Подпись установщика Inno Setup не прошла проверку: $($signature.Status)" }

$install = Start-Process -FilePath $innosetupInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-') -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "Установка Inno Setup завершилась с кодом $($install.ExitCode)." }

$isccCandidates = @(
    (Join-Path $env:ProgramFiles 'Inno Setup 7\\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\\ISCC.exe')
)
$iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iscc) { throw 'ISCC.exe Inno Setup 7 не найден после установки.' }

$installerScript = Join-Path $PSScriptRoot 'YandexMusicDownloaderPlus.iss'
& $iscc "/DPayloadDir=$payload" "/DOutputDir=$OutputDirectory" $installerScript
if ($LASTEXITCODE -ne 0) { throw "Компиляция установщика завершилась с кодом $LASTEXITCODE." }

$setupExe = Join-Path $OutputDirectory 'YandexMusicDownloaderPlus-Setup-0.2.0-preview.1.exe'
if (-not (Test-Path -LiteralPath $setupExe -PathType Leaf)) { throw "Итоговый EXE не найден: $setupExe" }
$hash = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($setupExe))" | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Готово: $setupExe" -ForegroundColor Green
Write-Host "SHA-256: $hash" -ForegroundColor Green
