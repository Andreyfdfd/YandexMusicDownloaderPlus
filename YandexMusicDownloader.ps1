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
$script:resumeSettings = $null
$script:resumeFromLog = $null
$script:sourceInventoryRecords = @()
$script:previousSourceInventory = @()
$script:sourceBaselinePath = $null
$script:hasPreviousSourceInventory = $false

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


function Get-PreviousDownloadSettings([string]$LogPath) {
    try { $logText = Get-Content -LiteralPath $LogPath -Raw -ErrorAction Stop }
    catch { Write-Host "Не удалось прочитать лог: $LogPath" -ForegroundColor Red; return $null }

    $urlMatch = [regex]::Match($logText, '(?m)^Ссылка:\s*(.+?)\s*$')
    $outputMatch = [regex]::Match($logText, '(?m)^Папка:\s*(.+?)\s*$')
    if (-not $urlMatch.Success -or -not $outputMatch.Success) {
        Write-Host 'В логе не найдены ссылка или папка назначения. Повтор отменён.' -ForegroundColor Yellow
        return $null
    }
    $url = $urlMatch.Groups[1].Value.Trim()
    $outputDir = $outputMatch.Groups[1].Value.Trim()
    $isRecoveryRun = $logText -match '(?m)^Режим: последовательное восстановление треков \(пункт 9\)\s*$' -or
        $logText -match '(?m)^Очередь восстановления по логу:'
    # In a recovery log, each URL прохода is a single track; preserve the original source URL.
    if (-not $isRecoveryRun) {
        $passUrlMatches = [regex]::Matches($logText, '(?m)^URL прохода:\s*(.+?)\s*$')
        if ($passUrlMatches.Count -gt 0) {
            $url = $passUrlMatches[$passUrlMatches.Count - 1].Groups[1].Value.Trim()
        } else {
            $alternateUrlMatches = [regex]::Matches($logText, '(?m)^Альтернативный URL после playlist-not-found:\s*(.+?)\s*$')
            if ($alternateUrlMatches.Count -gt 0) { $url = $alternateUrlMatches[$alternateUrlMatches.Count - 1].Groups[1].Value.Trim() }
        }
    }
    if ($url -notmatch '^https?://\S+') {
        Write-Host 'В логе отсутствует корректная HTTP(S)-ссылка. Повтор отменён.' -ForegroundColor Yellow
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($outputDir)) {
        Write-Host 'В логе не найдена папка назначения. Повтор отменён.' -ForegroundColor Yellow
        return $null
    }

    $qualityMatches = [regex]::Matches($logText, '(?m)^Качество прохода:\s*(.+?)\s*$')
    $formatMatches = [regex]::Matches($logText, '(?m)^Формат:\s*(.+?)\s*$')
    $formatLabel = 'AAC/M4A 192 kbps'
    if ($qualityMatches.Count -gt 0) { $formatLabel = $qualityMatches[$qualityMatches.Count - 1].Groups[1].Value.Trim() }
    elseif ($formatMatches.Count -gt 0) { $formatLabel = $formatMatches[0].Groups[1].Value.Trim() }

    $qualityValue = '1'
    if ($formatLabel -match '(?i)\bFLAC\b') { $qualityValue = '2' }
    $forceMp3 = $formatLabel -match '(?i)\bMP3\b'
    if ($forceMp3) { $qualityValue = '1'; $formatLabel = 'MP3' }
    elseif ($qualityValue -eq '2') { $formatLabel = 'FLAC (если lossless доступен для трека и аккаунта)' }
    else { $formatLabel = 'AAC/M4A 192 kbps' }

    return [pscustomobject]@{
        LogPath = $LogPath
        Url = $url
        OutputDir = $outputDir
        QualityValue = $qualityValue
        ForceMp3 = [bool]$forceMp3
        FormatName = $formatLabel
    }
}

function Select-PreviousDownloadLog {
    $logsDir = Join-Path $scriptRoot 'logs'
    if (-not (Test-Path -LiteralPath $logsDir -PathType Container)) {
        Write-Host 'Папка logs не найдена. Нет лога для повтора.' -ForegroundColor Yellow
        return $null
    }
    $logs = @(Get-ChildItem -LiteralPath $logsDir -Filter 'download-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 10)
    if ($logs.Count -eq 0) {
        Write-Host 'В папке logs пока нет файлов download-*.log.' -ForegroundColor Yellow
        return $null
    }

    Write-Host ''
    Write-Host 'Выбери предыдущий запуск. Показаны не более 10 последних логов:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $logs.Count; $i++) {
        Write-Host ("  {0} — {1}  ({2})" -f ($i + 1), $logs[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $logs[$i].Name)
    }
    $choices = @('0')
    for ($i = 1; $i -le $logs.Count; $i++) { $choices += [string]$i }
    $selection = Read-MenuChoice 'Номер лога (0 — отмена)' $choices '1'
    if ($selection -eq '0') { return $null }
    $settings = Get-PreviousDownloadSettings -LogPath $logs[[int]$selection - 1].FullName
    if ($null -eq $settings) { return $null }
    return $settings
}

function Move-ZeroLengthAudioToQuarantine([string]$RootPath) {
    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) { return }
    $extensions = @('.m4a', '.mp3', '.flac', '.aac', '.ogg', '.opus', '.wav', '.wma', '.aiff', '.ape')
    $zeroFiles = @(Get-ChildItem -LiteralPath $RootPath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Length -eq 0 -and
            $extensions -contains $_.Extension.ToLowerInvariant() -and
            $_.FullName -notmatch '(?i)\\[^\\]*\._DownloaderPlus_Quarantine_[^\\]*\\'
        })
    if ($zeroFiles.Count -eq 0) { return }

    Write-Host ''
    Write-Host ("Найдено аудиофайлов нулевого размера: {0}." -f $zeroFiles.Count) -ForegroundColor Yellow
    Write-Host 'Из-за --skip-existing загрузчик может пропустить их вместо повторной загрузки.' -ForegroundColor Gray
    Write-Host 'При согласии они будут перемещены в карантин, не удалены.' -ForegroundColor Gray
    $choice = Read-MenuChoice '0 — оставить на месте; 1 — перенести нулевые файлы в карантин' @('0','1') '0'
    if ($choice -ne '1') {
        Write-Host 'Нулевые файлы оставлены; загрузчик может их пропустить.' -ForegroundColor Yellow
        return
    }

    try {
        $fullRoot = [System.IO.Path]::GetFullPath($RootPath)
        $trimmedRoot = $fullRoot.TrimEnd([char[]]@('\','/'))
        if ($trimmedRoot -match '^[A-Za-z]:$') { $parent = "$trimmedRoot\"; $leaf = 'drive-root' }
        else { $parent = Split-Path -Parent $trimmedRoot; $leaf = Split-Path -Leaf $trimmedRoot }

        $qName = '{0}._DownloaderPlus_Quarantine_{1}' -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss')
        $qPath = Join-Path $parent $qName
        if (Test-Path -LiteralPath $qPath) {
            $qName = '{0}._DownloaderPlus_Quarantine_{1}_{2}' -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0,8))
            $qPath = Join-Path $parent $qName
        }

        $moved = 0; $failed = 0
        foreach ($file in $zeroFiles) {
            $relative = $file.FullName.Substring($trimmedRoot.Length).TrimStart([char[]]@('\','/'))
            $target = Join-Path $qPath $relative
            try {
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force -ErrorAction Stop | Out-Null
                Move-Item -LiteralPath $file.FullName -Destination $target -ErrorAction Stop
                $moved++
            } catch {
                $failed++
                Write-Host "Не удалось переместить $($file.FullName): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        if ($moved -gt 0) {
            Write-Host "Перемещено файлов: $moved. Папка карантина: $qPath" -ForegroundColor Green
            Write-Host 'Файлы сохранены, автоматического удаления не было.' -ForegroundColor DarkGray
        }
        if ($failed -gt 0) { Write-Host "Не удалось переместить файлов: $failed. Они остаются на месте и могут быть пропущены." -ForegroundColor Yellow }
    } catch {
        Write-Host "Не удалось подготовить карантин: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'Файлы не удалялись автоматически.' -ForegroundColor DarkGray
    }
}


function Get-SourceSnapshotKey([string]$SourceUrl) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($SourceUrl)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 20).ToLowerInvariant())
    } finally {
        $sha.Dispose()
    }
}

