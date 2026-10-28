#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaultExe = Join-Path $env:LOCALAPPDATA 'Python\pythoncore-3.14-64\Scripts\yandex-music-downloader.exe'
$defaultUrl = 'https://music.yandex.ru/playlists/lk.0ad9d4f5-d068-466f-9ddc-66cccbc68131'
$defaultDir = 'D:\Music'
$upstreamArchive = 'https://github.com/llistochek/yandex-music-downloader/archive/main.zip'

$script:exePath = $null
$script:helpText = ''
$script:outputDir = $null
$script:sourceUrl = $null
$script:token = $null
$script:logPath = $null
$script:timestamp = $null
$script:supportsSkipExisting = $false
$script:supportsEmbedCover = $false
$script:supportsLyrics = $false
$script:supportsDelay = $false
$script:supportsTimeout = $false
$script:supportsTries = $false
$script:supportsRetryDelay = $false
$script:supportsCoverResolution = $false
$script:supportsForceMp3 = $false
$script:supportsPathPattern = $false
$script:quality = '1'
$script:forceMp3 = $false
$script:formatName = 'AAC/M4A 192 kbps'
$script:delay = '0'
$script:lyricsChoice = '0'

# Use the native Windows DPAPI directly instead of importing Microsoft.PowerShell.Security.
# Data stays compatible with ConvertFrom-SecureString's default DPAPI hex format.
if (-not ('YandexMusicDownloaderPlus.DpapiTokenStore' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;

namespace YandexMusicDownloaderPlus
{
    public static class DpapiTokenStore
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct DATA_BLOB
        {
            public int cbData;
            public IntPtr pbData;
        }

        [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CryptProtectData(
            ref DATA_BLOB pDataIn, string szDataDescr, IntPtr pOptionalEntropy,
            IntPtr pvReserved, IntPtr pPromptStruct, uint dwFlags, out DATA_BLOB pDataOut);

        [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CryptUnprotectData(
            ref DATA_BLOB pDataIn, IntPtr ppszDataDescr, IntPtr pOptionalEntropy,
            IntPtr pvReserved, IntPtr pPromptStruct, uint dwFlags, out DATA_BLOB pDataOut);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr hMem);

        private const uint CRYPTPROTECT_UI_FORBIDDEN = 0x1;

        private static byte[] Transform(byte[] inputBytes, bool protect)
        {
            GCHandle pinned = new GCHandle();
            DATA_BLOB output = new DATA_BLOB();
            try
            {
                pinned = GCHandle.Alloc(inputBytes, GCHandleType.Pinned);
                DATA_BLOB input = new DATA_BLOB();
                input.cbData = inputBytes.Length;
                input.pbData = pinned.AddrOfPinnedObject();

                bool ok;
                if (protect)
                {
                    ok = CryptProtectData(ref input, String.Empty, IntPtr.Zero,
                        IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out output);
                }
                else
                {
                    ok = CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero,
                        IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out output);
                }

                if (!ok)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows DPAPI operation failed.");

                byte[] result = new byte[output.cbData];
                if (result.Length > 0)
                    Marshal.Copy(output.pbData, result, 0, result.Length);
                return result;
            }
            finally
            {
                if (output.pbData != IntPtr.Zero)
                {
                    if (output.cbData > 0)
                    {
                        byte[] zeros = new byte[output.cbData];
                        Marshal.Copy(zeros, 0, output.pbData, zeros.Length);
                    }
                    LocalFree(output.pbData);
                }

                if (pinned.IsAllocated)
                    pinned.Free();
            }
        }

        private static string ToHex(byte[] bytes)
        {
            return BitConverter.ToString(bytes).Replace("-", String.Empty).ToLowerInvariant();
        }

        private static byte[] FromHex(string hex)
        {
            if (String.IsNullOrWhiteSpace(hex) || (hex.Length % 2) != 0)
                throw new FormatException("The DPAPI token file is empty or malformed.");

            byte[] bytes = new byte[hex.Length / 2];
            for (int i = 0; i < bytes.Length; i++)
                bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            return bytes;
        }

        public static string ProtectSecureString(SecureString value)
        {
            if (value == null || value.Length == 0)
                throw new ArgumentException("Token is empty.", "value");

            byte[] clear = new byte[value.Length * 2];
            byte[] protectedBytes = null;
            IntPtr ptr = IntPtr.Zero;
            try
            {
                ptr = Marshal.SecureStringToCoTaskMemUnicode(value);
                Marshal.Copy(ptr, clear, 0, clear.Length);
                protectedBytes = Transform(clear, true);
                return ToHex(protectedBytes);
            }
            finally
            {
                if (ptr != IntPtr.Zero)
                    Marshal.ZeroFreeCoTaskMemUnicode(ptr);
                Array.Clear(clear, 0, clear.Length);
                if (protectedBytes != null)
                    Array.Clear(protectedBytes, 0, protectedBytes.Length);
            }
        }

        public static SecureString UnprotectToSecureString(string hex)
        {
            byte[] protectedBytes = null;
            byte[] clear = null;
            SecureString result = new SecureString();
            try
            {
                protectedBytes = FromHex(hex.Trim());
                clear = Transform(protectedBytes, false);
                if ((clear.Length % 2) != 0)
                    throw new CryptographicException("Decrypted DPAPI payload is not valid UTF-16 data.");

                for (int i = 0; i < clear.Length; i += 2)
                {
                    char ch = (char)(clear[i] | (clear[i + 1] << 8));
                    result.AppendChar(ch);
                }

                result.MakeReadOnly();
                return result;
            }
            catch
            {
                result.Dispose();
                throw;
            }
            finally
            {
                if (protectedBytes != null)
                    Array.Clear(protectedBytes, 0, protectedBytes.Length);
                if (clear != null)
                    Array.Clear(clear, 0, clear.Length);
            }
        }

        public static bool AreEqual(SecureString left, SecureString right)
        {
            if (left == null || right == null || left.Length != right.Length)
                return false;

            IntPtr leftPtr = IntPtr.Zero;
            IntPtr rightPtr = IntPtr.Zero;
            try
            {
                leftPtr = Marshal.SecureStringToCoTaskMemUnicode(left);
                rightPtr = Marshal.SecureStringToCoTaskMemUnicode(right);
                for (int i = 0; i < left.Length; i++)
                {
                    if (Marshal.ReadInt16(leftPtr, i * 2) != Marshal.ReadInt16(rightPtr, i * 2))
                        return false;
                }
                return true;
            }
            finally
            {
                if (leftPtr != IntPtr.Zero)
                    Marshal.ZeroFreeCoTaskMemUnicode(leftPtr);
                if (rightPtr != IntPtr.Zero)
                    Marshal.ZeroFreeCoTaskMemUnicode(rightPtr);
            }
        }
    }
}
'@ -ErrorAction Stop
}

