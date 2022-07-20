unit GuiTasks;

{
  Add-on for the "Tasks" unit:

  - TGuiThread: Provides methods that can be used by any thread to inject calls into the GUI thread.

  This unit enables ITask.Wait do perform a "modal" wait when called from the GUI thread. If not included in the
  project, ITask.Wait just blocks the GUI thread which may lead to a dead-lock is the task uses TGuiThread.Perform.

  This means:

  - During the wait, certain Windows messages are still processed (WM_PAINT, WM_TIMER, posted messages). This allows
	windows to be repainted and it allows tasks to perform GUI operations via TGuiThread.Perform.

  - During the wait, all top-level windows of the application are disabled, to prevent most reentrancy issues if
	some task (or a paint handler or a timer handler) displays a modal dialog.

  See also: https://devblogs.microsoft.com/oldnewthing/tag/modality
}

{$include LibOptions.inc}
{$ScopedEnums on}

interface

uses Windows, WinSlimLock, WindowsSynchronization, Tasks;

type
  //===================================================================================================================
  // References a named or anonymous method/function/procedure suitable for execution by TGuiThread.Perform().
  //===================================================================================================================
  IGuiProcRef = reference to procedure;

  //===================================================================================================================
  // Same as IGuiProcRef, but avoids the lengthy compiler-generated code at the call site when using a named method.
  //===================================================================================================================
  TGuiProc = procedure of object;


  //===================================================================================================================
  // Represents the GUI thread (or the main thread of the program according to System.MainThreadID).
  // All public methods are thread-safe.
  //===================================================================================================================
  TGuiThread = record
  strict private
	type
	  self = TGuiThread;

	  // type of a local variable inside Perform(): forms a queue of waiting calls
	  PActionCtx = ^TActionCtx;
	  TActionCtx = record
		FAction: IGuiProcRef;
		FNext: PActionCtx;
		FDone: TEvent;
	  end;

	  TQueue = record
	  strict private
		FFirst: PActionCtx;
		FLast: PActionCtx;
	  public
		procedure Append(Item: PActionCtx); inline;
		function Extract: PActionCtx; inline;
		function Dequeue(Item: PActionCtx): boolean;
	  end;

	class var
	  FHook: HHOOK;
	  FQueue: TQueue;					// queue for transferring calls from Perform() to MsgHook()
	  FQueueLock: TSlimRWLock;			// serializes access to FQueue
	class function MsgHook(Code: int32; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall; static;
  private
	class procedure InstallHook; static;
	class procedure UninstallHook; static;
  public
	// This method causes the GUI thread to execute <Action>. To do this, Perform waits until the GUI thread wants to
	// extract a Windows message from its message queue and lets it execute <Action> at this point.
	// <CancelObj> should be the cancel object of the Perform-calling task (see the following note on avoiding
	// deadlocks).
	// If <CancelObj> is set already before the actual start of <Action>, the GUI thread will not be waited for and
	// Perform returns without <Action> being executed.
	// If <CancelObj> is set after the actual start of <Action>, this has no effect on Perform.
	// The return value is false if <Action> was not executed due to <CancelObj>, otherwise true.
	// It is guaranteed that <Action> will no longer run after Perform() has returned.
	//
	// Deadlock avoidance:
	// If the GUI thread uses ITask.Wait, TThreadPool.Wait or TThreadPool.Destroy to wait for a task that calls Perform,
	// a deadlock occurs because both threads are waiting crosswise for each other. The GUI thread can only safely wait
	// for tasks if it has already called ITask.CancelObj.Cancel for the respective tasks: This causes the Perform
	// method (called by one such task) to return immediately, which in turn gives the task a chance to exit, which
	// ultimately allows the GUI thread to get out of the wait call.
	// Note: If this method is called by the GUI thread itself, <Action> is just called, without cross-thread
	// synchronization, and true is returned.
	class function Perform(Action: TGuiProc; CancelObj: ICancel): boolean; overload; static;
	class function Perform(const Action: IGuiProcRef; CancelObj: ICancel): boolean; overload; static;

	// This method is used by ITask.Wait() for the GUI thread. It will wait for <Handle> to become signaled, but
	// is simultaneously dispatching a limited range of Windows messages (timer, paint, posted messages).
	// (posted messages are messages create by PostThreadMessage() or PostMessage(NULL, ...)).
	// Could also be used by other application code.
	class procedure Wait(Handle: THandle; TimeoutMillisecs: uint32); static;
  end;


{############################################################################}
implementation
{############################################################################}

uses Messages, SysUtils, Classes, Forms, TimeoutUtil;


{ TGuiThread.TQueue }

 //===================================================================================================================
 // Append the item the the end of the queue.
 //===================================================================================================================
procedure TGuiThread.TQueue.Append(Item: PActionCtx);
begin
  if FFirst = nil then FFirst := Item
  else FLast.FNext := Item;
  FLast := Item;
end;


 //===================================================================================================================
 // Extract the first item from the queue. Returns nil is the queue is empty.
 //===================================================================================================================
function TGuiThread.TQueue.Extract: PActionCtx;
begin
  Result := FFirst;
  if Result <> nil then begin
	FFirst := Result.FNext;
  end;
end;


 //===================================================================================================================
 // Extract the given item from the queue. Returns true if the item is found and extracted, else false.
 //===================================================================================================================
function TGuiThread.TQueue.Dequeue(Item: PActionCtx): boolean;
var
  tmp: ^PActionCtx;
begin
  tmp := @FFirst;
  while tmp^ <> nil do begin
	if tmp^ = Item then begin
	  // found => dequeue:
	  tmp^ := tmp^^.FNext;
	  exit(true);
	end;
	tmp := @tmp^^.FNext;
  end;
  exit(false)
end;


{ TGuiThread }

 //===================================================================================================================
 // See description in interface section.
 //===================================================================================================================
class function TGuiThread.Perform(Action: TGuiProc; CancelObj: ICancel): boolean;
var
  tmp: IGuiProcRef;
begin
  tmp := Action;
  Result := self.Perform(tmp, CancelObj);
end;


 //===================================================================================================================
 // See description in interface section.
 //===================================================================================================================
class function TGuiThread.Perform(const Action: IGuiProcRef; CancelObj: ICancel): boolean;
var
  ActionCtx: TActionCtx;
begin
  Assert(not System.IsConsole);
  Assert(Assigned(Action));

  if Windows.GetCurrentThreadId = System.MainThreadID then begin
	// called from the GUI thread => no synchronisation needed:
	Action();
	exit(true);
  end;

  Assert(Assigned(CancelObj));

  ActionCtx.FAction := Action;
  ActionCtx.FDone := TEvent.Create(true);
  ActionCtx.FNext := nil;

  try

	// append to work queue:

	FQueueLock.AcquireExclusive;
	try
	  if FHook = 0 then begin
		FHook := Windows.SetWindowsHookEx(WH_GETMESSAGE, self.MsgHook, 0, System.MainThreadID);
	  end;

	  FQueue.Append(@ActionCtx);
	finally
	  FQueueLock.ReleaseExclusive;
	end;

	// trigger the hook in the GUI thread:
	Windows.PostThreadMessage(System.MainThreadID, WM_NULL, 0, 0);

	// Waiting only for ActionCtx.FDone would cause a deadlock if the GUI thread is calling TThreadPool.Destroy or
	// TThreadPool.Wait, since both do not execute the message hook!

	if TWaitHandle.WaitAny([ActionCtx.FDone.Handle, CancelObj.CancelWH.Handle], INFINITE) = 0 then
	  exit(true);

	// if the action is still in the queue then remove it and return false:
	FQueueLock.AcquireExclusive;
	try
	  if FQueue.Dequeue(@ActionCtx) then exit(false);
	finally
	  FQueueLock.ReleaseExclusive;
	end;

	// GUI thread is already executing the action => just wait:
	ActionCtx.FDone.Wait(INFINITE);
	Result := true;

  finally
	ActionCtx.FDone.Free;
  end;
end;


 //===================================================================================================================
 // Is executed in the thread for which this message hook was registered (System.MainThreadID) and reacts specifically
 // to the WM_NULL message generated by Perform().
 //===================================================================================================================
class function TGuiThread.MsgHook(Code: int32; wParam: WPARAM; lParam: LPARAM): LRESULT;
var
  ActionCtx: PActionCtx;
begin
  Assert(Windows.GetCurrentThreadId = System.MainThreadID);

  // <Code> values other than HC_ACTION are only possible with WH_JOURNALPLAYBACK and WH_JOURNALRECORD hooks, not with
  // WH_GETMESSAGE.

  // only react to WM_NULL messages sent via PostThreadMessage() (not to every message):
  if (Code = HC_ACTION) and (wParam = PM_REMOVE) and (PMsg(lParam).hwnd = 0) and (PMsg(lParam).message = WM_NULL) then begin

	FQueueLock.AcquireExclusive;
	try
	  ActionCtx := FQueue.Extract;
	finally
	  FQueueLock.ReleaseExclusive;
	end;

	if ActionCtx <> nil then begin

	  try

		try
		  ActionCtx.FAction();
		finally
		  ActionCtx.FDone.SetEvent;
		end;

	  except
		if Assigned(Classes.ApplicationHandleException) then
		  // this ultimately calls TApplication.HandleException() in GUI applications:
		  Classes.ApplicationHandleException(nil)
		else
		  // like what SysUtils assigns to System.ExceptProc (i.e. SysUtils.ExceptHandler), but without Halt(1):
		  SysUtils.ShowException(System.ExceptObject, System.ExceptAddr);
	  end;

	end;
  end;

  Result := Windows.CallNextHookEx(0, Code, wParam, lParam);
end;


 //===================================================================================================================
 // Registering the Windows hook. Must be done by the GUI thread.
 //===================================================================================================================
class procedure TGuiThread.InstallHook;
begin
  // Hooks are automatically unregistered when the thread that *called* SetWindowsHookEx exits. This ownership is not
  // mentioned anywhere in the Windows documentation. As the hook procedure runs on the thread specified by the last
  // argument (and *not* on the thread that installed the hook), there is no reason for Windows to behave in this
  // way.
  // https://stackoverflow.com/questions/8564987/list-of-installed-windows-hooks
  Assert(Windows.GetCurrentThreadId = System.MainThreadID);

  FHook := Windows.SetWindowsHookEx(WH_GETMESSAGE, self.MsgHook, 0, System.MainThreadID);
end;


 //===================================================================================================================
 // Deregistering the Windows hook.
 //===================================================================================================================
class procedure TGuiThread.UninstallHook;
begin
  if FHook <> 0 then begin
	Windows.UnhookWindowsHookEx(FHook);
	FHook := 0;
  end;
end;


 //===================================================================================================================
 // See description in interface section.
 //===================================================================================================================
class procedure TGuiThread.Wait(Handle: THandle; TimeoutMillisecs: uint32);

  // returns true when h is signaled or the timeout is reached:
  function _Wait(h: THandle; const Timeout: TTimeoutTime): boolean;
  var
	MilliSecs: uint32;
  begin
	if TimeoutMillisecs = INFINITE then MilliSecs := INFINITE else MilliSecs := Timeout.AsMilliSecs;
	case Windows.MsgWaitForMultipleObjects(1, h, false, MilliSecs, QS_PAINT or QS_TIMER or QS_POSTMESSAGE) of
	WAIT_OBJECT_0, WAIT_TIMEOUT: Result := true;
	else Result := false;
	end;
  end;

var
  t: TTimeoutTime;
  Msg: TMsg;
  Wnd: HWND;
  WindowList: Forms.TTaskWindowList;
  FocusState: Forms.TFocusState;
begin
  // disable all top-level windows of the GUI thread while waiting
  Wnd := Windows.GetActiveWindow;
  WindowList := Forms.DisableTaskWindows(0);
  FocusState := Forms.SaveFocusState;
  try

	t := TTimeoutTime.FromMillisecs(TimeoutMillisecs);

	// processes the next WM_PAINT, WM_TIMER or posted message; may throw exceptions during this processing:
	repeat

	  while Windows.PeekMessage(Msg, 0, WM_PAINT, WM_PAINT, PM_REMOVE)
		or Windows.PeekMessage(Msg, 0, WM_TIMER, WM_TIMER, PM_REMOVE)
		or Windows.PeekMessage(Msg, HWND(-1), 0, 0, PM_REMOVE)
	  do
		Windows.DispatchMessage(Msg);

	until _Wait(Handle, t);

  finally
	Forms.EnableTaskWindows(WindowList);
	Windows.SetActiveWindow(Wnd);
	Forms.RestoreFocusState(FocusState);
  end;
end;


initialization
  TGuiThread.InstallHook;
  Tasks.TThreadPool.GuiWaitFor := TGuiThread.Wait;
finalization
  Tasks.TThreadPool.GuiWaitFor := nil;
  TGuiThread.UninstallHook;
end.