function Invoke-SourceInventory([string]$SourceUrl, [string]$PythonExe) {
    $helperPath = Join-Path (Join-Path $scriptRoot 'tools') 'source_inventory.py'
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; Tracks = @(); Error = "Не найден вспомогательный файл: $helperPath" }
    }
    if ([string]::IsNullOrWhiteSpace($PythonExe) -or -not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; Tracks = @(); Error = 'Не найден python.exe, связанный с загрузчиком.' }
    }
    $jsonPath = Join-Path $env:TEMP ("ymdp-source-inventory-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $env:YMDPLUS_INVENTORY_TOKEN = $script:token
    try {
        $null = & $PythonExe $helperPath inventory --url $SourceUrl --output-json $jsonPath 2>&1
        $exitCode = $LASTEXITCODE
        if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
            return [pscustomobject]@{ Success = $false; Tracks = @(); Error = "Помощник состава источника завершился с кодом $exitCode и не создал ответ." }
        }
        try {
            $payload = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ Success = $false; Tracks = @(); Error = "Не удалось разобрать ответ помощника состава источника: $($_.Exception.Message)" }
        }
        if (-not $payload.success) {
            return [pscustomobject]@{ Success = $false; Tracks = @(); Error = [string]$payload.error }
        }
        return [pscustomobject]@{ Success = $true; Tracks = @($payload.tracks); Error = ''; Count = [int]$payload.count }
    } catch {
        return [pscustomobject]@{ Success = $false; Tracks = @(); Error = $_.Exception.Message }
    } finally {
        Remove-Item Env:\YMDPLUS_INVENTORY_TOKEN -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
            Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-NormalizedAudioBasePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { $fullPath = [System.IO.Path]::GetFullPath($Path) } catch { $fullPath = $Path }
    $extension = [System.IO.Path]::GetExtension($fullPath)
    if (@('.m4a','.mp3','.flac','.aac','.ogg','.opus','.wav','.wma','.aiff','.ape') -contains $extension.ToLowerInvariant()) {
        $fullPath = [System.IO.Path]::ChangeExtension($fullPath, $null)
    }
    return $fullPath.ToLowerInvariant()
}

function Get-TrackAudioFiles([string]$RootPath, [string]$RelativeBasePath) {
    if ([string]::IsNullOrWhiteSpace($RootPath) -or [string]::IsNullOrWhiteSpace($RelativeBasePath)) { return @() }
    $relative = $RelativeBasePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $basePath = Join-Path $RootPath $relative
    $directory = Split-Path -Parent $basePath
    $baseName = Split-Path -Leaf $basePath
    if ([string]::IsNullOrWhiteSpace($directory) -or -not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
    # Only formats that this upstream downloader recognizes for --skip-existing.
    $extensions = @('.m4a','.mp3','.flac')
    return @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
        Where-Object {
            ([System.IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $baseName) -and
            ($extensions -contains $_.Extension.ToLowerInvariant())
        })
}

function Test-AudioDuration([string]$PythonExe, [string]$AudioPath, [object]$ExpectedDurationMs) {
    $helperPath = Join-Path (Join-Path $scriptRoot 'tools') 'source_inventory.py'
    if ([string]::IsNullOrWhiteSpace($PythonExe) -or -not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; DurationSeconds = 0.0; ValidAgainstMetadata = $false; Error = 'Не найден помощник проверки длительности.' }
    }
    try {
        $output = (& $PythonExe $helperPath duration --path $AudioPath 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
            return [pscustomobject]@{ Success = $false; DurationSeconds = 0.0; ValidAgainstMetadata = $false; Error = $output }
        }
        $payload = $output | ConvertFrom-Json -ErrorAction Stop
        if (-not $payload.success) {
            return [pscustomobject]@{ Success = $false; DurationSeconds = 0.0; ValidAgainstMetadata = $false; Error = [string]$payload.error }
        }
        $actual = [double]$payload.durationSeconds
        $expected = 0.0
        if ($null -ne $ExpectedDurationMs -and [double]$ExpectedDurationMs -gt 0) {
            $expected = [double]$ExpectedDurationMs / 1000.0
        }
        if ($expected -le 0) {
            return [pscustomobject]@{ Success = $true; DurationSeconds = $actual; ValidAgainstMetadata = $false; Error = 'В источнике не указана длительность для сравнения.' }
        }
        $tolerance = [Math]::Max(8.0, $expected * 0.15)
        $valid = [Math]::Abs($actual - $expected) -le $tolerance
        return [pscustomobject]@{ Success = $true; DurationSeconds = $actual; ValidAgainstMetadata = $valid; Error = '' }
    } catch {
        return [pscustomobject]@{ Success = $false; DurationSeconds = 0.0; ValidAgainstMetadata = $false; Error = $_.Exception.Message }
    }
}

