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
  TaskUtils in 'TaskUtils.pas',
  MsgBox in 'MsgBox.pas';

{$R *.res}

// IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE = $8000: Terminal server aware
// IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE = $40: Address Space Layout Randomization (ASLR) enabled
// IMAGE_DLLCHARACTERISTICS_NX_COMPAT = $100: Data Execution Prevention (DEP) enabled
{$SetPeOptFlags $8140}

// IMAGE_FILE_LARGE_ADDRESS_AWARE: may use heap/code above 2GB
{$SetPeFlags IMAGE_FILE_LARGE_ADDRESS_AWARE}

begin
  Application.Initialize;
  Application.CreateForm(TfMainForm, fMainForm);
  Application.Run;
end.
