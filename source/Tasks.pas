unit Tasks;

{
  - ICancel: Reference to an object that serves as an cancellation flag.

  - ITask: Reference to an action passed to a thread pool for asynchronous execution.

  - TThreadPool: Implements a configurable thread pool and provides a default thread pool.

  - TGuiThread: Allows any thread to inject calls into the GUI thread.

  General:
  - The Delphi debugger slows down the application and the IDE severely when threads are created / destroyed in rapid
	succession.
  - The task queue works strictly first-come-first-serve (FIFO). A thread pool with only one thread will therefore
	process all tasks exactly in the order in which they were created.
  - The state of the ICancel object says nothing about *why* a task has ended. The action of the task can completely
	ignore the ICancel object; the thread pool generally does not know why a task has voluntarily ended.
  - The injection of calls into the GUI thread is done in such a way that foreign Windows message loops (open menus,
	standard Windows or other foreign message boxes, move + resize windows) do not prevent execution.

  Properties of a thread which the task action can change and must then reset before returning:
  - COM initialization (default: not initialized)
  - Language setting (Windows GUI texts) (Default: same as process)
  - Regional setting (formatting of numbers, date, etc.) (Default: like process)
  - Thread scheduling priority (default: standard)
  - Attachment to a Windows message queue (default: not attached)
  - Thread-local storage (TLS) (in Delphi: content of "threadvar" variables)

  Considerations for thread pool configuration:
  - Parameter MaxTaskQueueLength: The queue length for waiting tasks in the pool is basically unlimited and has no
	influence on performance. The parameter can be used to synchronize the task generation rate with the task
	processing rate in order not to have too many outstanding tasks (especially if the task actions contain resources
	such as open sockets, via variables captured by anonymous functions).
  - Parameter MaxThreads: If the tasks of a given pool do not or only rarely wait for external events or I/O operations
	(i.e. require intensive computing time) and are "short", this value should be equal to the number of CPU cores
	("logical processors") in the processor group of the process so that the available capacity is optimally used.
	If the tasks are mostly waiting for events, the number of MaxThreads can be much higher.
	Note: A 32-bit process with the default thread stack size of 1 MB can have a maximum of approx. 2000 threads, but
	up to approx. 12000 threads are possible with a smaller stack.
  - Parameter ThreadIdleMillisecs: Specifies the time after which an idle thread is automatically terminated. (A thread
	can only be idle if there are no waiting tasks in the pool.)
  - Parameter StackSizeKB: When the stack of a thread reaches this size, the operating system throws an exception. The
	standard stack size of all threads including the main thread is set in the Delphi project properties under "Linker".
	The required size depends on how much space the local variables plus call parameters use in a call chain, in the
	worst case. With external libraries (e.g. Oracle client), this can only be estimated and needs testing.


  Example code:

	TfMainForm = class(TForm)
	  procedure FormActive(Sender: TObject);
	  procedure FormClose(Sender: TObject; var Action: TCloseAction);
	private
	  FTask1: ITask;
	end;

	procedure TfMainForm.FormActive(Sender: TObject);
	var
	  Action: ITaskProcRef;
	  i: integer;
	begin
	  Action := procedure (const CancelObj: ICancel)
		begin
		  repeat
			Sleep(15);
			inc(i);
			if not TGuiThread.Perform(
			  procedure ()
			  begin
				self.Color := RGB(i mod 255, i mod 255, i mod 255);
				self.Caption := IntToStr(i);
			  end,
			  CancelObj
			) then exit;
		  until false;
		end;

	  FTask1 := TThreadPool.Run(Action, FCancel);
	end;

	procedure TfMainForm.FormClose(Sender: TObject; var Action: TCloseAction);
	begin
	  FTask1.CancelObj.Cancel;
	  // Wait *must* be called to ensure that the task has ended and therefore no longer accesses the form object:
	  FTask1.Wait;
	end;

}


{$include LibOptions.inc}
{$ScopedEnums on}

interface

uses Windows, WinSlimLock, WindowsSynchronization, SysUtils;