function Read-DefaultText([string]$Prompt, [string]$DefaultValue) {
    $value = Read-Host "$Prompt [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }
    return $value.Trim()
}

function Read-MenuChoice([string]$Prompt, [string[]]$Choices, [string]$DefaultValue) {
    while ($true) {
        $value = Read-Host "$Prompt (по умолчанию $DefaultValue)"
        if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }
        $value = $value.Trim()
        if ($Choices -contains $value) { return $value }
        Write-Host ("Введи один из вариантов: " + ($Choices -join ', ')) -ForegroundColor Yellow
    }
}

function Test-SavedTokenStorage {
    $tokenPath = Join-Path (Join-Path $env:APPDATA 'YandexMusicDownloaderPlus') 'token.dpapi'
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        Write-Host "Сохранённый файл токена не найден: $tokenPath" -ForegroundColor Yellow
        Write-Host 'Этот тест не создаёт новый файл и не запрашивает токен.' -ForegroundColor DarkGray
        return
    }

    $testToken = $null
    try {
        $ciphertext = (Get-Content -LiteralPath $tokenPath -Raw -ErrorAction Stop).Trim()
        $testToken = [YandexMusicDownloaderPlus.DpapiTokenStore]::UnprotectToSecureString($ciphertext)
        if ($null -ne $testToken -and $testToken.Length -gt 0) {
            Write-Host 'УСПЕХ: сохранённый токен расшифрован Windows DPAPI.' -ForegroundColor Green
            Write-Host 'Значение токена не выводилось и не отправлялось в сеть.' -ForegroundColor DarkGray
            Write-Host 'Этот тест проверяет расшифровку файла, но не срок действия токена на стороне Яндекса.' -ForegroundColor Gray
        } else {
            Write-Host 'Файл расшифровался, но токен оказался пустым.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Не удалось расшифровать файл токена: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Файл не был удалён или перезаписан.' -ForegroundColor DarkGray
    } finally {
        if ($null -ne $testToken) { $testToken.Dispose() }
    }
}

function Test-SavedTokenRoundTrip {
    $tokenStoreDir = Join-Path $env:APPDATA 'YandexMusicDownloaderPlus'
    $tokenPath = Join-Path $tokenStoreDir 'token.dpapi'
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        Write-Host "Сохранённый файл токена не найден: $tokenPath" -ForegroundColor Yellow
        return
    }

    $tempPath = Join-Path $env:TEMP ("YandexMusicDownloaderPlus-roundtrip-" + [guid]::NewGuid().ToString('N') + '.dpapi')
    $originalToken = $null
    $roundTripToken = $null
    try {
        $storedCiphertext = [System.IO.File]::ReadAllText($tokenPath, [System.Text.Encoding]::ASCII).Trim()
        $originalToken = [YandexMusicDownloaderPlus.DpapiTokenStore]::UnprotectToSecureString($storedCiphertext)

        $tempCiphertext = [YandexMusicDownloaderPlus.DpapiTokenStore]::ProtectSecureString($originalToken)
        [System.IO.File]::WriteAllText($tempPath, $tempCiphertext, [System.Text.Encoding]::ASCII)

        $reloadedCiphertext = [System.IO.File]::ReadAllText($tempPath, [System.Text.Encoding]::ASCII).Trim()
        $roundTripToken = [YandexMusicDownloaderPlus.DpapiTokenStore]::UnprotectToSecureString($reloadedCiphertext)

        if ([YandexMusicDownloaderPlus.DpapiTokenStore]::AreEqual($originalToken, $roundTripToken)) {
            Write-Host 'УСПЕХ: токен расшифрован, повторно зашифрован во временный файл и снова расшифрован; значения совпадают.' -ForegroundColor Green
            Write-Host 'Исходный token.dpapi не изменён. Токен не выводился и не отправлялся в сеть.' -ForegroundColor DarkGray
        } else {
            throw 'Токен после повторного шифрования и расшифровки не совпал с исходным.'
        }
    } catch {
        Write-Host "Проверка шифрования и повторной расшифровки не пройдена: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Исходный файл token.dpapi не изменялся.' -ForegroundColor DarkGray
    } finally {
        if ($null -ne $originalToken) { $originalToken.Dispose() }
        if ($null -ne $roundTripToken) { $roundTripToken.Dispose() }
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Find-Downloader([string]$PreferredPath) {
    if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath -PathType Leaf)) {
        return $PreferredPath
    }
    $cmd = Get-Command 'yandex-music-downloader.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    $cmd = Get-Command 'yandex-music-downloader' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    return $null
}

function Find-PythonForDownloader([string]$ExecutablePath, [string]$FallbackExecutablePath) {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($ExecutablePath, $FallbackExecutablePath)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
            $scriptsDir = Split-Path -Parent $path
            $pythonRoot = Split-Path -Parent $scriptsDir
            $candidate = Join-Path $pythonRoot 'python.exe'
            if (-not $candidates.Contains($candidate)) { [void]$candidates.Add($candidate) }
        } catch { }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $cmd = Get-Command 'python.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    return $null
}

function Get-DownloaderHelp([string]$ExecutablePath) {
    try {
        $text = (& $ExecutablePath --help 2>&1 | Out-String)
        return $text
    } catch {
        return ''
    }
}