function Add-TrackFailureToMap([hashtable]$FailureMap, [object]$TrackRecord, [string]$Details, [string]$FallbackLabel = '') {
    $trackId = ''
    $trackKey = ''
    if ($null -ne $TrackRecord -and -not [string]::IsNullOrWhiteSpace([string]$TrackRecord.TrackId)) {
        $trackId = [string]$TrackRecord.TrackId
        $trackKey = [string]$TrackRecord.TrackKey
        if ([string]::IsNullOrWhiteSpace($trackKey)) { $trackKey = $trackId }
    }
    $key = if ($trackKey) { $trackKey } elseif ($trackId) { $trackId } else { "label:$FallbackLabel" }
    if ([string]::IsNullOrWhiteSpace($key)) { $key = "unknown:$($FailureMap.Count)" }

    if ($FailureMap.ContainsKey($key)) {
        $existing = $FailureMap[$key]
        if (-not [string]::IsNullOrWhiteSpace($Details) -and $existing.Details -notlike "*$Details*") {
            $existing.Details = ($existing.Details, $Details | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '; '
        }
        return
    }

    $sourceIndex = ''
    $title = $FallbackLabel
    $artists = ''
    $album = ''
    $trackUrl = ''
    $relativePath = ''
    $duration = 0
    if ($null -ne $TrackRecord) {
        $sourceIndex = $TrackRecord.SourceIndex
        $title = $TrackRecord.TrackTitle
        $artists = $TrackRecord.Artists
        $album = $TrackRecord.AlbumTitle
        $trackUrl = $TrackRecord.TrackUrl
        $relativePath = $TrackRecord.RelativeBasePath
        $duration = $TrackRecord.DurationMs
    }
    $row = [pscustomobject]@{
        Category = 'Не удалось скачать'
        SourceIndex = $sourceIndex
        TrackId = $trackId
        TrackKey = $trackKey
        TrackTitle = $title
        Artists = $artists
        AlbumTitle = $album
        TrackUrl = $trackUrl
        RelativeBasePath = $relativePath
        DurationMs = $duration
        Details = $Details
    }
    $FailureMap[$key] = $row
}

function Write-SourceStatusReport(
    [object[]]$CurrentInventory,
    [object[]]$PreviousInventory,
    [bool]$HasPreviousInventory,
    [string]$SourceUrl,
    [string]$OutputDir,
    [string]$LogText,
    [string]$LogsDir,
    [string]$RunTimestamp,
    [string]$BaselinePath
) {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $failures = @{}
    $currentIds = @{}
    foreach ($track in @($CurrentInventory)) {
        $currentKey = [string]$track.TrackKey
        if ([string]::IsNullOrWhiteSpace($currentKey)) { $currentKey = [string]$track.TrackId }
        if (-not [string]::IsNullOrWhiteSpace($currentKey)) { $currentIds[$currentKey] = $true }
    }

    if ($HasPreviousInventory) {
        foreach ($oldTrack in @($PreviousInventory)) {
            $oldId = [string]$oldTrack.TrackId
            $oldKey = [string]$oldTrack.TrackKey
            if ([string]::IsNullOrWhiteSpace($oldKey)) { $oldKey = $oldId }
            if (-not [string]::IsNullOrWhiteSpace($oldKey) -and -not $currentIds.ContainsKey($oldKey)) {
                [void]$rows.Add([pscustomobject]@{
                    Category = 'Удалено из источника'
                    SourceIndex = $oldTrack.SourceIndex
                    TrackId = $oldId
                    TrackKey = $oldKey
                    TrackTitle = $oldTrack.TrackTitle
                    Artists = $oldTrack.Artists
                    AlbumTitle = $oldTrack.AlbumTitle
                    TrackUrl = $oldTrack.TrackUrl
                    RelativeBasePath = $oldTrack.RelativeBasePath
                    DurationMs = $oldTrack.DurationMs
                    Details = 'Трек был в предыдущем снимке источника, но отсутствует в текущем. Локальный файл не удалялся.'
                })
            }
        }
    } else {
        [void]$rows.Add([pscustomobject]@{
            Category = 'Начальный снимок источника'
            SourceIndex = ''; TrackId = ''; TrackKey = ''; TrackTitle = ''; Artists = ''; AlbumTitle = ''
            TrackUrl = ''; RelativeBasePath = ''; DurationMs = ''
            Details = 'Предыдущего снимка нет. Этот запуск создаёт базу для сравнения удалённых из источника треков в следующих запусках.'
        })
    }

    foreach ($entry in @(Get-UnavailableTrackEntries -Text $LogText)) {
        $match = $null
        if ($CurrentInventory.Count -eq [int]$entry.PlaylistTotal) {
            $match = @($CurrentInventory | Where-Object { [int]$_.SourceIndex -eq [int]$entry.TrackIndex } | Select-Object -First 1)[0]
        }
        if ($null -eq $match) {
            $match = @($CurrentInventory | Where-Object { $_.TrackLabel -and $_.TrackLabel.Trim() -ieq $entry.Track.Trim() } | Select-Object -First 1)[0]
        }
        Add-TrackFailureToMap -FailureMap $failures -TrackRecord $match -Details ("Основной загрузчик сообщил: {0}" -f $entry.Message) -FallbackLabel $entry.Track
    }

    $outcomeFiles = @(Get-ChildItem -LiteralPath $LogsDir -Filter "file-outcomes-$RunTimestamp-*.csv" -File -ErrorAction SilentlyContinue)
    foreach ($outcomeFile in $outcomeFiles) {
        foreach ($outcome in @(Import-Csv -LiteralPath $outcomeFile.FullName -ErrorAction SilentlyContinue)) {
            if ($outcome.Status -notin @('Не найден после прохода','Нулевой размер','Изменение не обнаружено')) { continue }
            $pathKey = Get-NormalizedAudioBasePath -Path ([string]$outcome.Path)
            $match = $null
            foreach ($track in @($CurrentInventory)) {
                $expectedBase = Join-Path $OutputDir ([string]$track.RelativeBasePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if ((Get-NormalizedAudioBasePath -Path $expectedBase) -eq $pathKey) { $match = $track; break }
            }
            $detail = "Отчёт $($outcomeFile.Name): $($outcome.Status) — $($outcome.Path)"
            Add-TrackFailureToMap -FailureMap $failures -TrackRecord $match -Details $detail -FallbackLabel ([System.IO.Path]::GetFileNameWithoutExtension([string]$outcome.Path))
        }
    }

    foreach ($failure in $failures.Values) { [void]$rows.Add($failure) }
    foreach ($errorLine in @(Get-ErrorLines -Text $LogText)) {
        [void]$rows.Add([pscustomobject]@{
            Category = 'Общая ошибка загрузки'
            SourceIndex = ''; TrackId = ''; TrackKey = ''; TrackTitle = ''; Artists = ''; AlbumTitle = ''
            TrackUrl = ''; RelativeBasePath = ''; DurationMs = ''
            Details = [string]$errorLine
        })
    }
    if ($rows.Count -eq 0) {
        [void]$rows.Add([pscustomobject]@{
            Category = 'Проблем не обнаружено'
            SourceIndex = ''; TrackId = ''; TrackKey = ''; TrackTitle = ''; Artists = ''; AlbumTitle = ''
            TrackUrl = ''; RelativeBasePath = ''; DurationMs = ''
            Details = 'В ходе этого запуска не обнаружено удалённых из источника или однозначно неудачных треков.'
        })
    }

    $reportPath = Join-Path $LogsDir "library-status-$RunTimestamp.csv"
    $rows.ToArray() | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
    if (@($CurrentInventory).Count -gt 0) {
        @($CurrentInventory) | Export-Csv -LiteralPath $BaselinePath -NoTypeInformation -Encoding UTF8
    }

    $removedCount = @($rows.ToArray() | Where-Object { $_.Category -eq 'Удалено из источника' }).Count
    $failedCount = @($rows.ToArray() | Where-Object { $_.Category -eq 'Не удалось скачать' }).Count
    Write-Host ''
    Write-Host 'Сводный отчёт по составу источника и неудачным загрузкам:' -ForegroundColor Cyan
    if (-not $HasPreviousInventory) {
        Write-Host '  Предыдущего снимка не было — база для поиска удалённых треков создана.' -ForegroundColor Gray
    } else {
        Write-Host "  Треков, удалённых из источника с предыдущей проверки: $removedCount" -ForegroundColor Yellow
    }
    Write-Host "  Треков с обнаруженной неудачной загрузкой: $failedCount" -ForegroundColor Yellow
    Write-Host "  Полный список: $reportPath" -ForegroundColor Green
    return [pscustomobject]@{ ReportPath = $reportPath; RemovedCount = $removedCount; FailedCount = $failedCount }
}

function Add-RetryCandidate([System.Collections.Generic.List[object]]$Queue, [hashtable]$Seen, [object]$TrackRecord, [string]$Details, [string]$FallbackLabel = '') {
    $trackId = ''
    $trackKey = ''
    if ($null -ne $TrackRecord) {
        $trackId = [string]$TrackRecord.TrackId
        $trackKey = [string]$TrackRecord.TrackKey
        if ([string]::IsNullOrWhiteSpace($trackKey)) { $trackKey = $trackId }
    }
    $key = if ($trackKey) { $trackKey } elseif ($trackId) { $trackId } else { "label:$FallbackLabel" }
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    if ($Seen.ContainsKey($key)) {
        $existing = $Seen[$key]
        if (-not [string]::IsNullOrWhiteSpace($Details) -and $existing.Details -notlike "*$Details*") {
            $existing.Details = ($existing.Details, $Details | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '; '
        }
        return
    }
    if ($null -eq $TrackRecord -or [string]::IsNullOrWhiteSpace([string]$TrackRecord.TrackUrl)) { return }
    $candidate = [pscustomobject]@{
        SourceIndex = $TrackRecord.SourceIndex
        TrackId = $trackId
        TrackKey = $trackKey
        TrackTitle = $TrackRecord.TrackTitle
        TrackLabel = $TrackRecord.TrackLabel
        Artists = $TrackRecord.Artists
        AlbumTitle = $TrackRecord.AlbumTitle
        TrackUrl = $TrackRecord.TrackUrl
        RelativeBasePath = $TrackRecord.RelativeBasePath
        DurationMs = $TrackRecord.DurationMs
        Details = $Details
    }
    [void]$Queue.Add($candidate)
    $Seen[$key] = $candidate
}

function Get-RetryQueueFromLog([string]$PreviousLogPath, [string]$OutputDir, [string]$PythonExe, [string]$LogsDir) {
    $match = [regex]::Match([System.IO.Path]::GetFileName($PreviousLogPath), '^download-(?<Stamp>\d{8}-\d{6})\.log$')
    if (-not $match.Success) { return [pscustomobject]@{ Queue = @(); Error = 'Имя выбранного лога не содержит ожидаемую временную метку.' } }
    $oldStamp = $match.Groups['Stamp'].Value
    $inventoryPath = Join-Path $LogsDir "source-inventory-$oldStamp.csv"
    $reportPath = Join-Path $LogsDir "library-status-$oldStamp.csv"
    $queue = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $inventory = @()
    $hasOriginalInventory = $false

    # Reusing a prior option-9 log should queue only unresolved candidates, not repeat successes.
    $priorQueuePath = Join-Path $LogsDir "retry-queue-$oldStamp.csv"
    $priorResultsPath = Join-Path $LogsDir "recovery-results-$oldStamp.csv"
    if (Test-Path -LiteralPath $priorQueuePath -PathType Leaf) {
        $priorQueue = @(Import-Csv -LiteralPath $priorQueuePath -ErrorAction SilentlyContinue)
        $priorResults = @{}
        if (Test-Path -LiteralPath $priorResultsPath -PathType Leaf) {
            foreach ($resultRow in @(Import-Csv -LiteralPath $priorResultsPath -ErrorAction SilentlyContinue)) {
                $resultKey = [string]$resultRow.TrackKey
                if ([string]::IsNullOrWhiteSpace($resultKey)) { $resultKey = [string]$resultRow.TrackId }
                if (-not [string]::IsNullOrWhiteSpace($resultKey)) { $priorResults[$resultKey] = $resultRow }
            }
        }
        foreach ($candidate in $priorQueue) {
            $candidateKey = [string]$candidate.TrackKey
            if ([string]::IsNullOrWhiteSpace($candidateKey)) { $candidateKey = [string]$candidate.TrackId }
            $previousResult = if ($priorResults.ContainsKey($candidateKey)) { $priorResults[$candidateKey] } else { $null }
            if ($null -ne $previousResult -and $previousResult.Status -eq 'Успешно восстановлен') {
                $present = @(Get-TrackAudioFiles -RootPath $OutputDir -RelativeBasePath ([string]$candidate.RelativeBasePath))
                if ($present.Count -gt 0) { continue }
                $detail = 'Файл ранее восстановлен, но теперь отсутствует; повторная попытка добавлена в очередь.'
            } elseif ($null -ne $previousResult) {
                $detail = 'Результат прошлой попытки: {0}. {1}' -f $previousResult.Status, $previousResult.Details
            } else {
                $detail = 'Предыдущая попытка была прервана до записи результата.'
            }
            Add-RetryCandidate -Queue $queue -Seen $seen -TrackRecord $candidate -Details $detail -FallbackLabel ([string]$candidate.TrackTitle)
        }
        return [pscustomobject]@{ Queue = @($queue.ToArray()); Error = ''; InventoryPath = $inventoryPath; ReportPath = $reportPath; Timestamp = $oldStamp; ReusedRecoveryQueue = $true }
    }

    if (Test-Path -LiteralPath $inventoryPath -PathType Leaf) {
        $inventory = @(Import-Csv -LiteralPath $inventoryPath)
        $hasOriginalInventory = $inventory.Count -gt 0
    } else {
        Write-Host 'У выбранного запуска нет сохранённого снимка треков. Пытаюсь прочитать состав источника сейчас; привязка старых позиций может оказаться невозможной.' -ForegroundColor Yellow
        $snapshot = Invoke-SourceInventory -SourceUrl $script:resumeSettings.Url -PythonExe $PythonExe
        if ($snapshot.Success) { $inventory = @($snapshot.Tracks) }
        else { Write-Host "Не удалось получить состав источника: $($snapshot.Error)" -ForegroundColor Yellow }
    }

    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        foreach ($row in @(Import-Csv -LiteralPath $reportPath | Where-Object { $_.Category -eq 'Не удалось скачать' })) {
            if (-not [string]::IsNullOrWhiteSpace([string]$row.TrackUrl)) {
                Add-RetryCandidate -Queue $queue -Seen $seen -TrackRecord $row -Details ([string]$row.Details) -FallbackLabel ([string]$row.TrackTitle)
            }
        }
    }

    $oldLogText = Get-Content -LiteralPath $PreviousLogPath -Raw -ErrorAction SilentlyContinue
    foreach ($entry in @(Get-UnavailableTrackEntries -Text $oldLogText)) {
        $track = $null
        if ($hasOriginalInventory -and $inventory.Count -eq [int]$entry.PlaylistTotal) {
            $track = @($inventory | Where-Object { [int]$_.SourceIndex -eq [int]$entry.TrackIndex } | Select-Object -First 1)[0]
        }
        if ($null -eq $track) {
            $track = @($inventory | Where-Object { $_.TrackLabel -and $_.TrackLabel.Trim() -ieq $entry.Track.Trim() } | Select-Object -First 1)[0]
        }
        Add-RetryCandidate -Queue $queue -Seen $seen -TrackRecord $track -Details ([string]$entry.Message) -FallbackLabel ([string]$entry.Track)
    }

    foreach ($outcomeFile in @(Get-ChildItem -LiteralPath $LogsDir -Filter "file-outcomes-$oldStamp-*.csv" -File -ErrorAction SilentlyContinue)) {
        foreach ($outcome in @(Import-Csv -LiteralPath $outcomeFile.FullName -ErrorAction SilentlyContinue)) {
            if ($outcome.Status -notin @('Не найден после прохода','Нулевой размер','Изменение не обнаружено')) { continue }
            $pathKey = Get-NormalizedAudioBasePath -Path ([string]$outcome.Path)
            $track = $null
            foreach ($item in $inventory) {
                $expectedBase = Join-Path $OutputDir ([string]$item.RelativeBasePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if ((Get-NormalizedAudioBasePath -Path $expectedBase) -eq $pathKey) { $track = $item; break }
            }
            Add-RetryCandidate -Queue $queue -Seen $seen -TrackRecord $track -Details ("$($outcome.Status): $($outcome.Path)") -FallbackLabel ([System.IO.Path]::GetFileNameWithoutExtension([string]$outcome.Path))
        }
    }
    return [pscustomobject]@{ Queue = @($queue.ToArray()); Error = ''; InventoryPath = $inventoryPath; ReportPath = $reportPath; Timestamp = $oldStamp }
}

function Move-CandidateFilesToQuarantine([object[]]$Queue, [string]$RootPath, [bool]$OnlyZeroLength = $false) {
    $filesToMove = New-Object 'System.Collections.Generic.List[object]'
    $seenPaths = @{}
    foreach ($candidate in @($Queue)) {
        foreach ($file in @(Get-TrackAudioFiles -RootPath $RootPath -RelativeBasePath ([string]$candidate.RelativeBasePath))) {
            if ($OnlyZeroLength -and $file.Length -ne 0) { continue }
            if ($seenPaths.ContainsKey($file.FullName)) { continue }
            $seenPaths[$file.FullName] = $true
            [void]$filesToMove.Add($file)
        }
    }
    if ($filesToMove.Count -eq 0) { return [pscustomobject]@{ Moved = 0; Path = '' } }

    $fullRoot = [System.IO.Path]::GetFullPath($RootPath)
    $trimmedRoot = $fullRoot.TrimEnd([char[]]@('\','/'))
    if ($trimmedRoot -match '^[A-Za-z]:$') { $parent = "$trimmedRoot\"; $leaf = 'drive-root' }
    else { $parent = Split-Path -Parent $trimmedRoot; $leaf = Split-Path -Leaf $trimmedRoot }
    $qName = '{0}._DownloaderPlus_Quarantine_{1}' -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $qPath = Join-Path $parent $qName
    if (Test-Path -LiteralPath $qPath) { $qPath = Join-Path $parent ("{0}._DownloaderPlus_Quarantine_{1}_{2}" -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0,8))) }

    $moved = 0
    foreach ($file in $filesToMove) {
        $relative = $file.FullName.Substring($trimmedRoot.Length).TrimStart([char[]]@('\','/'))
        $target = Join-Path $qPath $relative
        try {
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force -ErrorAction Stop | Out-Null
            Move-Item -LiteralPath $file.FullName -Destination $target -ErrorAction Stop
            $moved++
        } catch {
            Write-Host "Не удалось переместить в карантин $($file.FullName): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    return [pscustomobject]@{ Moved = $moved; Path = $qPath }
}

function Initialize-YtDlpRecovery([string]$PythonExe) {
    Write-Host ''
    Write-Host 'Основной загрузчик не смог получить трек. Можно попробовать резервный источник через yt-dlp и авторизованную браузерную сессию.' -ForegroundColor Yellow
    $enabled = Read-MenuChoice 'Использовать резервный источник для оставшихся неудачных треков? (0 — нет, 1 — да)' @('0','1') '1'
    if ($enabled -ne '1') { return [pscustomobject]@{ Enabled = $false; Browser = ''; PythonExe = $PythonExe } }
    Write-Host 'Выбери браузер, в котором Яндекс Музыка открывается с действующей авторизацией:'
    Write-Host '  1 — Chrome'; Write-Host '  2 — Edge'; Write-Host '  3 — Firefox'; Write-Host '  4 — Brave'
    $browserChoice = Read-MenuChoice 'Браузер' @('1','2','3','4') '1'
    $browser = switch ($browserChoice) { '1' { 'chrome' } '2' { 'edge' } '3' { 'firefox' } '4' { 'brave' } }
    Write-Host 'Проверяю/устанавливаю yt-dlp и плагин один раз для всей очереди...' -ForegroundColor Gray
    & $PythonExe -m pip install --upgrade 'yt-dlp[default]' 'yt-dlp-yandex-music'
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Установка резервного источника не удалась; продолжу очередь только основным загрузчиком.' -ForegroundColor Yellow
        return [pscustomobject]@{ Enabled = $false; Browser = $browser; PythonExe = $PythonExe }
    }
    return [pscustomobject]@{ Enabled = $true; Browser = $browser; PythonExe = $PythonExe }
}

function Invoke-YtDlpRecoveryTrack([object]$Candidate, [string]$PythonExe, [string]$Browser, [string]$StagingRoot) {
    $stageKey = [string]$Candidate.TrackKey
    if ([string]::IsNullOrWhiteSpace($stageKey)) { $stageKey = [string]$Candidate.TrackId }
    $stageKey = $stageKey -replace '[^A-Za-z0-9_-]', '_'
    $trackStage = Join-Path $StagingRoot $stageKey
    New-Item -ItemType Directory -Path $trackStage -Force | Out-Null
    $outputPattern = Join-Path $trackStage 'track.%(ext)s'
    $args = @('-m','yt_dlp','--cookies-from-browser',$Browser,'--no-playlist','--no-overwrites','--embed-metadata','--embed-thumbnail','--output',$outputPattern,[string]$Candidate.TrackUrl)
    Write-Host "  Резервный источник: $($Candidate.TrackTitle)" -ForegroundColor DarkCyan
    & $PythonExe @args 2>&1 | ForEach-Object {
        $line = [string]$_
        Write-Host $line
        if (-not [string]::IsNullOrWhiteSpace($script:logPath)) { Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8 }
    }
    $exitCode = $LASTEXITCODE
    $files = @(Get-ChildItem -LiteralPath $trackStage -File -ErrorAction SilentlyContinue |
        Where-Object { @('.m4a','.mp3','.flac','.aac','.ogg','.opus','.wav','.wma','.aiff','.ape') -contains $_.Extension.ToLowerInvariant() })
    if ($exitCode -ne 0 -or $files.Count -eq 0) {
        return [pscustomobject]@{ Success = $false; Path = ''; Details = "Резервный источник завершился с кодом $exitCode и не создал аудиофайл. Staging: $trackStage" }
    }
    $candidateFile = $files | Sort-Object Length -Descending | Select-Object -First 1
    if (@('.m4a','.mp3','.flac') -notcontains $candidateFile.Extension.ToLowerInvariant()) {
        return [pscustomobject]@{ Success = $false; Path = $candidateFile.FullName; Details = "Формат $($candidateFile.Extension) основной загрузчик не распознаёт для --skip-existing; файл оставлен в staging для ручной проверки." }
    }
    $duration = Test-AudioDuration -PythonExe $PythonExe -AudioPath $candidateFile.FullName -ExpectedDurationMs $Candidate.DurationMs
    if (-not $duration.Success -or -not $duration.ValidAgainstMetadata) {
        $reason = if (-not $duration.Success) { $duration.Error } else { "Длительность {0:N1} с не согласуется с ожидаемыми {1:N1} с." -f $duration.DurationSeconds, ([double]$Candidate.DurationMs / 1000.0) }
        return [pscustomobject]@{ Success = $false; Path = $candidateFile.FullName; Details = "Файл оставлен в staging для ручной проверки: $reason" }
    }

    $relative = ([string]$Candidate.RelativeBasePath).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $targetBase = Join-Path $script:outputDir $relative
    $targetPath = $targetBase + $candidateFile.Extension
    New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force | Out-Null
    if (Test-Path -LiteralPath $targetPath) {
        return [pscustomobject]@{ Success = $false; Path = $candidateFile.FullName; Details = "Целевой файл уже существует; результат оставлен в staging: $targetPath" }
    }
    Move-Item -LiteralPath $candidateFile.FullName -Destination $targetPath -ErrorAction Stop
    return [pscustomobject]@{ Success = $true; Path = $targetPath; Details = ("Резервный файл проверен по длительности ({0:N1} с из ожидаемых {1:N1} с)." -f $duration.DurationSeconds, ([double]$Candidate.DurationMs / 1000.0)) }
}

function Invoke-RetryFailedTracks([string]$PreviousLogPath, [string]$PythonExe, [string]$LogsDir, [string]$RunTimestamp) {
    $queueResult = Get-RetryQueueFromLog -PreviousLogPath $PreviousLogPath -OutputDir $script:outputDir -PythonExe $PythonExe -LogsDir $LogsDir
    if ($queueResult.Queue.Count -eq 0) {
        if ($queueResult.ReusedRecoveryQueue) {
            Write-Host 'В предыдущей очереди не осталось треков для повторного восстановления.' -ForegroundColor Green
        } else {
            Write-Host 'В выбранном запуске не удалось составить очередь отдельных треков для повтора.' -ForegroundColor Yellow
            Write-Host 'Для старого лога без source-inventory CSV может потребоваться обычный запуск, чтобы создать точный снимок источника.' -ForegroundColor Gray
        }
        return
    }
    $queue = @($queueResult.Queue)
    $queuePath = Join-Path $LogsDir "retry-queue-$RunTimestamp.csv"
    $queue | Export-Csv -LiteralPath $queuePath -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host ("Найдено треков для последовательного восстановления: {0}" -f $queue.Count) -ForegroundColor Cyan
    $queue | ForEach-Object { Write-Host ("  [{0}] {1} — {2}" -f $_.TrackId, $_.TrackTitle, $_.Details) }
    Write-Host "CSV очереди: $queuePath" -ForegroundColor DarkGray

    $zeroCandidates = New-Object 'System.Collections.Generic.List[object]'
    $nonzeroCandidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in $queue) {
        foreach ($file in @(Get-TrackAudioFiles -RootPath $script:outputDir -RelativeBasePath ([string]$candidate.RelativeBasePath))) {
            if ($file.Length -eq 0) { [void]$zeroCandidates.Add($candidate); break }
            [void]$nonzeroCandidates.Add($candidate)
            break
        }
    }
    if ($zeroCandidates.Count -gt 0) {
        $zeroDistinct = @($zeroCandidates | Group-Object TrackKey | ForEach-Object { $_.Group[0] })
        Write-Host ("Для {0} проблемных треков найдены файлы нулевого размера; загрузчик может пропустить их из-за --skip-existing." -f $zeroDistinct.Count) -ForegroundColor Yellow
        $moveZero = Read-MenuChoice '0 — оставить; 1 — переместить эти файлы в карантин и повторить загрузку' @('0','1') '0'
        if ($moveZero -eq '1') {
            $movedZero = Move-CandidateFilesToQuarantine -Queue $zeroDistinct -RootPath $script:outputDir -OnlyZeroLength $true
            Write-Host "Перемещено в карантин: $($movedZero.Moved). Папка: $($movedZero.Path)" -ForegroundColor Green
        }
    }

    $existingCandidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in $queue) {
        if (@(Get-TrackAudioFiles -RootPath $script:outputDir -RelativeBasePath ([string]$candidate.RelativeBasePath)).Count -gt 0) {
            [void]$existingCandidates.Add($candidate)
        }
    }
    if ($existingCandidates.Count -gt 0) {
        $existingDistinct = @($existingCandidates | Group-Object TrackKey | ForEach-Object { $_.Group[0] })
        Write-Host ("У {0} кандидатов всё ещё есть локальный аудиофайл. Он может быть полноценным, а может быть частичным." -f $existingDistinct.Count) -ForegroundColor Yellow
        $moveExisting = Read-MenuChoice '0 — сохранить и пропустить; 1 — перенести эти файлы в карантин и попытаться скачать заново' @('0','1') '0'
        if ($moveExisting -eq '1') {
            $movedExisting = Move-CandidateFilesToQuarantine -Queue $existingDistinct -RootPath $script:outputDir
            Write-Host "Перемещено файлов в карантин: $($movedExisting.Moved). Папка: $($movedExisting.Path)" -ForegroundColor Green
        }
    }

    $stagingRoot = Join-Path (Split-Path -Parent $script:outputDir) ("{0}._DownloaderPlus_RecoveryStaging_{1}" -f (Split-Path -Leaf $script:outputDir), $RunTimestamp)
    $fallback = $null
    $fallbackInitialized = $false
    $results = New-Object 'System.Collections.Generic.List[object]'
    $originalUrl = $script:sourceUrl

    for ($i = 0; $i -lt $queue.Count; $i++) {
        $candidate = $queue[$i]
        Write-Host ''
        Write-Host ("[{0}/{1}] {2} — {3}" -f ($i + 1), $queue.Count, $candidate.Artists, $candidate.TrackTitle) -ForegroundColor Cyan
        $existingNow = @(Get-TrackAudioFiles -RootPath $script:outputDir -RelativeBasePath ([string]$candidate.RelativeBasePath))
        if ($existingNow.Count -gt 0) {
            [void]$results.Add([pscustomobject]@{ TrackId = $candidate.TrackId; TrackKey = $candidate.TrackKey; Track = $candidate.TrackTitle; Status = 'Пропущен: локальный файл оставлен'; Method = ''; Path = $existingNow[0].FullName; Details = 'Не перезаписывался, потому что локальный файл оставлен пользователем.' })
            Write-Host 'У кандидата всё ещё есть локальный файл; по соображениям безопасности он не перезаписывается.' -ForegroundColor Yellow
            continue
        }

        $script:sourceUrl = [string]$candidate.TrackUrl
        $beforeFiles = @(Get-TrackAudioFiles -RootPath $script:outputDir -RelativeBasePath ([string]$candidate.RelativeBasePath) | ForEach-Object { $_.FullName.ToLowerInvariant() })
        $pass = Invoke-DownloadPass -PassName ("ВОССТАНОВЛЕНИЕ {0:D3} — ОСНОВНОЙ" -f ($i + 1)) -QualityValue $script:quality
        $afterFiles = @(Get-TrackAudioFiles -RootPath $script:outputDir -RelativeBasePath ([string]$candidate.RelativeBasePath))
        $newZeroFiles = @($afterFiles | Where-Object { $beforeFiles -notcontains $_.FullName.ToLowerInvariant() -and $_.Length -eq 0 })
        if ($newZeroFiles.Count -gt 0) {
            Write-Host 'Основной загрузчик оставил файл нулевого размера; он будет сохранён в карантине перед альтернативной попыткой.' -ForegroundColor Yellow
            $zeroQuarantine = Move-CandidateFilesToQuarantine -Queue @($candidate) -RootPath $script:outputDir
            if ($zeroQuarantine.Moved -gt 0) { Write-Host "Нулевой файл сохранён в карантине: $($zeroQuarantine.Path)" -ForegroundColor DarkGray }
            $afterFiles = @(Get-TrackAudioFiles -RootPath $script:outputDir -RelativeBasePath ([string]$candidate.RelativeBasePath))
        }
        $newFiles = @($afterFiles | Where-Object { $beforeFiles -notcontains $_.FullName.ToLowerInvariant() -and $_.Length -gt 0 })
        $verified = $null
        foreach ($file in $newFiles) {
            $probe = Test-AudioDuration -PythonExe $PythonExe -AudioPath $file.FullName -ExpectedDurationMs $candidate.DurationMs
            if ($probe.Success -and ($probe.ValidAgainstMetadata -or [double]$candidate.DurationMs -le 0)) {
                $verified = [pscustomobject]@{ File = $file; Probe = $probe }
                break
            }
            if (-not $probe.Success -or -not $probe.ValidAgainstMetadata) {
                if ($probe.Success) {
                    Write-Host ("Полученный файл подозрительно отличается по длительности ({0:N1} с); он будет сохранён в карантине перед альтернативной попыткой." -f $probe.DurationSeconds) -ForegroundColor Yellow
                } else {
                    Write-Host 'Не удалось проверить длительность нового файла; он будет сохранён в карантине перед альтернативной попыткой.' -ForegroundColor Yellow
                }
                $quarantined = Move-CandidateFilesToQuarantine -Queue @($candidate) -RootPath $script:outputDir
                if ($quarantined.Moved -gt 0) { Write-Host "Файл сохранён в карантине: $($quarantined.Path)" -ForegroundColor DarkGray }
            }
        }

        if ($null -ne $verified) {
            $detail = if ($verified.Probe.ValidAgainstMetadata) {
                "Проверка длительности пройдена: $([Math]::Round($verified.Probe.DurationSeconds,1)) с."
            } else {
                'Аудиофайл читается, но длительность в метаданных источника неизвестна; проверь вручную.'
            }
            $recoveryStatus = if ($verified.Probe.ValidAgainstMetadata) { 'Успешно восстановлен' } else { 'Скачан, нужна ручная проверка' }
            [void]$results.Add([pscustomobject]@{ TrackId = $candidate.TrackId; TrackKey = $candidate.TrackKey; Track = $candidate.TrackTitle; Status = $recoveryStatus; Method = 'Основной загрузчик'; Path = $verified.File.FullName; Details = $detail })
            Write-Host $detail -ForegroundColor Green
            continue
        }

        $stillExisting = @(Get-TrackAudioFiles -RootPath $script:outputDir -RelativeBasePath ([string]$candidate.RelativeBasePath))
        if ($stillExisting.Count -gt 0) {
            [void]$results.Add([pscustomobject]@{ TrackId = $candidate.TrackId; TrackKey = $candidate.TrackKey; Track = $candidate.TrackTitle; Status = 'Требует ручной проверки'; Method = 'Основной загрузчик'; Path = $stillExisting[0].FullName; Details = 'Файл появился, но его длительность не удалось подтвердить; он оставлен на диске.' })
            continue
        }

        if (-not $fallbackInitialized) {
            $fallback = Initialize-YtDlpRecovery -PythonExe $PythonExe
            $fallbackInitialized = $true
            if ($fallback.Enabled) { New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null }
        }
        if ($null -ne $fallback -and $fallback.Enabled) {
            try {
                $alternate = Invoke-YtDlpRecoveryTrack -Candidate $candidate -PythonExe $fallback.PythonExe -Browser $fallback.Browser -StagingRoot $stagingRoot
                if ($alternate.Success) {
                    [void]$results.Add([pscustomobject]@{ TrackId = $candidate.TrackId; TrackKey = $candidate.TrackKey; Track = $candidate.TrackTitle; Status = 'Успешно восстановлен'; Method = 'yt-dlp / резервный источник'; Path = $alternate.Path; Details = $alternate.Details })
                    Write-Host $alternate.Details -ForegroundColor Green
                    continue
                }
                $alternateDetails = $alternate.Details
                if ($alternate.Path) { $alternateDetails += " Путь: $($alternate.Path)" }
            } catch {
                $alternateDetails = $_.Exception.Message
            }
        } else {
            $alternateDetails = 'Резервный источник не был включён или не удалось установить yt-dlp.'
        }
        [void]$results.Add([pscustomobject]@{ TrackId = $candidate.TrackId; TrackKey = $candidate.TrackKey; Track = $candidate.TrackTitle; Status = 'Не удалось восстановить'; Method = 'Основной + резервный'; Path = ''; Details = "$alternateDetails; причина первой неудачи: $($pass.Text -join ' ')" })
        Write-Host "Не удалось восстановить: $($candidate.TrackTitle)" -ForegroundColor Red
    }

    $script:sourceUrl = $originalUrl
    $resultPath = Join-Path $LogsDir "recovery-results-$RunTimestamp.csv"
    $results.ToArray() | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
    "Очередь восстановления по логу: $PreviousLogPath" | Out-File -FilePath $script:logPath -Encoding utf8 -Append
    "Отчёт восстановления: $resultPath" | Out-File -FilePath $script:logPath -Encoding utf8 -Append
    Write-Host ''
    Write-Host 'Обработка очереди восстановления завершена.' -ForegroundColor Green
    Write-Host "Результаты по каждому треку: $resultPath" -ForegroundColor Green
    if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
        Write-Host "Файлы, не прошедшие проверку длительности или импорт в библиотеку, могут остаться в staging: $stagingRoot" -ForegroundColor Yellow
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

function Get-AudioFileSnapshot([string]$RootPath) {
    # Snapshot only audio files; covers, lyrics, logs and temporary metadata are excluded.
    $snapshot = @{}
    $audioExtensions = @('.m4a', '.mp3', '.flac', '.aac', '.ogg', '.opus', '.wav', '.wma', '.aiff', '.ape')

    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return ,$snapshot
    }

    $files = Get-ChildItem -LiteralPath $RootPath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $audioExtensions -contains $_.Extension.ToLowerInvariant() }

    foreach ($file in $files) {
        $snapshot[$file.FullName] = [pscustomobject]@{
            Length                = [long]$file.Length
            LastWriteTimeUtcTicks = [long]$file.LastWriteTimeUtc.Ticks
        }
    }

    return ,$snapshot
}

function Get-ReportedAudioPaths([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $paths = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    $extensionsPattern = '(?:m4a|mp3|flac|aac|ogg|opus|wav|wma|aiff|ape)'
    # Observed output: [1/1] [AAC 192kbps] Загружается D:\...\Track.m4a
    $pattern = '(?i)^\s*(?:\[\d+\s*/\s*\d+\]\s*)?(?:\[[^\]]+\]\s*)*(?:Загружается|Скачивается|Downloading|Download(?:ing)?)\s+(?<Path>.+\.' + $extensionsPattern + ')\s*$'

    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        if ($line -match $pattern) {
            $path = $Matches['Path'].Trim().Trim('"')
            try { $path = [System.IO.Path]::GetFullPath($path) } catch { }
            if (-not $seen.ContainsKey($path)) {
                $seen[$path] = $true
                [void]$paths.Add($path)
            }
        }
    }

    return @($paths.ToArray())
}

function Get-DownloadPassFileStats([hashtable]$Before, [hashtable]$After, [string]$Text) {
    $newAudioFiles = 0
    $modifiedAudioFiles = 0
    $zeroLengthAudioFiles = 0
    $reportedPaths = @(Get-ReportedAudioPaths -Text $Text)
    $reportedPathSet = @{}
    $reportedPathsMissing = 0
    $reportedPathsUnchanged = 0
    $outcomeRows = New-Object 'System.Collections.Generic.List[object]'

    foreach ($path in $After.Keys) {
        $current = $After[$path]
        $wasPresent = $Before.ContainsKey($path)
        $wasChanged = $false

        if ($wasPresent) {
            $previous = $Before[$path]
            $wasChanged = ($current.Length -ne $previous.Length) -or
                ($current.LastWriteTimeUtcTicks -ne $previous.LastWriteTimeUtcTicks)
        }

        if (-not $wasPresent -or $wasChanged) {
            if ($current.Length -le 0) {
                $zeroLengthAudioFiles++
            } elseif (-not $wasPresent) {
                $newAudioFiles++
            } else {
                $modifiedAudioFiles++
            }
        }
    }

    foreach ($reportedPath in $reportedPaths) {
        $reportedPathSet[$reportedPath] = $true
        $beforeExists = $Before.ContainsKey($reportedPath)
        $afterExists = $After.ContainsKey($reportedPath)
        $beforeBytes = $null
        $afterBytes = $null
        $lastWriteTime = $null
        $status = ''

        if ($beforeExists) { $beforeBytes = [long]$Before[$reportedPath].Length }
        if ($afterExists) {
            $afterFile = $After[$reportedPath]
            $afterBytes = [long]$afterFile.Length
            $lastWriteTime = $null
            $item = Get-Item -LiteralPath $reportedPath -ErrorAction SilentlyContinue
            if ($null -ne $item) { $lastWriteTime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
        }

        if (-not $afterExists) {
            $status = 'Не найден после прохода'
            $reportedPathsMissing++
        } elseif ($After[$reportedPath].Length -le 0) {
            $status = 'Нулевой размер'
        } elseif (-not $beforeExists) {
            $status = 'Создан во время прохода'
        } else {
            $previous = $Before[$reportedPath]
            $current = $After[$reportedPath]
            $changed = ($current.Length -ne $previous.Length) -or
                ($current.LastWriteTimeUtcTicks -ne $previous.LastWriteTimeUtcTicks)
            if ($changed) {
                $status = 'Изменён во время прохода'
            } else {
                $status = 'Изменение не обнаружено'
                $reportedPathsUnchanged++
            }
        }

        [void]$outcomeRows.Add([pscustomobject]@{
            Path                   = $reportedPath
            Status                 = $status
            ReportedByDownloader   = $true
            ExistedBefore          = $beforeExists
            BeforeBytes            = $beforeBytes
            ExistsAfter            = $afterExists
            AfterBytes             = $afterBytes
            LastWriteTime          = $lastWriteTime
        })
    }

    # Include new/changed audio files even when no corresponding path appeared in stdout.
    foreach ($path in $After.Keys) {
        if ($reportedPathSet.ContainsKey($path)) { continue }

        $current = $After[$path]
        $wasPresent = $Before.ContainsKey($path)
        $wasChanged = $false
        if ($wasPresent) {
            $previous = $Before[$path]
            $wasChanged = ($current.Length -ne $previous.Length) -or
                ($current.LastWriteTimeUtcTicks -ne $previous.LastWriteTimeUtcTicks)
        }
        if ($wasPresent -and -not $wasChanged) { continue }

        $beforeBytes = $null
        if ($wasPresent) { $beforeBytes = [long]$Before[$path].Length }
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        $lastWriteTime = $null
        if ($null -ne $item) { $lastWriteTime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }

        $status = if ($current.Length -le 0) {
            'Нулевой размер'
        } elseif (-not $wasPresent) {
            'Создан, путь не показан загрузчиком'
        } else {
            'Изменён, путь не показан загрузчиком'
        }

        [void]$outcomeRows.Add([pscustomobject]@{
            Path                   = $path
            Status                 = $status
            ReportedByDownloader   = $false
            ExistedBefore          = $wasPresent
            BeforeBytes            = $beforeBytes
            ExistsAfter            = $true
            AfterBytes             = [long]$current.Length
            LastWriteTime          = $lastWriteTime
        })
    }

    return [pscustomobject]@{
        NewAudioFiles          = $newAudioFiles
        ModifiedAudioFiles     = $modifiedAudioFiles
        ZeroLengthAudioFiles   = $zeroLengthAudioFiles
        ReportedAudioPaths     = $reportedPaths.Count
        ReportedPathsMissing   = $reportedPathsMissing
        ReportedPathsUnchanged = $reportedPathsUnchanged
        OutcomeRows            = @($outcomeRows.ToArray())
        OutcomeCsvPath         = $null
    }
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

    $beforeAudioFiles = Get-AudioFileSnapshot -RootPath $script:outputDir

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
    $afterAudioFiles = Get-AudioFileSnapshot -RootPath $script:outputDir
    $outputText = ($outputLines -join "`n")
    $fileStats = Get-DownloadPassFileStats -Before $beforeAudioFiles -After $afterAudioFiles -Text $outputText

    if (@($fileStats.OutcomeRows).Count -gt 0) {
        $passSlug = ($PassName -replace '[^\p{L}\p{Nd}_-]+', '_').Trim('_')
        $logDirectory = Split-Path -Parent $script:logPath
        $fileStats.OutcomeCsvPath = Join-Path $logDirectory "file-outcomes-$($script:timestamp)-$passSlug.csv"
        $fileStats.OutcomeRows | Export-Csv -LiteralPath $fileStats.OutcomeCsvPath -NoTypeInformation -Encoding UTF8
    }

    $statsLogLines = @(
        "Снимок аудиофайлов до/после прохода:"
        "Новых аудиофайлов с ненулевым размером: $($fileStats.NewAudioFiles)"
        "Изменённых аудиофайлов с ненулевым размером: $($fileStats.ModifiedAudioFiles)"
        "Новых/изменённых аудиофайлов нулевого размера: $($fileStats.ZeroLengthAudioFiles)"
        "Уникальных путей загрузки, указанных в выводе: $($fileStats.ReportedAudioPaths)"
        "Указанных путей, отсутствующих после прохода: $($fileStats.ReportedPathsMissing)"
        "Указанных путей без обнаруженного изменения: $($fileStats.ReportedPathsUnchanged)"
        "Точное число молча пропущенных файлов upstream не сообщает."
    )
    if (-not [string]::IsNullOrWhiteSpace($fileStats.OutcomeCsvPath)) {
        $statsLogLines += "CSV с пофайловыми результатами: $($fileStats.OutcomeCsvPath)"
    }
    $statsLogLines | Add-Content -LiteralPath $script:logPath -Encoding UTF8

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Text = $outputText
        FileStats = $fileStats
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

function Show-RunEnding([string]$Text, [int]$ExitCode, [object]$FileStats = $null) {
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

    if ($null -ne $FileStats) {
        Write-Host ''
        Write-Host 'Итоги по аудиофайлам (сравнение папки до и после прохода):' -ForegroundColor Cyan
        Write-Host "  Создано новых аудиофайлов: $($FileStats.NewAudioFiles)" -ForegroundColor Green
        Write-Host "  Изменено существовавших аудиофайлов: $($FileStats.ModifiedAudioFiles)"
        if ($FileStats.ZeroLengthAudioFiles -gt 0) {
            Write-Host "  Новых/изменённых аудиофайлов нулевого размера: $($FileStats.ZeroLengthAudioFiles)" -ForegroundColor Yellow
        }
        Write-Host "  Уникальных путей загрузки, показанных загрузчиком: $($FileStats.ReportedAudioPaths)"
        if ($FileStats.ReportedPathsMissing -gt 0) {
            Write-Host "  Указанных путей не найдено после прохода: $($FileStats.ReportedPathsMissing)" -ForegroundColor Yellow
        }
        if ($FileStats.ReportedPathsUnchanged -gt 0) {
            Write-Host "  Указанных путей без обнаруженного изменения файла: $($FileStats.ReportedPathsUnchanged)" -ForegroundColor Yellow
        }
        if (-not [string]::IsNullOrWhiteSpace($FileStats.OutcomeCsvPath)) {
            Write-Host "  Подробный CSV по каждому пути: $($FileStats.OutcomeCsvPath)" -ForegroundColor DarkGray
        }
        Write-Host '  Точное число молча пропущенных существующих файлов загрузчик не сообщает.' -ForegroundColor DarkGray
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
Write-Host '  8 — повторить незавершённую загрузку по предыдущему логу'
Write-Host '  9 — восстановить все неудачные треки по очереди (основной загрузчик → резервный источник)'
Write-Host '  0 — выход'
$actionChoice = Read-MenuChoice 'Выбор' @('0','1','2','3','4','5','6','7','8','9') '1'
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
if ($actionChoice -eq '8' -or $actionChoice -eq '9') {
    $script:resumeSettings = Select-PreviousDownloadLog
    if ($null -eq $script:resumeSettings) {
        Read-Host 'Не удалось выбрать подходящий лог. Нажми Enter для выхода' | Out-Null
        exit 1
    }
    $script:resumeFromLog = $script:resumeSettings.LogPath
    Write-Host ''
    if ($actionChoice -eq '8') {
        Write-Host 'Повтор будет запущен по параметрам из выбранного лога:' -ForegroundColor Cyan
        Write-Host 'Повтор использует --skip-existing; отсутствующие треки будут обработаны снова, существующие обычно пропускаются.' -ForegroundColor Gray
    } else {
        Write-Host 'Будет сформирована очередь проблемных треков из выбранного лога.' -ForegroundColor Cyan
        Write-Host 'Каждый трек сначала проверит основной загрузчик; оставшиеся ошибки можно попробовать скачать через yt-dlp по одному.' -ForegroundColor Gray
    }
    Write-Host "Лог:    $($script:resumeSettings.LogPath)" -ForegroundColor DarkGray
    Write-Host "Ссылка: $($script:resumeSettings.Url)"
    Write-Host "Папка:  $($script:resumeSettings.OutputDir)"
    Write-Host "Качество по умолчанию: $($script:resumeSettings.FormatName)"
    $confirmed = Read-MenuChoice 'Продолжить? (0 — отмена, 1 — да)' @('0','1') '1'
    if ($confirmed -ne '1') { exit 0 }
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
if ((@('8','9') -contains $actionChoice) -and $null -ne $script:resumeSettings) {
    $script:sourceUrl = $script:resumeSettings.Url
    $script:outputDir = $script:resumeSettings.OutputDir
    Write-Host 'Для выбранного режима используются ссылка и папка из лога.' -ForegroundColor Gray
} else {
    $sourceUrl = Read-DefaultText 'Ссылка на плейлист/альбом/исполнителя/отдельный трек' $defaultUrl
    $script:sourceUrl = $sourceUrl
    $script:outputDir = Read-DefaultText 'Папка для сохранения' $defaultDir
}

Write-Host ''
Write-Host 'Выбор качества/формата:' -ForegroundColor Cyan
if ($script:supportsForceMp3) {
    Write-Host '  1 — MP3 (только если поддерживается установленной версией)'
    Write-Host '  2 — AAC/M4A 192 кбит/с (как в исходной команде, без повторного перекодирования)'
    Write-Host '  3 — FLAC (если lossless доступен для трека и аккаунта)'
    $formatDefaultChoice = '2'
    if ((@('8','9') -contains $actionChoice) -and $null -ne $script:resumeSettings) {
        if ($script:resumeSettings.ForceMp3) { $formatDefaultChoice = '1' }
        elseif ($script:resumeSettings.QualityValue -eq '2') { $formatDefaultChoice = '3' }
    }
    $formatChoice = Read-MenuChoice 'Формат' @('1','2','3') $formatDefaultChoice
    switch ($formatChoice) {
        '1' { $script:quality = '1'; $script:forceMp3 = $true;  $script:formatName = 'MP3' }
        '2' { $script:quality = '1'; $script:forceMp3 = $false; $script:formatName = 'AAC/M4A 192 kbps' }
        '3' { $script:quality = '2'; $script:forceMp3 = $false; $script:formatName = 'FLAC' }
    }
} else {
    Write-Host '  1 — AAC/M4A 192 кбит/с (как в исходной команде)'
    Write-Host '  2 — FLAC (если lossless доступен для трека и аккаунта)'
    Write-Host '  (Установленная версия не предоставляет --force-mp3; MP3 не будет выдаваться за исходный формат.)' -ForegroundColor DarkYellow
    $formatDefaultChoice = '1'
    if ((@('8','9') -contains $actionChoice) -and $null -ne $script:resumeSettings -and $script:resumeSettings.QualityValue -eq '2') { $formatDefaultChoice = '2' }
    if ((@('8','9') -contains $actionChoice) -and $null -ne $script:resumeSettings -and $script:resumeSettings.ForceMp3) {
        Write-Host 'В старом логе указан MP3, но текущий загрузчик не поддерживает --force-mp3. Повтор будет в AAC/M4A или FLAC.' -ForegroundColor Yellow
    }
    $formatChoice = Read-MenuChoice 'Формат' @('1','2') $formatDefaultChoice
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
    if ($actionChoice -eq '8') { [void](Move-ZeroLengthAudioToQuarantine -RootPath $script:outputDir) }
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
    if (-not [string]::IsNullOrWhiteSpace($script:resumeFromLog)) {
        "Повторная попытка по предыдущему логу: $($script:resumeFromLog)" | Out-File -FilePath $script:logPath -Encoding utf8 -Append
    }
    if ($actionChoice -eq '9') {
        'Режим: последовательное восстановление треков (пункт 9)' | Out-File -FilePath $script:logPath -Encoding utf8 -Append
    }

    Write-Host ''
    Write-Host "Формат: $($script:formatName)" -ForegroundColor Green
    Write-Host "Папка:  $($script:outputDir)"
    Write-Host "Лог:    $($script:logPath)"
    Write-Host 'Уже существующие треки будут пропускаться. Повторные проходы используют тот же механизм защиты от дубликатов.' -ForegroundColor Cyan
    Write-Host 'Для остановки нажми Ctrl+C. Токен передаётся загрузчику как аргумент командной строки и поэтому может быть виден локальным средствам просмотра процессов.' -ForegroundColor DarkGray

    if ($actionChoice -eq '9') {
        $recoveryPython = Find-PythonForDownloader -ExecutablePath $script:exePath -FallbackExecutablePath $defaultExe
        Invoke-RetryFailedTracks -PreviousLogPath $script:resumeFromLog -PythonExe $recoveryPython -LogsDir $logsDir -RunTimestamp $script:timestamp
    } else {
        $script:sourceInventoryRecords = @()
        $script:previousSourceInventory = @()
        $script:sourceBaselinePath = $null
        $script:hasPreviousSourceInventory = $false
        $script:sourceInventorySucceeded = $false

        if (@('1','3') -contains $actionChoice) {
            $inventoryPython = Find-PythonForDownloader -ExecutablePath $script:exePath -FallbackExecutablePath $defaultExe
            Write-Host ''
            Write-Host 'Сверяю список треков источника для отчёта об удалённых и неудачных композициях...' -ForegroundColor Cyan
            $inventoryResult = Invoke-SourceInventory -SourceUrl $script:sourceUrl -PythonExe $inventoryPython
            if ($inventoryResult.Success -and $inventoryResult.Count -gt 0) {
                $script:sourceInventorySucceeded = $true
                $script:sourceInventoryRecords = @($inventoryResult.Tracks)
                $sourceKey = Get-SourceSnapshotKey -SourceUrl $script:sourceUrl
                $script:sourceBaselinePath = Join-Path $logsDir "source-baseline-$sourceKey.csv"
                $runInventoryPath = Join-Path $logsDir "source-inventory-$($script:timestamp).csv"
                $script:sourceInventoryRecords | Export-Csv -LiteralPath $runInventoryPath -NoTypeInformation -Encoding UTF8
                if (Test-Path -LiteralPath $script:sourceBaselinePath -PathType Leaf) {
                    $script:previousSourceInventory = @(Import-Csv -LiteralPath $script:sourceBaselinePath -ErrorAction SilentlyContinue)
                    $script:hasPreviousSourceInventory = $true
                }
                "Снимок источника: $runInventoryPath" | Out-File -FilePath $script:logPath -Encoding utf8 -Append
                Write-Host "В источнике найдено треков: $($script:sourceInventoryRecords.Count)" -ForegroundColor Green
                Write-Host "Снимок запуска: $runInventoryPath" -ForegroundColor DarkGray
            } else {
                $inventoryError = if ($inventoryResult.Success) { 'Список источника вернулся пустым; снимок не обновлён, чтобы не помечать все старые треки как удалённые.' } else { [string]$inventoryResult.Error }
                Write-Host "Не удалось получить полный список треков источника: $inventoryError" -ForegroundColor Yellow
                Write-Host 'Загрузка продолжится; отчёт об удалённых из источника композициях в этом запуске будет неполным.' -ForegroundColor Gray
                "Не удалось получить снимок источника: $inventoryError" | Out-File -FilePath $script:logPath -Encoding utf8 -Append
            }
        }

        $firstPass = Invoke-DownloadPass -PassName 'ПРОХОД 1' -QualityValue $script:quality
    $hasErrors = Show-RunEnding -Text $firstPass.Text -ExitCode $firstPass.ExitCode -FileStats $firstPass.FileStats
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
                $hasErrors = Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode -FileStats $lastPass.FileStats
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
                $stillErrors = Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode -FileStats $lastPass.FileStats
                if ($stillErrors) {
                    $fallbackChoice = Read-MenuChoice 'Остались ошибки. Попробовать AAC/M4A 192 кбит/с для ещё не скачанных треков? (1 — да, 0 — нет)' @('0','1') '1'
                    if ($fallbackChoice -eq '1') {
                        $lastPass = Invoke-DownloadPass -PassName 'РЕЗЕРВНЫЙ ПРОХОД AAC/M4A 192' -QualityValue '1'
                        [void](Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode -FileStats $lastPass.FileStats)
                    }
                }
            } elseif ($retryChoice -eq '2') {
                $lastPass = Invoke-DownloadPass -PassName 'РЕЗЕРВНЫЙ ПРОХОД AAC/M4A 192' -QualityValue '1'
                [void](Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode -FileStats $lastPass.FileStats)
            }
        } else {
            $retryChoice = Read-MenuChoice 'Повторить один раз в том же качестве? (0 — нет, 1 — да)' @('0','1') '1'
            if ($retryChoice -eq '1') {
                $lastPass = Invoke-DownloadPass -PassName 'ПОВТОРНЫЙ ПРОХОД' -QualityValue $script:quality
                [void](Show-RunEnding -Text $lastPass.Text -ExitCode $lastPass.ExitCode -FileStats $lastPass.FileStats)
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
    if ($script:sourceInventorySucceeded) {
        [void](Write-SourceStatusReport -CurrentInventory $script:sourceInventoryRecords -PreviousInventory $script:previousSourceInventory -HasPreviousInventory $script:hasPreviousSourceInventory -SourceUrl $script:sourceUrl -OutputDir $script:outputDir -LogText $allLogText -LogsDir $logsDir -RunTimestamp $script:timestamp -BaselinePath $script:sourceBaselinePath)
    }

    Write-Host 'Если отдельный трек всё равно не скачался, запусти этот же скрипт с прямой ссылкой на сам трек — так проще отделить проблему конкретного трека от проблемы всего плейлиста.' -ForegroundColor DarkGray
    }
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