type
  TWaitHandle = WindowsSynchronization.TWaitHandle;


  // Processing status of a task. The status can only change from "pending" to one of the three termination statuses.
  // Pending: Starting state, processing is not yet finished.
  // Completed: Processing was terminated without an exception, or it was terminated by EAbort.
  // Failed: Processing was aborted by an unhandled exception.
  // Discarded: Aborted before the processing started, by thread pool shutdown.
  TTaskState = (Pending, Completed, Failed, Discarded);


  //===================================================================================================================
  // Represents an cancellation flag (similar to CancellationToken + CancellationTokenSource in .NET).
  // This interface allows application code inside and outside of an running action to set an cancellation flag and to
  // query it. The flag signals asynchronous actions that they should terminiate as soon as possible.
  // Once set, the flag cannot be reset.
  // One and the same ICancel reference can be given to any number of tasks, and can be for any other purposes.
  // (This interface is not specific for tasks.)
  // All interface methods are thread-safe.
  //===================================================================================================================
  ICancel = interface
	// Can be called at any time by any thread to set the cancellation flag.
	procedure Cancel;

	// Can be called at any time by any thread to determine whether the cancellation flag has been set.
	// This gives *no* information about whether some task or action has already reacted to it, nor if it was already
	// finished when Cancel() was called.
	function IsCancelled: boolean;

	// Can be called at any time by any thread to read a TWaitHandle reference in order to wait for the cancellation
	// flag to be set.
	// The caller may no longer use the supplied TWaitHandle reference if he no longer has the ICancel reference, since
	// the TWaitHandle object can then already be released.
	// The caller must not release the object.
	function CancelWH: TWaitHandle;
  end;


  //===================================================================================================================
  // Represents an action passed to TThreadPool.Run() or TThreadPool.Queue() for asynchronous execution.
  // The release of the ITask reference by the application has no effect on the processing of the task.
  // All interface methods are thread-safe.
  //===================================================================================================================
  ITask = interface
	// Can be called by any thread at any time to determine whether and how the task has ended.
	// The status can only change from Pending to one of the three other statuses.
	function State: TTaskState;

	// Can be called by any thread at any time to read a TWaitHandle reference in order to wait for the end of the task.
	// The caller may no longer use the delivered TWaitHandle reference if he no longer has the ITask reference, since
	// the TWaitHandle object can then already be released.
	// The caller must not release the object.
	function CompleteWH: TWaitHandle;

	// Can be called at any time by any thread to determine whether the task was terminated by an unhandled exception,
	// and if so, which one. Returns nil if no unhandled exception has occurred.
	// The caller must not release the object.
	function UnhandledException: Exception;

	// Can be called by any thread at any time to get a reference to the ICancel object assigned to the task. This
	// reference can be used in any way you like.
	function CancelObj: ICancel;

	// Can be called by any thread (including the GUI thread) at any time to wait for the task to finish.
	// Returns true when the task has ended, and false when the call timed out.
	// If ThrowOnError is set, an exception is thrown if the task was terminated by an unhandled exception.
	// The exception text comes from the unhandled exception, but the exception type is always SysUtils.Exception.
	// Waiting is completely passive (e.g. no Windows messages are processed).
	function Wait(ThrowOnError: boolean = true; TimeoutMillisecs: uint32 = INFINITE): boolean;

	// Can be called by the GUI thread to wait for the task to finish and to process at least paint and timer events in
	// parallel, so that the GUI does not appear completely dead if the wait takes longer.
	// Returns true when the task has ended, and false when the call timed out.
	// If ThrowOnError is set, an exception is thrown if the task was terminated by an unhandled exception. The
	// exception text comes from the unhandled exception, but the exception type is always SysUtils.Exception.
	// Irrespective of ThrowOnError, exceptions from paint or timer messages can occur that are processed while waiting.
	//
	// Remarks:
	// - Since timer and paint Windows messages are processed while waiting, Delphi code may also be run through in
	//   timer events or paint handlers.
	// - Messages generated with PostThreadMessage() are also processed during the wait.
	// - As usual, after approx. 5 seconds the window will be "ghosted" by Windows ("no response" appears in the window
	//   title bar and the window content is frozen by the system). In general, the method should therefore only be
	//   used if the expected waiting time is short (for example, when the task has already been canceled).
	// - There are the following variants in the Windows API: CoWaitForMultipleObjects(), MsgWaitForMultipleObjects()
	//   and WaitForMultipleObjects(). For special requirements, the caller himself should use CompleteHW.Handle with
	//   one of these variants, specify the desired flags and react according to the respective return value.
	function GuiWait(ThrowOnError: boolean = true; TimeoutMillisecs: uint32 = INFINITE): boolean;
  end;


  //===================================================================================================================
  // References a named or anonymous method suitable for execution as a thread pool task.
  // (Note: There are the types Classes.TThreadMethod and Classes.TThreadProcedure used by the not-so-great standard
  // Delphi TThread class.)
  // Important:
  // The ITaskProcRef action must not call System.EndThread(), Windows.ExitThread() nor Windows.TerminateThread(), as
  // this will cause memory leaks and unpredicatable behavior.
  // Windows.SuspendThread can lead to dead-locks (for example, when the thread in the Memory Manager, this will deadlock
  // the entire process) and is therefore also prohibited.
  //===================================================================================================================
  ITaskProcRef = reference to procedure (const CancelObj: ICancel);

  //===================================================================================================================
  // Same as ITaskProcRef, but avoids the lengthy compiler-generated code at the call site when a normal method is used.
  // With instance methods, the caller must ensure that the object instance is not released while the task is running;
  // class methods don't have this problem.
  //===================================================================================================================
  TTaskProc = procedure (const CancelObj: ICancel) of object;


  //===================================================================================================================
  // Represents a thread pool with threads used exclusively by this pool.
  // The pure creation of a TThreadPool object allocates *no* resources and *no* threads.
  // Each TThreadpool instance is independent, there is no coordination across pools.
  // All public methods (except Destroy) are thead-safe.
  //===================================================================================================================
  TThreadPool = class
  private
	class var
	  FDefaultPool: TThreadPool;

	type
	  ITask2 = interface;	// forward-declaration for SetNext and GetNext (needed at last for the D2009 compiler)

	  // extends ITask with internal management methods.
	  ITask2 = interface (ITask)
		procedure SetNext(const Item: TThreadPool.ITask2);
		function GetNext: TThreadPool.ITask2;
		procedure Execute;
		procedure Discard;
	  end;

  strict private
	type
	  // helper structure: implements an ITask2 FIFO as a linear list.
	  TTaskQueue = record
	  strict private
		FFirst: ITask2;
		FLast: ITask2;
		FCount: uint32;
	  public
		procedure Append(const Task: ITask2);
		function Extract: ITask2;
		property Count: uint32 read FCount;
	  end;

	var
	  FTaskQueue: TTaskQueue;						// linear list of waiting tasks
	  FMaxWaitTasks: uint32;						// maximum length of <FTaskQueue>
	  FThreadIdleMillisecs: uint32;					// Time after which an idle thread terminates itself
	  FStackSize: uint32;							// parameter for CreateThread()
	  FLock: TSlimRWLock;							// serializes Get/Put together with FItemAvail and FSpaceAvail
	  FItemAvail: WinSlimLock.TConditionVariable;	// for Get
	  FSpaceAvail: WinSlimLock.TConditionVariable;	// for Put
	  FIdle: WinSlimLock.TConditionVariable;		// Destroy: "no threads", Wait: "no tasks"
	  FDestroying: boolean;							// is set by Destroy so that no more new tasks are accepted (default thread pool!)
	  FThreads: record
		TotalMax: uint32;			// static: total number of threads allowed in this thread pool
		TotalCount: uint32;			// current: Threads in the thread pool
		IdleCount: uint32;			// current: Idle threads, i.e. threads waiting for work inside Get()
	  end;

	class function OsThreadFunc(self: TThreadPool): integer; static;
	procedure StartNewThread;
	function Put(const Action: ITaskProcRef; const CancelObj: ICancel): ITask2;
	function Get: ITask2;

  public
	// Performes TThreadPool.Queue(<Action>,<CancelObj>) for the default thread pool.
	// The default thread pool has the following properties:
	//  MaxThreads=2000, MaxTaskQueueLength=2^32, ThreadIdleMillisecs=15000, StackSizeKB=0
	// This means that every task within the reasonable limits (i.e. up to 2000) is processed immediately by a thread.
	// The default thread pool is therefore suitable for individual ad hoc actions (reliable immediate start of the
	// action), but not for massively parallel algorithms that would bring the pool close to MaxThreads and thereby
	// delay ad hoc actions.
	// For massively parallel things, a separate pool should be created that has a very limited number of threads (e.g.
	// MaxThreads = number of CPU cores) and a queue that is sensibly limited (e.g. MaxTaskQueueLength = 4 * MaxThreads).
	class function Run(Action: TTaskProc; CancelObj: ICancel = nil): ITask; overload;
	class function Run(const Action: ITaskProcRef; CancelObj: ICancel = nil): ITask; overload;

	// Creates an independent thread pool with the given properties:
	// - MaxThreads: Maximum number of threads that this pool can execute at the same time. If 0, System.CPUCount is used.
	// - MaxTaskQueueLength: Maximum number of tasks waiting to be processed by a pool thread (at least 1).
	// - ThreadIdleMillisecs: Time in milliseconds after which idle threads automatically terminate (INFINITE is not
	//   supported).
	// - StackSizeKB: Stack size of the threads in kilobytes. 0 means stack size is the same as for the main thread
	//   (which is defined in the Delphi linker settings).
	// The caller becomes the owner of the pool, and must release it at the appropriate time.
	// The release is *not* thread-safe, but can be done by any thread as long as it does not belong to this pool itself.
	// The Destroy method does not return until all threads in the pool have terminated.
	constructor Create(MaxThreads, MaxTaskQueueLength, ThreadIdleMillisecs, StackSizeKB: uint32);
	destructor Destroy; override;

	// Can be called by any thread at any time in order to transfer <Action> to this thread pool for processing by a
	// thread as soon as possible.
	// As long as the task queue has not yet reached its maximum length, the method returns immediately; otherwise it
	// waits until a place in the task queue has become free.
	// If the number of running threads in the pool has not yet reached the maximum, <Action> is guaranteed to be
	// processed by a thread immediately; otherwise, <Action> remains in the queue until a thread is available.
	// <CancelObj> can be any ICancel reference; if nil is passed, an ICancel object is automatically provided
	// (accessible via ITask.CancelObj).
	// The EAbort exception can be used within <Action> to end the task early using the usual exception mechanism. In
	// this case, ITask.Status is set to Completed, analogous to a normal voluntary termination of the task.
	// Note: If a pool task tries to create another task in the same pool, but there is no more space in the task queue,
	// the operation blocks until another task terminates. This can cause a deadlock.
	function Queue(Action: TTaskProc; CancelObj: ICancel = nil): ITask; overload;
	function Queue(const Action: ITaskProcRef; CancelObj: ICancel = nil): ITask; overload;

	// Can be called by any thread at any time in order to wait for the completion of all tasks in this thread pool.
	// If other threads are able to create new tasks at any time (requirement: they have access to this thread pool),
	// "completion of all tasks" is a purely temporary state.
	// The status of the pool is not changed by this call.
	procedure Wait;

	property ThreadsTotal: uint32 read FThreads.TotalCount;
	property ThreadsIdle: uint32 read FThreads.IdleCount;
  end;


  //===================================================================================================================
  // References a named or anonymous method suitable for execution by TGuiThread.Perform ().
  //===================================================================================================================
  IGuiProcRef = reference to procedure;

  //===================================================================================================================
  // Same as IGuiProcRef, but avoids the lengthy compiler-generated code at the call site when using a named method.
  // With instance methods, the caller must ensure that the object instance is not released as long as the task may
  // call this method; class methods don't have this problem.
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
	class var
	  FHook: HHOOK;
	  FActionDone: TEvent;					// is set by Perform() when FGuiAction is done
	  FThreadLock: TSlimRWLock;				// serializes calls to Perform()
	  FActionLock: TSlimRWLock;				// serializes access to FGuiAction
	  FGuiAction: IGuiProcRef;
	class procedure ExchangeRefs(var a1, a2: IGuiProcRef); static;
	class function MsgHook(code: int32; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall; static;
  private
	class procedure UninstallHook; static;
  public
	// This method causes the GUI thread <Action> to execute. To do this, Perform waits until the GUI thread wants to
	// take a Windows message from its message queue and lets it execute <Action> at this point in time.
	// In general, <CancelObj> should be the cancel object of the Perform-calling task (see the following note on
	// avoiding deadlocks).
	// If <CancelObj> is set already before the actual start of <Action>, the GUI thread will not be waited for and
	// Perform returns without <Action> being executed.
	// If <CancelObj> is only set after <Action> has actually started, this has no effect on Perform.
	// The return value is false if <Action> was not executed due to <CancelObj>, otherwise true is returned.
	// It is guaranteed that <Action> will no longer run after Perform() has returned.
	// Deadlock avoidance:
	// If the GUI thread waits for a task that calls Perform, a deadlock occurs because both threads are waiting
	// crosswise for each other. The GUI thread can only safely wait for a task if it has called ITask.CancelObj.Cancel
	// for the respective task: This causes the Perform method to return immediately when called by this task, which in
	// turn gives the task a chance to exit, which ultimately allows the GUI thread to get out of the wait call.
	// Note: If this method is called by the GUI thread itself, <Action> is called without cross-thread synchronization,
	// otherwise the behavior is identical.
	class function Perform(Action: TGuiProc; CancelObj: ICancel): boolean; overload; static;
	class function Perform(Action: IGuiProcRef; CancelObj: ICancel): boolean; overload; static;
  end;


  //===================================================================================================================
  // Implements ICancel on the basis of a TEvent object that is only created when required.
  //===================================================================================================================
  TCancelFlag = class (TInterfacedObject, ICancel)
  strict private
	FWaitHandle: TEvent;					// is only created when ICancel.CancelWH is called
	FCancelled: boolean;					// whether ICancel.Cancel was called
  private
	// >> ICancel
	procedure Cancel;
	function IsCancelled: boolean;
	function CancelWH: TWaitHandle;
	// << ICancel
  public
	destructor Destroy; override;
  end;


  //===================================================================================================================
  // Implements ICancel based on an existing TWaitHandle object.
  // The ICancel.Cancel method *only* works if a TEvent or TWaitableTimer object has been passed to the constructor;
  // this method is ineffective for all other classes derived from TWaitHandle, since the signaled state of the handle
  // is only explicitly changeable for TEvent and TWaitableTimer objects.
  //===================================================================================================================
  TCancelHandle = class (TInterfacedObject, ICancel)
  strict private
	FWaitHandle: TWaitHandle;
	FOwnsHandle: boolean;					// whether FWaitHandle must be released
  private
	// >> ICancel
	procedure Cancel;
	function IsCancelled: boolean;
	function CancelWH: TWaitHandle;
	// << ICancel
  public
	constructor Create(WaitHandle: TWaitHandle; TakeOwnership: boolean);
	constructor CreateTimeout(Milliseconds: uint32);
	destructor Destroy; override;
  end;


{############################################################################}
implementation
{############################################################################}

uses Messages, Classes, TimeoutUtil;

type
  //===================================================================================================================
  // Encapsulates an ITaskProcRef action, and provides ICancel and ITask2.
  // If FCancelObj is nil, TTaskWrapper is his own ICancel object. The task can pass on its ICancel interface to other
  // actions or tasks, whereby this object is then used independently of the task.
  //===================================================================================================================
  TTaskWrapper = class sealed (TCancelFlag, TThreadPool.ITask2)
  strict private
	FAction: ITaskProcRef;					// application function to be executed
	FUnhandledException: TObject;			// Exception that occurred during the execution of FAction (), set if FState = Failed
	FCancelObj: ICancel;					// Reference to explicitly given (i.e. external) CancelObj, otherwise nil
	FCompleteHandle: TEvent;				// is only generated when ITask.CompleteWH is called
	FNext: TThreadPool.ITask2;				// used by TTaskQueue
	FState: TTaskState;						// result of the task processing, is only set once
  private
	// >> ITask
	function State: TTaskState;
	function CompleteWH: TWaitHandle;
	function UnhandledException: Exception;
	function CancelObj: ICancel;
	function Wait(ThrowOnError: boolean; TimeoutMillisecs: uint32): boolean;
	function GuiWait(ThrowOnError: boolean; TimeoutMillisecs: uint32): boolean;
	// << ITask
	// >> ITask2
	procedure SetNext(const Item: TThreadPool.ITask2);
	function GetNext: TThreadPool.ITask2;
	procedure Execute;
	procedure Discard;
	// << ITask2
  public
	constructor Create(const Action: ITaskProcRef; const CancelObj: ICancel);
	destructor Destroy; override;
  end;


 //===================================================================================================================
 // Ensures in a thread-safe manner that <Event> contains a TEvent object after the call.
 // If <Event> is set in parallel by another thread, the object created first is retained.
 //===================================================================================================================
procedure ProvideEvent(var Event: TEvent);
var
  tmp: TEvent;
begin
  tmp := TEvent.Create(true);
  // always returns the original value of FWaitHandle, but only changes it if it was nil:
  // FWaitHandle was not nil => other thread was faster here => its TEvent is now used:
  if Windows.InterlockedCompareExchangePointer(pointer(Event), tmp, nil) <> nil then tmp.Free;
end;


{ TCancelHandle }

 //===================================================================================================================
 // Generates an ICancel object based on <WaitHandle>.
 //===================================================================================================================
constructor TCancelHandle.Create(WaitHandle: TWaitHandle; TakeOwnership: boolean);
begin
  FWaitHandle := WaitHandle;
  FOwnsHandle := TakeOwnership;
  inherited Create;
end;


 //===================================================================================================================
 // Generates an ICancel object that requests cancellation after <Milliseonds> milliseconds. The timer starts immediately.
 //===================================================================================================================
constructor TCancelHandle.CreateTimeout(Milliseconds: uint32);
var
  Timer: TWaitableTimer;
begin
  Timer := TWaitableTimer.Create(true);
  self.Create(Timer, true);
  Timer.Start(Milliseconds);
end;


 //===================================================================================================================
 //===================================================================================================================
destructor TCancelHandle.Destroy;
begin
  if FOwnsHandle then FWaitHandle.Free;
  inherited;
end;


 //===================================================================================================================
 // Implements ICancel.Cancel: see description there.
 //===================================================================================================================
procedure TCancelHandle.Cancel;
begin
  if FWaitHandle is TEvent then
	TEvent(FWaitHandle).SetEvent
  else if FWaitHandle is TWaitableTimer then
	TWaitableTimer(FWaitHandle).Start(0)
  else
	Assert(false, 'Unsupported TWaitHandle');
end;


 //===================================================================================================================
 // Implements ICancel.IsCancelled: see description there.
 //===================================================================================================================
function TCancelHandle.IsCancelled: boolean;
begin
  Result := FWaitHandle.IsSignaled;
end;


 //===================================================================================================================
 // Implements ICancel.CancelWH: see description there.
 //===================================================================================================================
function TCancelHandle.CancelWH: TWaitHandle;
begin
  Result := FWaitHandle;
end;


{ TCancelFlag }

 //===================================================================================================================
 //===================================================================================================================
destructor TCancelFlag.Destroy;
begin
  FWaitHandle.Free;
  inherited;
end;


 //===================================================================================================================
 // Implements ICancel.Cancel: see description there.
 //===================================================================================================================
procedure TCancelFlag.Cancel;
begin
  FCancelled := true;
  // only after setting FCancelled, otherwise CancelWH() might miss the true value:
  if Assigned(FWaitHandle) then FWaitHandle.SetEvent;
end;


 //===================================================================================================================
 // Implements ICancel.IsCancelled: see description there.
 //===================================================================================================================
function TCancelFlag.IsCancelled: boolean;
begin
  Result := FCancelled;
end;


 //===================================================================================================================
 // Implements ICancel.CancelWH: see description there.
 // The method generates the corresponding Windows object only at the first access.
 //===================================================================================================================
function TCancelFlag.CancelWH: TWaitHandle;
begin
  if not Assigned(FWaitHandle) then begin
	ProvideEvent(FWaitHandle);
	// put the status of FCancelled into the (possibly) new event before a reference to it is returned:
	if FCancelled then FWaitHandle.SetEvent;
  end;
  Result := FWaitHandle;
end;


{ TTaskWrapper }

 //===================================================================================================================
 //===================================================================================================================
constructor TTaskWrapper.Create(const Action: ITaskProcRef; const CancelObj: ICancel);
begin
  FAction := Action;
  FCancelObj := CancelObj;
  Assert(FState = TTaskState.Pending);
  inherited Create;
end;


 //===================================================================================================================
 //===================================================================================================================
destructor TTaskWrapper.Destroy;
begin
  FUnhandledException.Free;
  FCompleteHandle.Free;
  inherited;
end;


 //===================================================================================================================
 // Implements ITask2.Execute: Method is executed in the pool thread. It is only called once at most.
 //===================================================================================================================
procedure TTaskWrapper.Execute;
const
  DefaultFpuCfg = $1332;	// Start value of System.Default8087CW, is set in the initialization section by the main thread via _FpuInit
begin
  Assert(FState = TTaskState.Pending);
  Assert(not Assigned(FUnhandledException));
  Assert(not Assigned(FCompleteHandle) or not FCompleteHandle.IsSignaled);

  try
	// always start with the default FPU configuration (idiotically there is also a global, non-thread-specific variable Default8087CW):
	System.Set8087CW(DefaultFpuCfg);
	try
	  FAction(self.CancelObj);
	finally
	  // the anonymous function may have captured refs to other resources => release them as part of the task:
	  FAction := nil;
	end;
	FState := TTaskState.Completed;
  except
	on EAbort do FState := TTaskState.Completed; // treat EAbort as a voluntary termination
	else begin
	  FState := TTaskState.Failed;
	  // AcquireExceptionObject prevents the release of the exception object when the exception block is exited:
	  FUnhandledException := System.AcquireExceptionObject;
	end;
  end;

  // only *after* setting FState:
  if Assigned(FCompleteHandle) then FCompleteHandle.SetEvent;
end;


 //===================================================================================================================
 // Implements ITask2.Abort: Set task to "Discarded".
 //===================================================================================================================
procedure TTaskWrapper.Discard;
begin
  Assert(FState = TTaskState.Pending);
  FState := TTaskState.Discarded;
end;


 //===================================================================================================================
 // Implements ITask2.SetNext: Set FNext to <Item>.
 //===================================================================================================================
procedure TTaskWrapper.SetNext(const Item: TThreadPool.ITask2);
begin
  FNext := Item;
end;


 //===================================================================================================================
 // Implements ITask2.GetNext: Returns the value of FNext and sets FNext to nil, so that this object no longer
 // references the returned task.
 //===================================================================================================================
function TTaskWrapper.GetNext: TThreadPool.ITask2;
begin
  Result := FNext;
  FNext := nil;
end;


 //===================================================================================================================
 // Implements ITask.IsComplete: see description there.
 //===================================================================================================================
function TTaskWrapper.State: TTaskState;
begin
  Result := FState;
end;


 //===================================================================================================================
 // Implements ITask.CompleteWH: see description there.
 //===================================================================================================================
function TTaskWrapper.CompleteWH: TWaitHandle;
begin
  if not Assigned(FCompleteHandle) then begin
	ProvideEvent(FCompleteHandle);
	// put the status of ITask.State into the (possibly) new event before a reference to it is returned:
	if FState <> TTaskState.Pending then FCompleteHandle.SetEvent;
  end;
  Result := FCompleteHandle;
end;


 //===================================================================================================================
 // Implements ITask.UnhandledException: see description there.
 //===================================================================================================================
function TTaskWrapper.UnhandledException: Exception;
begin
  Result := FUnhandledException as Exception;
end;


 //===================================================================================================================
 // Implements ITask.CancelObj: see description there.
 //===================================================================================================================
function TTaskWrapper.CancelObj: ICancel;
begin
  if Assigned(FCancelObj) then Result := FCancelObj else Result := self;
end;


 //===================================================================================================================
 // Implements ITask.Wait: see description there.
 //===================================================================================================================
function TTaskWrapper.Wait(ThrowOnError: boolean; TimeoutMillisecs: uint32): boolean;
begin
  if FState = TTaskState.Pending then self.CompleteWH.Wait(TimeoutMillisecs);

  if ThrowOnError and Assigned(FUnhandledException) then
	raise Exception.Create(self.UnhandledException.Message);

  Result := FState <> TTaskState.Pending;
end;


 //===================================================================================================================
 // Implements ITask.GuiWait: see description there.
 //===================================================================================================================
function TTaskWrapper.GuiWait(ThrowOnError: boolean; TimeoutMillisecs: uint32): boolean;

  // returns true when h is signaled or the timeout is reached:
  function _Wait(h: THandle; MilliSecs: uint32): boolean;
  begin
	if TimeoutMillisecs = INFINITE then MilliSecs := INFINITE;
	case Windows.MsgWaitForMultipleObjects(1, h, false, MilliSecs, QS_PAINT or QS_TIMER or QS_POSTMESSAGE) of
	WAIT_OBJECT_0, WAIT_TIMEOUT: Result := true;
	else Result := false;
	end;
  end;

  // processes the next Window message <MsgCode>; may throw exceptions during this processing:
  function _RemoveMsg(h: HWND; MsgCode: UINT): boolean;
  var
	Msg: TMsg;
  begin
	Result := Windows.PeekMessage(Msg, h, MsgCode, MsgCode, PM_REMOVE);
	if Result then Windows.DispatchMessage(Msg);
  end;

var
  h: THandle;
  t: TTimeoutTime;
begin
  if FState = TTaskState.Pending then begin

	h := self.CompleteWH.Handle;
	t := TTimeoutTime.FromMillisecs(TimeoutMillisecs);

	while not _Wait(h, t.AsMilliSecs) do begin
	  // process all available WM_PAINT-, WM_TIMER- and all messages *posted* to this thread, but ignore all input
	  // messages (mouse, keyboard):
	  while _RemoveMsg(0, 0) or _RemoveMsg(0, WM_TIMER) or _RemoveMsg(0, WM_PAINT) do {nothing};
	end;

  end;

  if ThrowOnError and Assigned(FUnhandledException) then
	raise Exception.Create(self.UnhandledException.Message);

  Result := FState <> TTaskState.Pending;
end;


{ TThreadPool.TTaskQueue }

 //===================================================================================================================
 // Appends <Task> to the end of the queue, whereby the queue becomes the owner of <Task>.
 //===================================================================================================================
procedure TThreadPool.TTaskQueue.Append(const Task: ITask2);
begin
  Assert((FCount = 0) and (FFirst = nil) and (FLast = nil) or (FCount <> 0) and (FFirst <> nil) and (FLast <> nil));

  if FCount = 0 then FFirst := Task
  else FLast.SetNext(Task);
  FLast := Task;

  inc(FCount);
end;


 //===================================================================================================================
 // Extracts the first task from the queue, whereby the caller becomes the owner.
 //===================================================================================================================
function TThreadPool.TTaskQueue.Extract: ITask2;
begin
  Assert((FCount <> 0) and (FFirst <> nil) and (FLast <> nil));

  Result := FFirst;
  FFirst := Result.GetNext;

  dec(FCount);
  if FCount = 0 then FLast := nil;
end;


{ TThreadPool }

 //===================================================================================================================
 //===================================================================================================================
class function TThreadPool.Run(Action: TTaskProc; CancelObj: ICancel = nil): ITask;
var
  tmp: ITaskProcRef;
begin
  tmp := Action;
  Result := self.Run(tmp, CancelObj);
end;


 //===================================================================================================================
 //===================================================================================================================
class function TThreadPool.Run(const Action: ITaskProcRef; CancelObj: ICancel = nil): ITask;
begin
  if not Assigned(FDefaultPool) then FDefaultPool := TThreadPool.Create(2000, High(uint32), 15000, 0);
  Result := FDefaultPool.Queue(Action, CancelObj);
end;


 //===================================================================================================================
 //===================================================================================================================
constructor TThreadPool.Create(MaxThreads, MaxTaskQueueLength, ThreadIdleMillisecs, StackSizeKB: uint32);
begin
  // CPUCount contains the number of CPUs in the processor group of the process, not the total number. But a process is
  // only scheduled within its processor group, so that all other CPUs are irrelevant anyway.
  if MaxThreads = 0 then MaxThreads := System.CPUCount;
  FThreads.TotalMax := MaxThreads;

  if MaxTaskQueueLength = 0 then MaxTaskQueueLength := 1;
  FMaxWaitTasks := MaxTaskQueueLength;

  FThreadIdleMillisecs := ThreadIdleMillisecs;
  FStackSize := StackSizeKB * 1024;

  inherited Create;
end;


 //===================================================================================================================
 // Blocks until all threads have terminated (so that they do not work with a pool object that has already been released).
 // When Destroy is called, no other thread in the application may continue to use this thread pool object (as always
 // with Destroy). If, after entering Destroy, an attempt is made to create new tasks in this pool, these are discarded
 // right away. This application malfunction can occur with the standard thread pool because circular unit references
 // can lead to an unclear situation as to when the standard thread pool will be released.
 //===================================================================================================================
destructor TThreadPool.Destroy;
begin
  // no longer accept new tasks (default thread pool!):
  FDestroying := true;

  // threads that go idle should terminate immediately (normally no more tasks and threads should be created, but it
  // is possible that a running task still creates new tasks in this pool):
  FThreadIdleMillisecs := 0;

  // wake up all threads waiting in Get(), so that they see the new FThreadIdleMillisecs value:
  TSlimRWLock.WakeAllConditionVariable(FItemAvail);

  FLock.AcquireExclusive;
  // cancel all tasks that have not yet started (for faster completion in the case of accumulated tasks):
  while FTaskQueue.Count <> 0 do FTaskQueue.Extract.Discard;
  // wait until no more threads are active (similar to .Wait):
  while FThreads.TotalCount <> 0 do FLock.SleepConditionVariable(FIdle, INFINITE, 0);
  FLock.ReleaseExclusive;

  // no task must wait at this point:
  Assert(FTaskQueue.Count = 0);
  // the locks must be released:
  Assert(FItemAvail.Ptr = nil);
  Assert(FSpaceAvail.Ptr = nil);

  inherited;
end;


 //===================================================================================================================
 // Implements TThreadPool.Wait: see description there.
 //===================================================================================================================
procedure TThreadPool.Wait;
begin
  FLock.AcquireExclusive;
  while (FThreads.IdleCount < FThreads.TotalCount) or (FTaskQueue.Count <> 0) do FLock.SleepConditionVariable(FIdle, INFINITE, 0);
  FLock.ReleaseExclusive;
end;


 //===================================================================================================================
 // Creates a TTaskWrapper object and places it in the task queue. If necessary, this waits for free space in the task
 // queue.
 //===================================================================================================================
function TThreadPool.Put(const Action: ITaskProcRef; const CancelObj: ICancel): ITask2;
var
  ThreadAction: (WakeThread, CreateThread, Nothing);
begin
  if FDestroying then begin
	Result := TTaskWrapper.Create(Action, CancelObj);
	// signal that something special has happened to the task:
	Result.Discard;
	exit;
  end;

  Result := TTaskWrapper.Create(Action, CancelObj);

  FLock.AcquireExclusive;
  try

	// wait until space becomes available for a task:
	while FTaskQueue.Count >= FMaxWaitTasks do begin
	  // during SleepConditionVariable() other threads can take the lock
	  FLock.SleepConditionVariable(FSpaceAvail, INFINITE, 0);
	end;

	FTaskQueue.Append(Result);

	// if necessary and allowed, then create a new thread:
	if FThreads.IdleCount > 0 then
	  ThreadAction := WakeThread
	else if FThreads.TotalCount < FThreads.TotalMax then begin
	  inc(FThreads.TotalCount);
	  ThreadAction := CreateThread;
	end
	else
	  ThreadAction := Nothing;

  finally
	FLock.ReleaseExclusive;
  end;

  case ThreadAction of
  WakeThread:   TSlimRWLock.WakeConditionVariable(FItemAvail);
  CreateThread: self.StartNewThread;
  end;
end;


 //===================================================================================================================
 // Waits until a task is available in the queue and returns it.
 // If the timeout occurred while waiting, nil is returned. Otherwise the next object from the queue is returned, which
 // now belongs to the caller.
 //===================================================================================================================
function TThreadPool.Get: ITask2;
var
  EndTime: TTimeoutTime;
begin
  EndTime := TTimeoutTime.FromMillisecs(FThreadIdleMillisecs);

  FLock.AcquireExclusive;
  try

	// calling thread is now idle:
	inc(FThreads.IdleCount);

	// wait until timeout occurs or a task becomes available:
	while FTaskQueue.Count = 0 do begin
	  // if no thread does anything, then wake up all threads waiting in TThreadPool.Wait() for this specific condition:
	  if FThreads.IdleCount = FThreads.TotalCount then TSlimRWLock.WakeAllConditionVariable(FIdle);
	  // during SleepConditionVariable() other threads can take the lock
	  if (FThreadIdleMillisecs = 0) or not FLock.SleepConditionVariable(FItemAvail, EndTime.AsMilliSecs, 0) then begin
		// Timeout occurred => thread must *not* terminate if there are waiting tasks, since Put () then assumes that this thread is idle.
		if FTaskQueue.Count <> 0 then break;
		// calling thread will terminate:
		dec(FThreads.TotalCount);
		dec(FThreads.IdleCount);
		// wake up the destructor when there is no more thread:
		if FThreads.TotalCount = 0 then TSlimRWLock.WakeAllConditionVariable(FIdle);
		exit(nil);
	  end;
	end;

	Result := FTaskQueue.Extract;

	// calling thread is no longer idle:
	dec(FThreads.IdleCount);

  finally
	FLock.ReleaseExclusive;
  end;

  // wake up a thread that may be waiting in Put():
  TSlimRWLock.WakeConditionVariable(FSpaceAvail);
end;


 //===================================================================================================================
 // Implements TThreadPool.Queue: see description there.
 //===================================================================================================================
function TThreadPool.Queue(const Action: ITaskProcRef; CancelObj: ICancel): ITask;
begin
  Result := self.Put(Action, CancelObj);
end;


 //===================================================================================================================
 // Implements TThreadPool.Queue: see description there.
 //===================================================================================================================
function TThreadPool.Queue(Action: TTaskProc; CancelObj: ICancel): ITask;
begin
  Result := self.Put(Action, CancelObj);
end;


 //===================================================================================================================
 // Creates an OS thread that immediately starts executing TThreadPool.ThreadWrapper.
 // MaxStackSize:
 //   If not zero, this defines the space reserved for the stack in the address area of the process (in bytes).
 //   If zero, the maximum stack size from the Exeutable header is used (Project Options -> Delphi Compiler -> Linking -> Maximum Stack Size).
 //===================================================================================================================
procedure TThreadPool.StartNewThread;
const
  // WinBase.h:
  STACK_SIZE_PARAM_IS_A_RESERVATION = $00010000;
var
  Handle: THandle;
  ThreadID: DWORD;
begin
  Handle := THandle(System.BeginThread(nil, FStackSize, pointer(@TThreadPool.OsThreadFunc), self, STACK_SIZE_PARAM_IS_A_RESERVATION, ThreadID));
  if Handle = 0 then SysUtils.RaiseLastOSError;
  Windows.CloseHandle(Handle);
end;


 //===================================================================================================================
 // Is executed in the created thread and calls ITask.Execute.
 //===================================================================================================================
class function TThreadPool.OsThreadFunc(self: TThreadPool): integer;
var
  Task: ITask2;
begin
  repeat

	// waiting for new work for the duration of ThreadIdleMillisecs:
	Task := self.Get;

	// timeout while waiting for new tasks:
	if not Assigned(Task) then break;

	// - Task.Execute must not call Windows.ExitThread() or System.EndThread().
	// - Task.Execute must not throw exceptions.
	Task.Execute;

	// release reference now:
	Task := nil;

  until false;

  // would be returned by Windows.GetExitCodeThread, but irrelevant here:
  Result := 0;
end;


{ TGuiThread }

 //===================================================================================================================
 //===================================================================================================================
class function TGuiThread.Perform(Action: TGuiProc; CancelObj: ICancel): boolean;
var
  tmp: IGuiProcRef;
begin
  tmp := Action;
  Result := self.Perform(tmp, CancelObj);
end;


 //===================================================================================================================
 //===================================================================================================================
class function TGuiThread.Perform(Action: IGuiProcRef; CancelObj: ICancel): boolean;
begin
  Assert(Assigned(Action) and Assigned(CancelObj));

  if CancelObj.IsCancelled then
	exit(false);

  if Windows.GetCurrentThreadId = System.MainThreadID then begin
	// calls from the GUI thread can be executed synchronously:
	Action();
	exit(true);
  end;

  FThreadLock.AcquireExclusive;
  try

	if FHook = 0 then begin
	  ProvideEvent(FActionDone);
	  FHook := Windows.SetWindowsHookEx(WH_GETMESSAGE, self.MsgHook, 0, System.MainThreadID);
	end;

	FActionDone.ResetEvent;
	Assert(not Assigned(FGuiAction));

	// FGuiAction functions as a 1-element queue => exchange sets FGuiAction
	self.ExchangeRefs(Action, FGuiAction);

	// trigger the hook in the MainThread:
	Windows.PostThreadMessage(System.MainThreadID, WM_NULL, 0, 0);

	// Wait for execution by thread <MainThreadID>. If the GUI thread is waiting for the end of the task that makes
	// this Perform call, then it does not execute MsgHook() => *must* monitor the CancelObj in parallel:
	if TWaitHandle.WaitAny([FActionDone.Handle, CancelObj.CancelWH.Handle], INFINITE) = 0 then
	  exit(true);

	// CancelObj has caused the Wait to return => determine whether FGuiAction has already been consumed by MsgHook,
	// but in any case reset FGuiAction so that the action can no longer be started.
	self.ExchangeRefs(Action, FGuiAction);

	// has FGuiAction been consumed by MsgHook?
	if Assigned(Action) then
	  exit(false);

	// MsgHook has already consumed FGuiAction => wait for the end:
	FActionDone.Wait(INFINITE);
	Result := true;

  finally
	FThreadLock.ReleaseExclusive;
  end;
end;


 //===================================================================================================================
 // Is executed in the thread for which this message hook was registered and reacts specifically to the Windows message
 // generated by Perform().
 //===================================================================================================================
class function TGuiThread.MsgHook(code: int32; wParam: WPARAM; lParam: LPARAM): LRESULT;
var
  Action: IGuiProcRef;
begin
  Assert(code >= 0);
  Result := Windows.CallNextHookEx(FHook, code, wParam, lParam);

  if (code >= 0) and (wParam = PM_REMOVE) and (PMsg(lParam).hwnd = 0) and (PMsg(lParam).message = WM_NULL) then begin

	Assert(not Assigned(Action));

	// FGuiAction functions as a 1-element queue => remove reference from FGuiAction:
	self.ExchangeRefs(Action, FGuiAction);

	if Assigned(Action) then begin
	  try
		try
		  Action();
		except
		  if Assigned(Classes.ApplicationHandleException) then
			// this ultimately calls TApplication.HandleException() in GUI applications:
			Classes.ApplicationHandleException(nil)
		  else
			// like what SysUtils assigns to System.ExceptProc (i.e. SysUtils.ExceptHandler), but without Halt(1):
			SysUtils.ShowException(System.ExceptObject, System.ExceptAddr);
		end;
	  finally
		FActionDone.SetEvent;
	  end;
	end;

  end;
end;


 //===================================================================================================================
 // Swaps the values of <a1> and <a2>, protected by FActionLock.
 //===================================================================================================================
class procedure TGuiThread.ExchangeRefs(var a1, a2: IGuiProcRef);
{$if not declared(IGuiProcRef) or (sizeof(IGuiProcRef) <> sizeof(pointer))} {$message error 'Wrong size'} {$ifend}
var
  p1: pointer absolute a1;
  p2: pointer absolute a2;
  tmp: pointer;
begin
  FActionLock.AcquireExclusive;
  // swapping the values does not change the reference count of both parameters:
  tmp := p1;
  p1 := p2;
  p2 := tmp;
  FActionLock.ReleaseExclusive;
end;


 //===================================================================================================================
 //===================================================================================================================
class procedure TGuiThread.UninstallHook;
begin
  if FHook <> 0 then begin
	Windows.UnhookWindowsHookEx(FHook);
	FHook := 0;
  end;
  FActionDone.Free;
end;


initialization
finalization
  TThreadPool.FDefaultPool.Free;
  TGuiThread.UninstallHook;
end.