function Update-Downloader([string]$ExecutablePath) {
    $pythonExe = Find-PythonForDownloader -ExecutablePath $ExecutablePath -FallbackExecutablePath $defaultExe
    if ([string]::IsNullOrWhiteSpace($pythonExe)) {
        Write-Host 'Не найден python.exe, связанный с загрузчиком. Автообновление отменено.' -ForegroundColor Red
        Write-Host 'Обнови пакет вручную по инструкции из ПРОЧТИ_МЕНЯ.txt.' -ForegroundColor Yellow
        return $false
    }

    Write-Host ''
    Write-Host "Python: $pythonExe" -ForegroundColor DarkGray
    Write-Host 'Будет установлен текущий код из официального репозитория разработчика загрузчика.' -ForegroundColor Yellow
    Write-Host 'Загрузка файлов при этом не начинается.'
    Write-Host ''
    & $pythonExe -m pip install --upgrade $upstreamArchive
    $updateExitCode = $LASTEXITCODE
    if ($updateExitCode -ne 0) {
        Write-Host "Обновление завершилось с кодом $updateExitCode." -ForegroundColor Red
        return $false
    }

    Write-Host 'Обновление пакета завершено.' -ForegroundColor Green
    return $true
}

function Get-FormatLabel([string]$QualityValue, [bool]$Mp3) {
    if ($Mp3) { return 'MP3 (перекодирование поддерживаемой версией загрузчика)' }
    if ($QualityValue -eq '2') { return 'FLAC (если доступен для трека и аккаунта)' }
    if ($QualityValue -eq '1') { return 'AAC/M4A 192 kbps' }
    return 'AAC/M4A 64 kbps'
}

function Invoke-DownloadPass([string]$PassName, [string]$QualityValue) {
    $cliArgs = @('--token', $script:token, '--quality', $QualityValue, '--url', $script:sourceUrl, '--dir', $script:outputDir)

    # Это ключевое условие: каждый запуск, включая повторные, пропускает уже имеющиеся файлы.
    if ($script:supportsSkipExisting) { $cliArgs += '--skip-existing' }
    if ($script:supportsEmbedCover) { $cliArgs += '--embed-cover' }
    if ($script:supportsCoverResolution) { $cliArgs += @('--cover-resolution', '400') }
    # Явно фиксируем шаблон, совпадающий с текущим default ymd, чтобы --skip-existing
    # продолжал узнавать файлы из предыдущих запусков этого загрузчика.
    if ($script:supportsPathPattern) { $cliArgs += @('--path-pattern', '#album-artist/#album/#number - #title') }
    if ($script:supportsDelay) { $cliArgs += @('--delay', $script:delay) }
    if ($script:supportsTimeout) { $cliArgs += @('--timeout', '30') }
    if ($script:supportsTries) { $cliArgs += @('--tries', '20') }
    if ($script:supportsRetryDelay) { $cliArgs += @('--retry-delay', '3') }
    if ($script:supportsLyrics) {
        switch ($script:lyricsChoice) {
            '1' { $cliArgs += @('--lyrics-format', 'text') }
            '2' { $cliArgs += @('--lyrics-format', 'lrc') }
            default { $cliArgs += @('--lyrics-format', 'none') }
        }
    }
    if ($script:forceMp3 -and $script:supportsForceMp3) { $cliArgs += '--force-mp3' }

    "`r`n================ $PassName ================" | Out-File -FilePath $script:logPath -Encoding utf8 -Append
    "Качество прохода: $(Get-FormatLabel -QualityValue $QualityValue -Mp3 $script:forceMp3)" | Out-File -FilePath $script:logPath -Encoding utf8 -Append
    "URL прохода: $($script:sourceUrl)" | Out-File -FilePath $script:logPath -Encoding utf8 -Append

    Write-Host ''
    Write-Host "--- $PassName ---" -ForegroundColor Cyan
    Write-Host "Качество прохода: $(Get-FormatLabel -QualityValue $QualityValue -Mp3 $script:forceMp3)" -ForegroundColor DarkGray
    Write-Host 'Новые треки будут отображаться ниже по мере обработки. Уже существующие файлы загрузчик пропускает молча.' -ForegroundColor DarkGray
    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    $global:LASTEXITCODE = 0

    & $script:exePath @cliArgs 2>&1 | ForEach-Object {
        $line = [string]$_
        [void]$outputLines.Add($line)
        Write-Host $line
        Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8
    }
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Text = ($outputLines -join "`n")
    }
}

function Get-UnavailableTrackEntries([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $currentPass = ''
    # Known output observed in live runs:
    # [1866/6737] Трек Didier Marouani, Space - Just Blue не доступен для скачивания
    $pattern = '(?i)^\s*\[(?<Index>\d+)\s*/\s*(?<Total>\d+)\]\s*(?:Трек\s+)?(?<Track>.+?)\s+(?<Message>не\s+доступен\s+для\s+скачивания|недоступен\s+для\s+скачивания|недоступна\s+для\s+скачивания|недоступно\s+для\s+скачивания|not\s+available\s+for\s+download|unavailable\s+for\s+download)\s*$'

    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        if ($line -match '^\s*=+\s*(?<Pass>.+?)\s*=+\s*$') {
            $currentPass = $Matches['Pass'].Trim()
            continue
        }
        if ($line -match $pattern) {
            [void]$entries.Add([pscustomobject]@{
                TrackIndex    = [int]$Matches['Index']
                PlaylistTotal = [int]$Matches['Total']
                Track         = $Matches['Track'].Trim()
                Message       = $line.Trim()
                Pass          = $currentPass
            })
        }
    }
    return @($entries.ToArray())
}

