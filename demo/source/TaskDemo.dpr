program TaskDemo;

{$include CompilerOptions.inc}

uses
  WinMemMgr,
  MemTest,
  //VclFixPack,
  CorrectLocale,
  //StackTrace,
  Windows,
  Forms,
  MainForm in 'MainForm.pas' {fMainForm},
  TaskUtils in 'TaskUtils.pas';

{$R *.res}

// IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE = $8000: Terminal server aware
// IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE = $40: Address Space Layout Randomization (ASLR) für dieses EXE enablen
// IMAGE_DLLCHARACTERISTICS_NX_COMPAT = $100: Data Execution Prevention (DEP) für dieses EXE enablen
{$SetPeOptFlags $8140}

// IMAGE_FILE_LARGE_ADDRESS_AWARE: verträgt Pointer > 2GB
{$SetPeFlags IMAGE_FILE_LARGE_ADDRESS_AWARE}

begin
  Application.Initialize;
  Application.CreateForm(TfMainForm, fMainForm);
  Application.Run;
end.
