unit MsgBox;

{
  Reduced example of a better message box wrapper (compared with TApplication.MessageBox):
  - Buttons are labeled according to the current UI language of the calling thread.
  - The display position is centered to the current active window, not to the monitor.
  - TaskDialog is used instead of MessageBox, as MessageBox does not scale correctly on HighDPI monitors with
	DPI_AWARENESS_CONTEXT_UNAWARE_GDISCALED.

  Notes:
  - Controlling the button captions in the message box is needed when your application can be switched between different
	languages, by the user, at runtime. Part of such switch is calling SetProcessPreferredUILanguages(), so that system
	message boxes (like File selection, Printer setup) are also using the language of your application's GUI.
}

{$include CompilerOptions.inc}

interface

uses Windows;

type
  TMsgBox = record
  public
	class function Show(const Msg: string; Buttons: uint = MB_ICONINFORMATION or MB_OK; const Caption: string = 'Native modal message box'): integer; static;
	class procedure ShowInfo(const Msg: string); static;
  end;


{############################################################################}
implementation
{############################################################################}

uses
  CommCtrl,
  SysUtils,
  Forms;


{ TMsgBox }

 //=============================================================================
 // Displays the Windows "TaskDialog" message box.
 // The buttons in the dialog are labeled according to the GUI language of the calling thread, and the dialog is
 // centered in front of the application's active window.
 // If the dialog is closed by ESC, IDCANCEL is returned.
 // In <Buttons> you pass the same values as for MsgBox(,,,uType).
 // Note: MB_ABORTRETRYIGNORE is handled as MB_RETRYCANCEL.
 //===================================================================================================================
class function TMsgBox.Show(const Msg: string; Buttons: uint; const Caption: string): integer;

  procedure _HResChk(res: HRESULT);
  begin
	if res <> S_OK then SysUtils.RaiseLastOSError(DWORD(res));
  end;

  procedure _InitCfg(out Cfg: CommCtrl.TTaskDialogConfig);
  var
	Btn: DWORD;
	DefBtn2: DWORD;
	ID: LPCWSTR;
  begin
	FillChar(Cfg, sizeof(Cfg), 0);
	Cfg.cbSize := sizeof(Cfg);
	Cfg.hwndParent := Application.ActiveFormHandle;
	Cfg.pszContent := PWideChar(Msg);
	if Caption <> '' then
	  Cfg.pszWindowTitle := PWideChar(Caption);

	Cfg.dwFlags := TDF_POSITION_RELATIVE_TO_WINDOW or TDF_ALLOW_DIALOG_CANCELLATION;
	if Application.UseRightToLeftReading then
	  Cfg.dwFlags := Cfg.dwFlags or TDF_RTL_LAYOUT;

	case Buttons and MB_TYPEMASK of
	MB_OKCANCEL:    begin Btn := TDCBF_OK_BUTTON or TDCBF_CANCEL_BUTTON; DefBtn2 := TDCBF_CANCEL_BUTTON; end;
	MB_YESNOCANCEL: begin Btn := TDCBF_YES_BUTTON or TDCBF_NO_BUTTON or TDCBF_CANCEL_BUTTON; DefBtn2 := TDCBF_CANCEL_BUTTON; end;
	MB_YESNO:       begin Btn := TDCBF_YES_BUTTON or TDCBF_NO_BUTTON; DefBtn2 := TDCBF_NO_BUTTON; end;
	MB_ABORTRETRYIGNORE,	// IGNORE and ABORT are not supported
	MB_RETRYCANCEL: begin Btn := TDCBF_RETRY_BUTTON or TDCBF_CANCEL_BUTTON; DefBtn2 := TDCBF_CANCEL_BUTTON; end;
	else {MB_OK:}   begin Btn := TDCBF_OK_BUTTON; DefBtn2 := TDCBF_OK_BUTTON; end;
	end;

	Cfg.dwCommonButtons := Btn;
	if Buttons and MB_DEFMASK > MB_DEFBUTTON1 then
	  Cfg.nDefaultButton := DefBtn2;

	case Buttons and MB_ICONMASK of
	MB_ICONERROR:       ID := IDI_ERROR;
	MB_ICONQUESTION:    ID := IDI_QUESTION;
	MB_ICONWARNING:     ID := IDI_WARNING;
	MB_ICONINFORMATION: ID := IDI_INFORMATION;
	else exit;
	end;

	_HResChk( CommCtrl.LoadIconMetric(0, ID, CommCtrl.LIM_LARGE, Cfg.hMainIcon) );
	Cfg.dwFlags := Cfg.dwFlags or TDF_USE_HICON_MAIN;
  end;

var
  Init: TInitCommonControlsEx;
  Cfg: CommCtrl.TTaskDialogConfig;
  WindowList: Forms.TTaskWindowList;
  FocusState: Forms.TFocusState;
begin
  // the wrapper for LoadIconMetric() in CommCtrl.pas dont call InitComCtl, like done in the TaskDialogIndirect wrapper:
  Init.dwSize := sizeof(Init);
  Init.dwICC := ICC_STANDARD_CLASSES;
  CommCtrl.InitCommonControlsEx(Init);

  _InitCfg(Cfg);

  // Disable all other top-level windows, like TApplication.MessageBox() or TCommonDialog.TaskModalDialog().
  // (Strange things: Both do not call "ReleaseCapture" and "Application.ModalStarted", as done in TCustomForm.ShowModal.
  // So why is ShowModal doing this?)

  WindowList := Forms.DisableTaskWindows(Cfg.hwndParent);
  FocusState := Forms.SaveFocusState;
  try
	_HResChk( CommCtrl.TaskDialogIndirect(Cfg, @Result, nil, nil) );
  finally
	if Cfg.hMainIcon <> 0 then Win32Check(Windows.DestroyIcon(Cfg.hMainIcon));
	Forms.EnableTaskWindows(WindowList);
	Windows.SetActiveWindow(Cfg.hwndParent);
	Forms.RestoreFocusState(FocusState);
  end;
end;


 //===================================================================================================================
 //===================================================================================================================
class procedure TMsgBox.ShowInfo(const Msg: string);
begin
  TMsgBox.Show(Msg, MB_ICONINFORMATION or MB_OK);
end;

end.