function Get-ErrorLines([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $pattern = '(?i)(Traceback|Unhandled exception|\bException\b|^\s*(?:ERROR|FATAL)\b|ошиб(?:ка|ки|ок)|не удалось|невозможно|недоступ|smart_preview|preview stream|\bfailed\b|HTTP\s+(?:403|404|429|5\d\d))'
    $knownUnavailablePattern = '(?i)(?:не\s+доступен|недоступен|недоступна|недоступно)\s+для\s+скачивания|not\s+available\s+for\s+download|unavailable\s+for\s+download'
    $lines = [regex]::Split($Text, '\r?\n')
    $errorLinesFound = @($lines | Where-Object {
        ($_ -match $pattern) -and
        ($_ -notmatch $knownUnavailablePattern) -and
        ($_ -notmatch '(?i)\b0\s+failed\b|(?:ошибок|ошибки)\s*[:=]?\s*0')
    })
    return $errorLinesFound
}

function Show-RunEnding([string]$Text, [int]$ExitCode) {
    $errorLines = @(Get-ErrorLines -Text $Text)
    $unavailableEntries = @(Get-UnavailableTrackEntries -Text $Text)

    if ($ExitCode -ne 0 -or $errorLines.Count -gt 0) {
        Write-Host "Возможные ошибки обнаружены (код завершения: $ExitCode; строк с другими диагностическими признаками: $($errorLines.Count))." -ForegroundColor Yellow
        if ($unavailableEntries.Count -gt 0) {
            Write-Host "Дополнительно загрузчик сообщил о недоступности $($unavailableEntries.Count) треков. Они будут внесены в отдельный CSV-отчёт." -ForegroundColor Yellow
        }
        Write-Host 'Не каждая диагностическая строка означает сбой всего прохода; полный лог сохранён.' -ForegroundColor DarkGray
    } elseif ($unavailableEntries.Count -gt 0) {
        Write-Host "Проход завершён, но загрузчик сообщил о недоступности $($unavailableEntries.Count) треков. Они не считаются успешно скачанными." -ForegroundColor Yellow
        Write-Host 'Список недоступных треков будет сохранён в CSV-отчёт.' -ForegroundColor DarkGray
    } else {
        Write-Host 'Загрузчик завершил проход без обнаруженных по тексту ошибок.' -ForegroundColor Green
    }

    # Return only actionable/general errors. Unavailable tracks are recorded separately
    # and do not by themselves trigger an automatic retry of the entire playlist.
    return ($ExitCode -ne 0 -or $errorLines.Count -gt 0)
}


function Get-UnavailableTrackSummary([object[]]$Entries) {
    if ($null -eq $Entries -or $Entries.Count -eq 0) { return @() }
    return @(
        $Entries |
            Group-Object -Property { '{0}/{1}|{2}' -f $_.TrackIndex, $_.PlaylistTotal, $_.Track } |
            ForEach-Object {
                $entryGroup = $_
                $firstEntry = $entryGroup.Group[0]
                [pscustomobject]@{
                    TrackIndex    = $firstEntry.TrackIndex
                    PlaylistTotal = $firstEntry.PlaylistTotal
                    Track         = $firstEntry.Track
                    Attempts      = $entryGroup.Count
                    Passes        = (($entryGroup.Group | Select-Object -ExpandProperty Pass -Unique) -join '; ')
                    Messages      = (($entryGroup.Group | Select-Object -ExpandProperty Message -Unique) -join ' | ')
                }
            } |
            Sort-Object TrackIndex, Track
    )
}

function Invoke-AnalyzeExistingLog {
    $logsDir = Join-Path $scriptRoot 'logs'
    if (-not (Test-Path -LiteralPath $logsDir -PathType Container)) {
        Write-Host "Папка журналов не найдена: $logsDir" -ForegroundColor Red
        return
    }

    $latestLog = Get-ChildItem -LiteralPath $logsDir -Filter 'download-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latestLog) {
        Write-Host "В папке $logsDir не найдено файлов download-*.log." -ForegroundColor Red
        return
    }

    Write-Host ''
    Write-Host 'АНАЛИЗ СУЩЕСТВУЮЩЕГО ЖУРНАЛА — БЕЗ ЗАГРУЗКИ МУЗЫКИ' -ForegroundColor Cyan
    $logPath = Read-DefaultText 'Путь к журналу для анализа' $latestLog.FullName
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        Write-Host "Файл не найден: $logPath" -ForegroundColor Red
        return
    }

    $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop
    $entries = @(Get-UnavailableTrackEntries -Text $logText)
    $unavailableSummary = @(Get-UnavailableTrackSummary -Entries $entries)
    $otherErrors = @(Get-ErrorLines -Text $logText)
    $analysisTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvPath = Join-Path $logsDir "unavailable-analysis-$analysisTimestamp.csv"
    $reportPath = Join-Path $logsDir "errors-analysis-$analysisTimestamp.txt"

    if ($unavailableSummary.Count -gt 0) {
        $unavailableSummary | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Недоступных уникальных позиций плейлиста: $($unavailableSummary.Count)" -ForegroundColor Yellow
        Write-Host "CSV: $csvPath" -ForegroundColor Yellow
    } else {
        Write-Host 'Строк о недоступных треках не обнаружено.' -ForegroundColor Green
    }

    Write-Host "Других диагностических строк: $($otherErrors.Count)"
    $reportLines = New-Object 'System.Collections.Generic.List[string]'
    [void]$reportLines.Add('Сводка анализа существующего журнала; скачивание не запускалось.')
    [void]$reportLines.Add("Исходный лог: $logPath")
    [void]$reportLines.Add("Недоступных уникальных позиций плейлиста: $($unavailableSummary.Count)")
    [void]$reportLines.Add("Других строк с диагностическими признаками: $($otherErrors.Count)")
    if ($unavailableSummary.Count -gt 0) { [void]$reportLines.Add("CSV недоступных треков: $csvPath") }
    foreach ($errorLine in $otherErrors) { [void]$reportLines.Add([string]$errorLine) }
    $reportLines | Out-File -FilePath $reportPath -Encoding utf8
    Write-Host "Сводка: $reportPath" -ForegroundColor DarkGray
}

