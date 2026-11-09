#define AppName "Yandex Music Downloader Plus"
#define AppVersion "0.2.0-preview.1"
#define AppPublisher "Andreyfdfd"
#ifndef PayloadDir
  #define PayloadDir "..\artifacts\payload"
#endif
#ifndef OutputDir
  #define OutputDir "..\artifacts\output"
#endif

[Setup]
AppId={{7D6408D0-DAA1-4CE4-98F8-C3DE9B6D1B4C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/Andreyfdfd/YandexMusicDownloaderPlus
DefaultDirName={localappdata}\Programs\YandexMusicDownloaderPlus
DefaultGroupName=Yandex Music Downloader Plus
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=YandexMusicDownloaderPlus-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
UninstallDisplayName=Yandex Music Downloader Plus
UninstallDisplayIcon={app}\runtime\Scripts\yandex-music-downloader.exe
CloseApplications=no

[Types]
Name: "full"; Description: "Полная установка"
Name: "compact"; Description: "Основная программа"
Name: "custom"; Description: "Выбор компонентов"; Flags: iscustom

[Components]
Name: "core"; Description: "Downloader Plus и встроенный Python 3.14"; Types: full compact custom; Flags: fixed
Name: "fallback"; Description: "Предустановить резервный источник yt-dlp и плагин Яндекс Музыки"; Types: full
Name: "docs"; Description: "Инструкции и сведения о проекте"; Types: full custom

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Ярлыки:"
Name: "createmusicfolder"; Description: "Создать выбранную папку для музыки сразу после установки"; GroupDescription: "Музыкальная библиотека:"

[Dirs]
Name: "{app}\logs"

[Files]
Source: "{#PayloadDir}\YandexMusicDownloader.ps1"; DestDir: "{app}"; Components: core; Flags: ignoreversion
Source: "{#PayloadDir}\Запустить_загрузку.bat"; DestDir: "{app}"; Components: core; Flags: ignoreversion
Source: "{#PayloadDir}\tools\source_inventory.py"; DestDir: "{app}\tools"; Components: core; Flags: ignoreversion
Source: "{#PayloadDir}\runtime\*"; DestDir: "{app}\runtime"; Components: core; Excludes: "Optional\Lib\site-packages\*"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\runtime\Optional\Lib\site-packages\*"; DestDir: "{app}\runtime\Optional\Lib\site-packages"; Components: fallback; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\README.md"; DestDir: "{app}\docs"; Components: docs; Flags: ignoreversion
Source: "{#PayloadDir}\ПРОЧТИ_МЕНЯ.txt"; DestDir: "{app}\docs"; Components: docs; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Yandex Music Downloader Plus\Downloader Plus"; Filename: "{app}\Запустить_загрузку.bat"; Components: core
Name: "{autodesktop}\Downloader Plus"; Filename: "{app}\Запустить_загрузку.bat"; Components: core; Tasks: desktopicon

[Run]
Filename: "{app}\Запустить_загрузку.bat"; Description: "Запустить Yandex Music Downloader Plus"; Flags: postinstall nowait skipifsilent unchecked; Components: core

[Code]
var
  MusicFolderPage: TInputDirWizardPage;

procedure InitializeWizard();
begin
  MusicFolderPage := CreateInputDirPage(
    wpSelectTasks,
    'Папка для музыки',
    'Выберите, куда сохранять загруженные композиции',
    'По умолчанию используется папка Music в вашем профиле Windows (обычно диск C:). При необходимости выберите другой диск или каталог.',
    False,
    ''
  );
  MusicFolderPage.Add('Путь к музыкальной библиотеке:');
  MusicFolderPage.Values[0] := ExpandConstant('{userprofile}\Music');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  MusicPath: String;
  SettingsDir: String;
begin
  if CurStep = ssPostInstall then
  begin
    MusicPath := Trim(MusicFolderPage.Values[0]);
    if MusicPath = '' then
      MusicPath := ExpandConstant('{userprofile}\Music');

    if WizardIsTaskSelected('createmusicfolder') then
    begin
      if not ForceDirectories(MusicPath) then
        MsgBox('Не удалось создать папку для музыки: ' + MusicPath + #13#10 +
          'Проверьте путь и права доступа. Загрузчик всё равно сможет создать папку при первом запуске.',
          mbError, MB_OK);
    end;

    SettingsDir := ExpandConstant('{userappdata}\YandexMusicDownloaderPlus');
    if ForceDirectories(SettingsDir) then
    begin
      if not SaveStringToFile(AddBackslash(SettingsDir) + 'music-path.txt', MusicPath + #13#10, False) then
        MsgBox('Не удалось сохранить выбранную папку музыки. При первом запуске её можно будет указать вручную.',
          mbInformation, MB_OK);
    end
    else
      MsgBox('Не удалось сохранить настройку музыкальной папки. При первом запуске её можно будет указать вручную.',
        mbInformation, MB_OK);
  end;
end;
