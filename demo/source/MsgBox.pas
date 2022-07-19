unit MsgBox;

{
  Reduced example of a better message box wrapper (compared with TApplication.MessageBox):
  - Buttons are labeled according to the current UI language of the GUI thread.
  - The display position is centered to the current active window, not to the monitor.
  - The owning top-level window may also be a non-delphi dialog

  In this demo, tthis is an example of an external Windows component that uses its own modal message loop.
}

{$include CompilerOptions.inc}

interface

uses Windows;

type
  TMsgBox = record
  strict private
	class var FHook: HHOOK;
	class function HookProc(Code: integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall; static;
  public
	class function Show(const Msg: string; Buttons: integer = MB_ICONINFORMATION or MB_OK; const Caption: string = 'Native modal message box'): integer; static;
	class procedure ShowInfo(const Msg: string); static;
  end;


{############################################################################}
implementation
{############################################################################}

uses Forms;


{$if not declared(GetThreadUILanguage)}
function GetThreadUILanguage: LANGID; stdcall; external Windows.kernel32 name 'GetThreadUILanguage';
{$ifend}


{ TMsgBox }

 //=============================================================================
 // Callback for a WH_CBT hook, to center the message box with regards to its parent window.
 //=============================================================================
class function TMsgBox.HookProc(Code: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT;

  procedure _CenterOnParent(CreateData: PCreateStruct); inline;
  var
	ParentRect: TRect;
  begin
	if Windows.GetWindowRect(CreateData.hwndParent, ParentRect) then begin
	  CreateData.X := ParentRect.Left + ((ParentRect.Right - ParentRect.Left) - CreateData.cx) div 2;
	  CreateData.Y := ParentRect.Top + ((ParentRect.Bottom - ParentRect.Top) - CreateData.cy) div 2;
	end;
  end;

begin
  // first call other hooks in the chain:
  Result := Windows.CallNextHookEx(0, Code, wParam, lParam);

  if Code = HCBT_CREATEWND then begin
	// deregister as soon as possible, to only handle the first window created after the hook is installed:
	Assert(FHook <> 0);
	Windows.UnhookWindowsHookEx(FHook);
	FHook := 0;
	// now center the message box:
	_CenterOnParent(PCBTCreateWnd(lParam).lpcs);
  end;
end;


 //===================================================================================================================
 // Shows <Msg> using the standard Windows message box.
 //===================================================================================================================
class function TMsgBox.Show(const Msg: string; Buttons: integer; const Caption: string): integer;
var
  Wnd: HWND;
  WindowList: Forms.TTaskWindowList;
  FocusState: Forms.TFocusState;
begin
  Assert(Windows.GetCurrentThreadId = System.MainThreadID);

  Buttons := Buttons and (Windows.MB_TYPEMASK or Windows.MB_ICONMASK or Windows.MB_DEFMASK) or MB_TASKMODAL;

  if Application.UseRightToLeftReading then Buttons := Buttons or Windows.MB_RTLREADING;

  // Disable all other top-level windows, like TApplication.MessageBox() or TCommonDialog.TaskModalDialog().
  // (Strange things: Both do not call "ReleaseCapture" and "Application.ModalStarted", as done in TCustomForm.ShowModal.
  // So why is ShowModal doing this?)

  Wnd := Application.ActiveFormHandle;
  WindowList := Forms.DisableTaskWindows(Wnd);
  FocusState := Forms.SaveFocusState;
  try

	Assert(FHook = 0);
	FHook := Windows.SetWindowsHookEx(WH_CBT, TMsgBox.HookProc, 0, System.MainThreadID);

	Result := Windows.MessageBoxEx(Wnd, PChar(Msg), PChar(Caption), Buttons, GetThreadUILanguage);

	//  normally already done within the hook:
	if FHook <> 0 then begin
	  Windows.UnhookWindowsHookEx(FHook);
	  FHook := 0;
	end;

  finally
	Forms.EnableTaskWindows(WindowList);
	Windows.SetActiveWindow(Wnd);
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