function Invoke-AlternativeTrack {
    Write-Host ''
    Write-Host 'РЕЗЕРВНЫЙ ЗАГРУЗЧИК ДЛЯ ОДНОГО ПРОБЛЕМНОГО ТРЕКА' -ForegroundColor Cyan
    Write-Host 'Используется yt-dlp + актуальный плагин Yandex Music; авторизация берётся из браузерной сессии.' -ForegroundColor Gray
    Write-Host 'Файл будет помещён в отдельную папку _YandexMusic_Fallback, а не смешан с библиотекой автоматически.' -ForegroundColor Yellow
    Write-Host 'Это позволяет проверить полную длительность и не создать незаметный дубликат в D:\Music.' -ForegroundColor Gray
    Write-Host ''

    $trackUrl = Read-Host 'Прямая ссылка на ОДИН трек (пример: /album/123/track/456)'
    if ([string]::IsNullOrWhiteSpace($trackUrl) -or $trackUrl -notmatch '^https?://music\.yandex\.(ru|com)/album/\d+/track/\d+') {
        Write-Host 'Нужна прямая ссылка вида https://music.yandex.ru/album/123/track/456. Загрузка отменена.' -ForegroundColor Red
        return
    }

    Write-Host ''
    Write-Host 'Выбери браузер, в котором Яндекс Музыка открывается с действующей авторизацией:'
    Write-Host '  1 — Chrome'
    Write-Host '  2 — Edge'
    Write-Host '  3 — Firefox'
    Write-Host '  4 — Brave'
    $browserChoice = Read-MenuChoice 'Браузер' @('1','2','3','4') '1'
    $browser = switch ($browserChoice) {
        '1' { 'chrome' }
        '2' { 'edge' }
        '3' { 'firefox' }
        '4' { 'brave' }
    }

    $preferred = Find-Downloader -PreferredPath $defaultExe
    $pythonExe = Find-PythonForDownloader -ExecutablePath $preferred -FallbackExecutablePath $defaultExe
    if ([string]::IsNullOrWhiteSpace($pythonExe) -or -not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        $pythonCmd = Get-Command 'python.exe' -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $pythonCmd) { $pythonExe = $pythonCmd.Source }
    }
    if ([string]::IsNullOrWhiteSpace($pythonExe) -or -not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        Write-Host 'Не найден python.exe. Установи Python 3.9+ и запусти команду повторно.' -ForegroundColor Red
        return
    }

    Write-Host ''
    Write-Host "Python: $pythonExe" -ForegroundColor DarkGray
    Write-Host 'Проверяю/устанавливаю yt-dlp и плагин. Токен из основного режима здесь не используется.' -ForegroundColor Gray
    & $pythonExe -m pip install --upgrade 'yt-dlp[default]' yt-dlp-yandex-music
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Не удалось установить резервный backend. Подробности показаны выше.' -ForegroundColor Red
        return
    }

    $mainDir = Read-DefaultText 'Корневая музыкальная папка' $defaultDir
    $fallbackDir = Join-Path $mainDir '_YandexMusic_Fallback'
    New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fallbackLogDir = Join-Path $scriptRoot 'logs'
    New-Item -ItemType Directory -Path $fallbackLogDir -Force | Out-Null
    $fallbackLog = Join-Path $fallbackLogDir "fallback-$timestamp.log"
    $archivePath = Join-Path $fallbackDir 'download-archive.txt'
    $outputPattern = Join-Path $fallbackDir '%(artist,creator,uploader)s - %(title)s.%(ext)s'

    @(
        "Начало резервного прохода: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "URL трека: $trackUrl"
        "Браузер-сессия: $browser"
        "Папка staging: $fallbackDir"
        'Cookies и токены в лог не записываются.'
    ) | Out-File -FilePath $fallbackLog -Encoding utf8

    Write-Host ''
    Write-Host "Папка для проверки: $fallbackDir" -ForegroundColor Cyan
    Write-Host 'Не закрывай браузер, если браузерная сессия не извлекается. При запросе входа проверь, что аккаунт имеет право на полное воспроизведение.' -ForegroundColor Gray
    Write-Host 'Если плагин сообщит smart_preview/короткий preview, не заменяй им полный трек.' -ForegroundColor Yellow

    $ytArgs = @(
        '-m', 'yt_dlp',
        '--cookies-from-browser', $browser,
        '--download-archive', $archivePath,
        '--no-overwrites',
        '--embed-metadata',
        '--embed-thumbnail',
        '--output', $outputPattern,
        $trackUrl
    )

    & $pythonExe @ytArgs 2>&1 | ForEach-Object {
        $line = [string]$_
        Write-Host $line
        Add-Content -LiteralPath $fallbackLog -Value $line -Encoding UTF8
    }
    $exitCode = $LASTEXITCODE

    Write-Host ''
    if ($exitCode -eq 0) {
        Write-Host 'Резервный проход завершился. Открой файл из _YandexMusic_Fallback и проверь длительность/воспроизведение перед перемещением в библиотеку.' -ForegroundColor Green
    } else {
        Write-Host "Резервный backend завершился с кодом $exitCode. Смотри лог: $fallbackLog" -ForegroundColor Yellow
        Write-Host 'Этот способ требует свежую авторизацию в браузере и не гарантирует доступность каждого трека.' -ForegroundColor Gray
    }
    Write-Host "Лог: $fallbackLog" -ForegroundColor DarkGray
}

# UTF-8 нужен, чтобы названия с диакритикой и необычными символами не роняли Python в Windows.
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
# Important: the downloader's per-track print() output is piped through PowerShell
# for live display and logging. Without unbuffered Python output, lines can stay in
# a buffer and appear only after the whole pass has finished.
$env:PYTHONUNBUFFERED = '1'

Clear-Host
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '   Яндекс Музыка — Downloader Plus' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host 'Токен вводится скрыто; сохранение использует Windows DPAPI и не требует модуля Microsoft.PowerShell.Security.' -ForegroundColor Gray
Write-Host ''
Write-Host 'Режим:'
Write-Host '  1 — скачать музыку (обычный режим)'
Write-Host '  2 — обновить загрузчик и выйти'
Write-Host '  3 — обновить загрузчик и затем начать скачивание'
Write-Host '  4 — попробовать резервный источник для одного проблемного трека (yt-dlp + сессия браузера)'
Write-Host '  5 — создать отчёт по недоступным трекам из существующего лога (без скачивания)'
Write-Host '  6 — проверить расшифровку сохранённого токена (без загрузки и без вывода токена)'
Write-Host '  7 — проверить шифрование и повторную расшифровку токена (без сети и без изменения сохранённого файла)'
Write-Host '  0 — выход'
$actionChoice = Read-MenuChoice 'Выбор' @('0','1','2','3','4','5','6','7') '1'
if ($actionChoice -eq '0') { exit 0 }
if ($actionChoice -eq '4') {
    Invoke-AlternativeTrack
    Read-Host 'Нажми Enter для выхода' | Out-Null
    exit 0
}
if ($actionChoice -eq '5') {
    Invoke-AnalyzeExistingLog
    Read-Host 'Нажми Enter для выхода' | Out-Null
    exit 0
}
if ($actionChoice -eq '6') {
    Test-SavedTokenStorage
    Read-Host 'Нажми Enter для выхода' | Out-Null
    exit 0
}
if ($actionChoice -eq '7') {
    Test-SavedTokenRoundTrip
    Read-Host 'Нажми Enter для выхода' | Out-Null
    exit 0
}

$script:exePath = Find-Downloader -PreferredPath $defaultExe
if ($actionChoice -eq '2' -or $actionChoice -eq '3') {
    $updated = Update-Downloader -ExecutablePath $script:exePath
    if (-not $updated) {
        Read-Host 'Нажми Enter для выхода' | Out-Null
        exit 1
    }
    if ($actionChoice -eq '2') {
        Read-Host 'Обновление завершено. Нажми Enter для выхода' | Out-Null
        exit 0
    }
    $script:exePath = Find-Downloader -PreferredPath $defaultExe
}

if ([string]::IsNullOrWhiteSpace($script:exePath) -or -not (Test-Path -LiteralPath $script:exePath -PathType Leaf)) {
    Write-Host 'Не удалось найти yandex-music-downloader.exe.' -ForegroundColor Red
    Write-Host "Ожидаемый исходный путь: $defaultExe"
    Write-Host 'Попробуй сначала пункт 2 (обновить загрузчик) или поправь $defaultExe в начале файла.'
    Read-Host 'Нажми Enter для выхода' | Out-Null
    exit 1
}

$script:helpText = Get-DownloaderHelp -ExecutablePath $script:exePath
$script:supportsSkipExisting = $script:helpText -match '--skip-existing'
$script:supportsEmbedCover = $script:helpText -match '--embed-cover'
$script:supportsLyrics = $script:helpText -match '--lyrics-format'
$script:supportsDelay = $script:helpText -match '--delay'
$script:supportsTimeout = $script:helpText -match '--timeout'
$script:supportsTries = $script:helpText -match '--tries'
$script:supportsRetryDelay = $script:helpText -match '--retry-delay'
$script:supportsCoverResolution = $script:helpText -match '--cover-resolution'
$script:supportsForceMp3 = $script:helpText -match '--force-mp3'
$script:supportsPathPattern = $script:helpText -match '--path-pattern'
$supportsQuality = $script:helpText -match '--quality'
$supportsUrl = $script:helpText -match '--url'
$supportsToken = $script:helpText -match '--token'
$supportsDir = $script:helpText -match '--dir'

Write-Host ''
Write-Host "Загрузчик: $($script:exePath)" -ForegroundColor DarkGray
if (-not $supportsSkipExisting) {
    Write-Host 'В установленной версии не найден --skip-existing.' -ForegroundColor Red
    Write-Host 'Чтобы не нарушить главное условие (не скачивать дубликаты), запуск отменён. Обнови загрузчик через пункт 2.' -ForegroundColor Yellow
    Read-Host 'Нажми Enter для выхода' | Out-Null
    exit 2
}
if (-not ($supportsQuality -and $supportsUrl -and $supportsToken -and $supportsDir)) {
    Write-Host 'Установленная версия не поддерживает необходимые параметры --quality, --url, --token и/или --dir.' -ForegroundColor Red
    Write-Host 'Обнови загрузчик через пункт 2 и попробуй снова.' -ForegroundColor Yellow
    Read-Host 'Нажми Enter для выхода' | Out-Null
    exit 2
}

Write-Host ''
$sourceUrl = Read-DefaultText 'Ссылка на плейлист/альбом/исполнителя/отдельный трек' $defaultUrl
$script:sourceUrl = $sourceUrl
$script:outputDir = Read-DefaultText 'Папка для сохранения' $defaultDir

Write-Host ''
Write-Host 'Выбор качества/формата:' -ForegroundColor Cyan
if ($script:supportsForceMp3) {
    Write-Host '  1 — MP3 (только если поддерживается установленной версией)'
    Write-Host '  2 — AAC/M4A 192 кбит/с (как в исходной команде, без повторного перекодирования)'
    Write-Host '  3 — FLAC (если lossless доступен для трека и аккаунта)'
    $formatChoice = Read-MenuChoice 'Формат' @('1','2','3') '2'
    switch ($formatChoice) {
        '1' { $script:quality = '1'; $script:forceMp3 = $true;  $script:formatName = 'MP3' }
        '2' { $script:quality = '1'; $script:forceMp3 = $false; $script:formatName = 'AAC/M4A 192 kbps' }
        '3' { $script:quality = '2'; $script:forceMp3 = $false; $script:formatName = 'FLAC' }
    }
} else {
    Write-Host '  1 — AAC/M4A 192 кбит/с (как в исходной команде)'
    Write-Host '  2 — FLAC (если lossless доступен для трека и аккаунта)'
    Write-Host '  (Установленная версия не предоставляет --force-mp3; MP3 не будет выдаваться за исходный формат.)' -ForegroundColor DarkYellow
    $formatChoice = Read-MenuChoice 'Формат' @('1','2') '1'
    switch ($formatChoice) {
        '1' { $script:quality = '1'; $script:forceMp3 = $false; $script:formatName = 'AAC/M4A 192 kbps' }
        '2' { $script:quality = '2'; $script:forceMp3 = $false; $script:formatName = 'FLAC' }
    }
}

$script:lyricsChoice = '0'
if ($script:supportsLyrics) {
    Write-Host ''
    Write-Host 'Тексты песен:'
    Write-Host '  0 — не скачивать'
    Write-Host '  1 — текст в тегах'
    Write-Host '  2 — отдельные LRC-файлы с временными метками'
    $script:lyricsChoice = Read-MenuChoice 'Тексты' @('0','1','2') '0'
}

$script:delay = '0'
if ($script:supportsDelay) {
    Write-Host ''
    Write-Host 'Задержка между запросами: 0 — быстрее; 1 — осторожнее при ограничениях API.'
    $script:delay = Read-MenuChoice 'Задержка в секундах' @('0','1') '0'
}

# Persistent token storage: Windows DPAPI, bound to the current Windows user profile.
# The token is encrypted at rest and never written in plaintext to the script or logs.
$tokenStoreDir = Join-Path $env:APPDATA 'YandexMusicDownloaderPlus'
$tokenStorePath = Join-Path $tokenStoreDir 'token.dpapi'
$secureToken = $null
$tokenPtr = [IntPtr]::Zero
$script:token = $null
$useSavedToken = $false

if (Test-Path -LiteralPath $tokenStorePath -PathType Leaf) {
    try {
        $storedCiphertext = (Get-Content -LiteralPath $tokenStorePath -Raw -ErrorAction Stop).Trim()
        if ([string]::IsNullOrWhiteSpace($storedCiphertext)) {
            throw 'Файл сохранённого токена пуст.'
        }
        $candidateToken = [YandexMusicDownloaderPlus.DpapiTokenStore]::UnprotectToSecureString($storedCiphertext)
        Write-Host ''
        Write-Host 'Найден сохранённый токен, зашифрованный для текущего пользователя Windows.' -ForegroundColor Cyan
        $savedTokenChoice = Read-Host 'Enter — использовать его; N — ввести новый; D — удалить сохранённый и ввести новый [Enter/N/D]'
        if ([string]::IsNullOrWhiteSpace($savedTokenChoice) -or $savedTokenChoice -match '^(?i:y|yes|д|да)$') {
            $secureToken = $candidateToken
            $useSavedToken = $true
            Write-Host 'Используется сохранённый токен.' -ForegroundColor Green
        } else {
            $candidateToken.Dispose()
            if ($savedTokenChoice -match '^(?i:d|delete|удалить)$') {
                Remove-Item -LiteralPath $tokenStorePath -Force -ErrorAction Stop
                Write-Host 'Сохранённый токен удалён.' -ForegroundColor Yellow
            } else {
                Write-Host 'Будет запрошен новый токен.' -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Host "Не удалось расшифровать сохранённый токен через Windows DPAPI: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'Введи токен заново. При сохранении файл будет заменён.' -ForegroundColor DarkGray
    }
}

if (-not $useSavedToken) {
    $secureToken = Read-Host 'Вставь токен Яндекс Музыки (ввод скрыт)' -AsSecureString
    if ($secureToken.Length -eq 0) {
        Write-Host 'Токен не введён. Загрузка отменена.' -ForegroundColor Red
        Read-Host 'Нажми Enter для выхода' | Out-Null
        exit 1
    }

    $saveChoice = Read-Host 'Сохранить токен зашифрованным для следующих запусков этого пользователя Windows? [Y/n]'
    $saveToken = [string]::IsNullOrWhiteSpace($saveChoice) -or $saveChoice -match '^(?i:y|yes|д|да)$'
    if ($saveToken) {
        try {
            New-Item -ItemType Directory -Path $tokenStoreDir -Force -ErrorAction Stop | Out-Null
            $encryptedToken = [YandexMusicDownloaderPlus.DpapiTokenStore]::ProtectSecureString($secureToken)
            Set-Content -LiteralPath $tokenStorePath -Value $encryptedToken -Encoding ASCII -ErrorAction Stop
            Write-Host "Токен сохранён в зашифрованном виде: $tokenStorePath" -ForegroundColor Green
            Write-Host 'Он не хранится в открытом виде в папке проекта или журнале.' -ForegroundColor DarkGray
        } catch {
            Write-Host "Не удалось сохранить токен через Windows DPAPI: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host 'Продолжаю работу без сохранения токена.' -ForegroundColor DarkGray
        }
    } else {
        # Avoid accidentally reusing an old saved token if user opts not to store the new one.
        if (Test-Path -LiteralPath $tokenStorePath -PathType Leaf) {
            Remove-Item -LiteralPath $tokenStorePath -Force -ErrorAction SilentlyContinue
        }
        Write-Host 'Токен останется только в памяти текущего запуска.' -ForegroundColor DarkGray
    }
}

$tokenPtr = [IntPtr]::Zero
try {
    $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $script:token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr)

    if (-not (Test-Path -LiteralPath $script:outputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:outputDir -Force | Out-Null
    }
    $logsDir = Join-Path $scriptRoot 'logs'
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    $script:timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:logPath = Join-Path $logsDir "download-$($script:timestamp).log"

    @(
        "Начало: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Формат: $($script:formatName)"
        "Ссылка: $($script:sourceUrl)"
        "Папка: $($script:outputDir)"
        "Загрузчик: $($script:exePath)"
        'Режим пропуска существующих файлов: включён'
        'Токен намеренно не записывается в лог.'
    ) | Out-File -FilePath $script:logPath -Encoding utf8

    Write-Host ''
    Write-Host "Формат: $($script:formatName)" -ForegroundColor Green
    Write-Host "Папка:  $($script:outputDir)"
    Write-Host "Лог:    $($script:logPath)"
    Write-Host 'Уже существующие треки будут пропускаться. Повторные проходы используют тот же механизм защиты от дубликатов.' -ForegroundColor Cyan
    Write-Host 'Для остановки нажми Ctrl+C. Токен передаётся загрузчику как аргумент командной строки и поэтому может быть виден локальным средствам просмотра процессов.' -ForegroundColor DarkGray

    $firstPass = Invoke-DownloadPass -PassName 'ПРОХОД 1' -QualityValue $script:quality
    $hasErrors = Show-RunEnding -Text $firstPass.Text -ExitCode $firstPass.ExitCode
    $lastPass = $firstPass

    if ($hasErrors -and $script:supportsSkipExisting -and $script:sourceUrl -match '/playlists/lk\.' -and $firstPass.Text -match '(?i)playlist-not-found|NotFoundError') {
        Write-Host ''
        Write-Host 'Похоже, текущая версия загрузчика не распознала современную ссылку вида /playlists/lk.…' -ForegroundColor Yellow
        Write-Host 'В репозитории загрузчика описывался похожий сбой. Можно попробовать привычный адрес избранного по логину: /users/ЛОГИН/playlists/3.' -ForegroundColor Gray
        $retryLogin = Read-Host 'Логин Яндекса (Enter — пропустить этот способ)'
        if (-not [string]::IsNullOrWhiteSpace($retryLogin)) {
            $safeLogin = $retryLogin.Trim()
            if ($safeLogin -match '^[A-Za-z0-9._-]+$') {
                $oldSourceUrl = $script:sourceUrl
                $script:sourceUrl = "https://music.yandex.ru/users/$safeLogin/playlists/3"
                "Альтернативный URL после playlist-not-found: $($script:sourceUrl)" | Out-File -FilePath $script:logPath -Encoding utf8 -Append
                $lastPass = Invoke-DownloadPass -PassName 'ПОВТОР ПО USER/PLAYLISTS/3' -QualityValue $script:quality
                $hasErrors = Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode
                if ($hasErrors) { $script:sourceUrl = $oldSourceUrl }
            } else {
                Write-Host 'Логин содержит неподдерживаемые символы. Повтор не выполнялся.' -ForegroundColor Yellow
            }
        }
    }

    if ($hasErrors -and $script:supportsSkipExisting -and -not ($firstPass.Text -match '(?i)playlist-not-found|NotFoundError')) {
        Write-Host ''
        Write-Host 'Возможные ошибки: можно повторить загрузку. Успешно сохранённые файлы должны пропускаться через --skip-existing.' -ForegroundColor Yellow
        if ($script:quality -eq '2') {
            Write-Host '  0 — закончить'
            Write-Host '  1 — повторить в FLAC'
            Write-Host '  2 — повторить в AAC/M4A 192 кбит/с (может помочь, если FLAC недоступен)'
            $retryChoice = Read-MenuChoice 'Повторный проход' @('0','1','2') '1'
            if ($retryChoice -eq '1') {
                $lastPass = Invoke-DownloadPass -PassName 'ПОВТОР FLAC' -QualityValue '2'
                $stillErrors = Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode
                if ($stillErrors) {
                    $fallbackChoice = Read-MenuChoice 'Остались ошибки. Попробовать AAC/M4A 192 кбит/с для ещё не скачанных треков? (1 — да, 0 — нет)' @('0','1') '1'
                    if ($fallbackChoice -eq '1') {
                        $lastPass = Invoke-DownloadPass -PassName 'РЕЗЕРВНЫЙ ПРОХОД AAC/M4A 192' -QualityValue '1'
                        [void](Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode)
                    }
                }
            } elseif ($retryChoice -eq '2') {
                $lastPass = Invoke-DownloadPass -PassName 'РЕЗЕРВНЫЙ ПРОХОД AAC/M4A 192' -QualityValue '1'
                [void](Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode)
            }
        } else {
            $retryChoice = Read-MenuChoice 'Повторить один раз в том же качестве? (0 — нет, 1 — да)' @('0','1') '1'
            if ($retryChoice -eq '1') {
                $lastPass = Invoke-DownloadPass -PassName 'ПОВТОРНЫЙ ПРОХОД' -QualityValue $script:quality
                [void](Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode)
            }
        }
    }

    $allLogText = Get-Content -LiteralPath $script:logPath -Raw -ErrorAction SilentlyContinue
    $otherErrorSummary = @(Get-ErrorLines -Text $allLogText)
    $allUnavailableEntries = @(Get-UnavailableTrackEntries -Text $allLogText)

    # Retries can repeat the same unavailable message. Keep one CSV row per playlist
    # position + displayed track, and preserve how many attempts reported it.
    $unavailableSummary = @(Get-UnavailableTrackSummary -Entries $allUnavailableEntries)

    $errorReportPath = Join-Path $logsDir "errors-$($script:timestamp).txt"
    $unavailableReportPath = Join-Path $logsDir "unavailable-$($script:timestamp).csv"

    if ($unavailableSummary.Count -gt 0) {
        $unavailableSummary | Export-Csv -LiteralPath $unavailableReportPath -NoTypeInformation -Encoding UTF8
        Write-Host ''
        Write-Host "Недоступных уникальных позиций плейлиста: $($unavailableSummary.Count)" -ForegroundColor Yellow
        Write-Host "CSV со списком недоступных треков: $unavailableReportPath" -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host 'Строк о недоступных треках не обнаружено.' -ForegroundColor Green
    }

    $reportLines = New-Object 'System.Collections.Generic.List[string]'
    [void]$reportLines.Add('Сводка автоматического анализа текущего запуска.')
    [void]$reportLines.Add("Недоступных уникальных позиций плейлиста: $($unavailableSummary.Count)")
    [void]$reportLines.Add("Других строк с диагностическими признаками: $($otherErrorSummary.Count)")
    [void]$reportLines.Add("Полный лог: $($script:logPath)")
    if ($unavailableSummary.Count -gt 0) {
        [void]$reportLines.Add("CSV недоступных треков: $unavailableReportPath")
    }
    if ($otherErrorSummary.Count -gt 0) {
        [void]$reportLines.Add('')
        [void]$reportLines.Add('Другие диагностические строки (могут включать предупреждения):')
        foreach ($errorLine in $otherErrorSummary) {
            [void]$reportLines.Add([string]$errorLine)
        }
    }
    if ($unavailableSummary.Count -eq 0 -and $otherErrorSummary.Count -eq 0) {
        [void]$reportLines.Add('Явных диагностических строк автоматический фильтр не обнаружил.')
    }
    $reportLines | Out-File -FilePath $errorReportPath -Encoding utf8

    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    Write-Host "Полный лог: $($script:logPath)"
    Write-Host "Отчёт:     $errorReportPath"
    Write-Host 'Если отдельный трек всё равно не скачался, запусти этот же скрипт с прямой ссылкой на сам трек — так проще отделить проблему конкретного трека от проблемы всего плейлиста.' -ForegroundColor DarkGray
} catch {
    Write-Host "Ошибка запуска: $($_.Exception.Message)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($script:logPath)) { Write-Host "Проверь лог: $($script:logPath)" }
} finally {
    if ($tokenPtr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
    }
    if ($null -ne $secureToken) { $secureToken.Dispose() }
    $script:token = $null
}

Read-Host 'Нажми Enter, чтобы закрыть окно' | Out-Null
