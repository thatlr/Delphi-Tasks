unit Tasks;

{
  General thread-pool implementation. For interaction of tasks with the GUI, also include the unit "GuiTasks".

  - ICancel: Reference to an object that serves as an cancellation flag.

  - ITask: Reference to an action passed to a thread pool for asynchronous execution.

  - TThreadPool: Implements a configurable thread pool and provides a default thread pool.

  General notes:
  - The Delphi debugger slows down the application and the IDE severely when threads are created / destroyed in rapid
	succession.
  - The task queue works strictly first-come-first-serve (FIFO). A thread pool with only one thread will therefore
	process all tasks exactly in the order in which they were created.
  - Tasks cannot be forced to end. They must monitor themselves whether an abort is necessary and then end in an orderly
	manner (release of all owned resources and locks). To support this way of working, each task action is given an
	ICancel reference explicitly (as a call parameter).
  - The state of the ICancel object says nothing about *why* a task has ended. The action of the task can completely
	ignore the ICancel object.
  - The injection of calls into the GUI thread is done in such a way that foreign Windows message loops (open menus,
	delphi-external modal dialogs or message boxes, moving/resizing a window) do not prevent execution.

  Properties of a thread which the task action can change and must then reset before returning:
  - COM initialization (default: not initialized)
  - Language setting (Windows GUI texts) (Default: same as process)
  - Regional settings (formatting of numbers, date, etc.) (Default: same as process)
  - Thread scheduling priority (default: standard)
  - Attachment to a Windows message queue (default: not attached)
  - Thread-local storage (TLS) (in Delphi: content of "threadvar" variables)

  Considerations for thread pool configuration:
  - Parameter MaxTaskQueueLength: The number of waiting tasks in the pool is basically unlimited and has no
	influence on performance. The parameter can be used to synchronize the task generation rate with the task
	processing rate in order not to have too many outstanding tasks (especially if the task actions are owning
	resources such as open sockets).
  - Parameter MaxThreads: If the tasks of a given pool do not or only rarely wait for external events like I/O
	operations, this value should be equal to the number of CPU cores ("logical processors") in the processor group of
	the process so that the available capacity is optimally used.
	If the tasks of a given pool are waiting for events more frequently, the MaxThreads count can be much higher. The
	aim is to ensure that the available CPU cores are utilized as fully as possible so that tasks do not have to wait
	unnecessarily long to be processed.
	Note: A 32-bit process with the default thread stack size of 1 MB can have a maximum of approx. 2000 threads, but
	up to approx. 12000 threads are possible with a smaller stack.
  - Parameter ThreadIdleMillisecs: Specifies the time after which an idle thread is automatically terminated. (A thread
	can only be idle if there are no waiting tasks in the pool.)
  - Parameter StackSizeKB: When the stack of a thread reaches this size, the operating system throws an exception. The
	standard stack size of all threads including the main thread is set in the Delphi project properties under "Linker".
	The required size depends on how much space the local variables plus call parameters use in any possible call chain.
	With external libraries (e.g. Oracle client), this can only be estimated and needs testing.

  Use of Memory Barriers:
  - System.MemoryBarrier is identical to MemoryBarrier() in WinNT.h and about 30% faster than the MFENCE instruction.
  - Without MemoryBarrier(), the lazy-initialized events are not always set.
  - MemoryBarrier() ensures that all stores of this CPU core are visible to other cores when the call returns.
	As x86 has MESI as cache-coherence protocol, this is not about cache consistency, but about delayed write to
	memory/L1 cache from the core's store buffer.

	https://newbedev.com/which-is-a-better-write-barrier-on-x86-lock-addl-or-xchgl
	https://newbedev.com/race-condition-on-x86
	https://bartoszmilewski.com/2008/11/05/who-ordered-memory-fences-on-an-x86/
	https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2b-manual.pdf
	https://docs.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-memorybarrier
	https://prog.world/weak-memory-models-write-buffering-on-x86/
	https://preshing.com/20120515/memory-reordering-caught-in-the-act/
	https://www.cl.cam.ac.uk/~pes20/weakmemory/x86tso-paper.tphols.pdf
}


{$include LibOptions.inc}
{$ScopedEnums on}

interface

uses WinSlimLock, WindowsSynchronization, SysUtils;

type
  TWaitHandle = WindowsSynchronization.TWaitHandle;


  // Processing status of a task. The status can only change from "Pending" to one of the three termination statuses.
  // Pending: Initial state, processing is not yet finished.
  // Completed: Processing was completed without an exception, or it was terminated by the EAbort exception.
  // Failed: Processing was aborted by an unhandled exception (except EAbort which counts as "Completed").
  // Discarded: Aborted by thread pool shutdown, before processing had started.
  TTaskState = (Pending, Completed, Failed, Discarded);


  //===================================================================================================================
  // Represents an cancellation flag (similar to CancellationToken + CancellationTokenSource in .NET).
  // This interface allows application code to set and to query an cancellation flag. Generally, the flag signals
  // asynchronous actions that they should terminiate as soon as possible.
  // Once set, the flag cannot be reset.
  // One and the same ICancel reference can be given to any number of tasks, and can be also used by any other code in
  // the application.
  // All interface methods are thread-safe.
  //===================================================================================================================
  ICancel = interface
	// Can be called at any time by any thread to set the cancellation flag.
	procedure Cancel;

	// Can be called at any time by any thread to determine whether the cancellation flag has been set.
	function IsCancelled: boolean;

	// Can be called at any time by any thread to obtain a TWaitHandle reference in order to wait for the cancellation
	// flag to be set.
	// The caller must stop using the obtained TWaitHandle reference if it no longer owns the corresponding ICancel
	// reference.
	// The caller must not release the obtained object.
	function CancelWH: TWaitHandle;
  end;


  //===================================================================================================================
  // Represents an action passed to TThreadPool.Run() or TThreadPool.Queue() for asynchronous execution.
  // The release of the ITask reference by the application does not affect the processing of the task.
  // All interface methods are thread-safe.
  //===================================================================================================================
  ITask = interface
	// Can be called by any thread at any time to determine whether and how the task has ended.
	// The status can only change from Pending to one of the three other statuses.
	function State: TTaskState;

	// Can be called by any thread at any time to obtain a TWaitHandle reference in order to wait for the end of the task.
	// The caller must stop using the obtained TWaitHandle reference if it no longer owns the corresponding ITask
	// reference.
	// The caller must not release the obtained object.
	function CompleteWH: TWaitHandle;

	// Can be called at any time by any thread to determine whether the task was terminated by an unhandled exception,
	// and if so, which one. Returns nil if no unhandled exception has occurred so far.
	// The caller must not release the obtained object.
	function UnhandledException: Exception;

	// Can be called by any thread at any time to get the ICancel object assigned to the task. This reference can be
	// used in any way you like.
	function CancelObj: ICancel;

	// Can be called by any thread (including the GUI thread) at any time to wait for the task to finish.
	// Returns true when the task has ended, and false when the call timed out.
	// If ThrowOnError is set, an exception is thrown if the task was terminated by an unhandled exception.
	// The exception text comes from the unhandled exception, but the exception type is always SysUtils.Exception (this
	// is because there is no generic way to clone the object referenced by the UnhandledException property).
	// When called from a non-GUI thread:
	//   The wait is completely passive and no Windows messages are processed.
	// When called from the GUI thread:
	//   Parallel to the waiting, paint and timer messages are processed so that the GUI does not appear completely dead
	//   if the waiting takes longer. Exceptions from the paint or timer event processing are not intercepted regardless
	//   of ThrowOnError, as these are not created by the task.
	// Remarks for use in the GUI thread:
	// - Since timer and paint Windows messages are processed while waiting, Delphi code in the respective timer events
	//   or paint handlers will be executed by the GUI thread. Be aware of potential reentracy issues.
	//   Messages generated with PostThreadMessage() or PostMessage(null,...) are also processed during the wait.
	// - As usual, after waiting for approx. 5 seconds, all the GUI windows will be "ghosted" by Windows ("no response"
	//   appears in the window title bar and the window content is frozen by the system). In general, the Wait method
	//   should therefore only be called if the expected waiting time is "short".
	// - When the task has already been canceled via its ICancel reference, calling Wait() will not dead-lock even when
	//   the task uses TGuiThread.Perform().
	// - There are the following variants in the Windows API: CoWaitForMultipleObjects(), MsgWaitForMultipleObjects()
	//   and WaitForMultipleObjects(). For special requirements, the caller himself should use CompleteHW.Handle with
	//   one of these variants, specify the desired flags and react according to the respective return value.
	function Wait(ThrowOnError: boolean = true; TimeoutMillisecs: uint32 = INFINITE): boolean;
  end;


  //===================================================================================================================
  // Referencess a named or anonymous method/function/procedure suitable for execution as a thread pool task.
  // (Note: This is different from the types Classes.TThreadMethod and Classes.TThreadProcedure used by the not-so-great
  // standard Delphi TThread class.)
  // Important:
  // The method must not call System.EndThread(), Windows.ExitThread() nor Windows.TerminateThread(), as this will cause
  // memory leaks, resource leaks and unpredictable behavior.
  // Windows.SuspendThread can lead to dead-locks (for example, when the thread is stoppped when inside the Memory
  // Manager, this will deadlock the entire process) and is therefore also prohibited.
  //===================================================================================================================
  ITaskProcRef = reference to procedure (const CancelObj: ICancel);

  //===================================================================================================================
  // Same as ITaskProcRef, but avoids the lengthy compiler-generated code at the call site when a normal method is used.
  //===================================================================================================================
  TTaskProc = procedure (const CancelObj: ICancel) of object;


  //===================================================================================================================
  // Represents a thread pool with threads that are used exclusively by this pool.
  // The pure creation of a TThreadPool object allocates *no* resources and *no* threads.
  // Each TThreadpool instance is independent, there is no coordination between the pools.
  // All public methods (except Destroy) are thead-safe.
  //===================================================================================================================
  TThreadPool = class
  private
	class var
	  FDefaultPool: TThreadPool;

	type
	  ITask2 = interface;	// forward-declaration for SetNext and GetNext (needed at least for the D2009 compiler)

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
	  FThreadIdleMillisecs: uint32;					// time after which an idle thread terminates itself
	  FStackSize: uint32;							// parameter for CreateThread(): thread stack size, in bytes
	  FLock: TSlimRWLock;							// serializes Get/Put together with FItemAvail and FSpaceAvail
	  FItemAvail: WinSlimLock.TConditionVariable;	// condition for Get
	  FSpaceAvail: WinSlimLock.TConditionVariable;	// condition for Put
	  FIdle: WinSlimLock.TConditionVariable;		// condition for Destroy: "no threads", Wait: "no tasks"
	  FDestroying: boolean;							// is set by Destroy so that no more new tasks are accepted (important for the default thread pool)
	  FThreads: record
		TotalMax: uint32;							// static: total number of threads allowed in this thread pool
		TotalCount: uint32;							// current number of threads in the thread pool
		IdleCount: uint32;							// current number of idle threads, i.e. threads waiting for work inside Get()
	  end;

	class function OsThreadFunc(self: TThreadPool): integer; static;
	procedure StartNewThread;
	function Put(const Action: ITaskProcRef; const CancelObj: ICancel): ITask2;
	function Get: ITask2;

  public
	class var
	  // To not pull-in most of the VCL code, this is to be provided by another unit:
	  // Used when the GUI thread calls ITask.Wait. Should wait until <Handle> gets signaled.
	  // May throw exceptions.
	  GuiWaitFor: procedure (Handle: THandle; TimeoutMillisecs: uint32);

  public
	// Queues the action to the default thread pool and returns the respective ITask reference.
	// The default thread pool has the following properties:
	//  MaxThreads=2000, MaxTaskQueueLength=2^32, ThreadIdleMillisecs=15000, StackSizeKB=0
	// As long as no more than 2000 tasks are queued up to the pool, the action is processed as soon as the OS can
	// allocate CPU time, without having to wait for the termination of others tasks.
	// The default thread pool is therefore suitable for ad-hoc tasks (reliable immediate start of the task), but not
	// for massively parallel algorithms that generate many tasks. That would bring the pool close to MaxThreads and
	// thereby delaying ad-hoc tasks.
	// For massively parallel things, a separate pool should be created that has a very limited number of threads (e.g.
	// MaxThreads = number of CPU cores) and a reasonably limited task queue (e.g. MaxTaskQueueLength = 4 * MaxThreads).
	class function Run(Action: TTaskProc; CancelObj: ICancel = nil): ITask; overload;
	class function Run(const Action: ITaskProcRef; CancelObj: ICancel = nil): ITask; overload;

	// Creates an independent thread pool with the given properties:
	// - MaxThreads: Maximum number of threads that this pool can execute at the same time. If 0, System.CPUCount is used.
	// - MaxTaskQueueLength: Maximum number of tasks waiting to be processed (at least 1).
	// - ThreadIdleMillisecs: Time in milliseconds after which idle threads automatically terminate (INFINITE is not
	//   supported).
	// - StackSizeKB: Stack size of the threads in kilobytes. 0 means the stack size is the same as for the main thread
	//   (which is defined in the Delphi linker settings).
	// The caller becomes the owner of the pool and must destroy it at the appropriate time. The destruction is *not*
	// thread-safe, but can be done by any thread as long as it does not belong to this pool itself.
	// The destructor does not return until all threads in the pool have terminated.
	constructor Create(MaxThreads, MaxTaskQueueLength, ThreadIdleMillisecs, StackSizeKB: uint32);
	destructor Destroy; override;

	// Can be called by any thread at any time in order to assign <Action> to this thread pool and return an ITask
	// reference that can be used by the application to monitor or control the task.
	// As long as the task queue has not yet reached its maximum length, the method returns immediately; otherwise it
	// waits until a place in the task queue has become free.
	// If the number of running threads in the pool has not yet reached the maximum, the task is guaranteed to be
	// processed immediately; otherwise, the task waits in the queue until a thread becomes available or until the
	// pool is destroyed.
	// <CancelObj> can be any ICancel reference; if nil is passed, an ICancel object is automatically provided
	// (accessible via ITask.CancelObj).
	// Exceptions can be used within <Action> to terminate the task early. When the task is ended by EAbort, ITask.Status
	// is set to TTaskState.Completed, as for normal termination of the task. Other exceptions cause ITask.Status to be
	// set to TTaskState.Failed.
	// Note: If a pool task tries to create another task in the same pool, but there is no more space in the task queue,
	// the operation blocks until another task terminates. This can cause a deadlock.
	function Queue(Action: TTaskProc; CancelObj: ICancel = nil): ITask; overload;
	function Queue(const Action: ITaskProcRef; CancelObj: ICancel = nil): ITask; overload;

	// Can be called by any thread at any time in order to wait for the completion of all tasks in this thread pool.
	// If other threads are able to create new tasks, "completion of all tasks" is a purely temporary state.
	// This call does not change the status of the pool.
	// Since there is no timeout, the application logic must ensure that the wait will eventually return (e.g. by using
	// an ICancel that is observed by all tasks in the pool).
	procedure Wait;

	property ThreadsTotal: uint32 read FThreads.TotalCount;
	property ThreadsIdle: uint32 read FThreads.IdleCount;
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


// Like System.SetMXCSR, but does NOT change the global variable System.DefaultMXCSR.
procedure SetMXCSR(NewValue: uint32);
procedure ResetMXCSR; inline;

// Like System.Set8087CW, but does NOT change the global variable System.Default8087CW.
procedure Set8087CW(NewValue: Word);
procedure Reset8087CW; inline;


{############################################################################}
implementation
{############################################################################}

uses Windows, TimeoutUtil;

type
  //===================================================================================================================
  // Encapsulates an ITaskProcRef action, and provides ICancel and ITask2.
  // If FCancelObj is nil, TTaskWrapper is his own ICancel object. The task can pass on its ICancel interface to other
  // actions or tasks, whereby this object is then used independently of the task.
  //===================================================================================================================
  TTaskWrapper = class sealed (TCancelFlag, TThreadPool.ITask2)
  strict private
	FAction: ITaskProcRef;					// application function to be executed
	FUnhandledException: TObject;			// exception that occurred during the execution of FAction(), set if FState = Failed
	FCancelObj: ICancel;					// reference to explicitly provided CancelObj, otherwise nil
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
  // always returns the original value of <Event>, but only changes it if it was nil:
  // Event was not nil => other thread was faster => its TEvent is now used:
  if Windows.InterlockedCompareExchangePointer(pointer(Event), tmp, nil) <> nil then tmp.Free;
end;


 //===================================================================================================================
 // Sets the value of the MMX/SSE control register, without affecting System.DefaultMXCSR.
 //===================================================================================================================
procedure SetMXCSR(NewValue: uint32);
asm
  {$if sizeof(pointer) = 8}
  AND     ECX, $FFC0	// Remove flag bits
  PUSH    RCX			// push QWORD with the MXCSR value in the lower DWORD
  LDMXCSR [RSP]			// load MXCSR from the top-most stack dword
  POP     RCX			// deallocate QWORD
  {$else}
  AND     EAX, $FFC0	// Remove flag bits
  PUSH    EAX			// push DWORD with the MXCSR value
  LDMXCSR [ESP]			// load MXCSR from the top-most stack dword
  POP     EAX			// deallocate DWORD
  {$ifend}
end;


 //===================================================================================================================
 // Resets the value of the MMX/SSE control register to default value used by Delphi.
 //===================================================================================================================
procedure ResetMXCSR;
const
  DefaultSseCfg = $1900;	// Start value of System.DefaultMXCSR
begin
  SetMXCSR(DefaultSseCfg);
end;


 //===================================================================================================================
 // Sets the value of the 8087 control word, without affecting System.Default8087CW.
 //===================================================================================================================
procedure Set8087CW(NewValue: Word);
asm
  {$if sizeof(pointer) = 8}
  PUSH    RCX			// push QWORD with the MXCSR value in the lower WORD
  FNCLEX				// don't raise pending exceptions enabled by the new flags
  FLDCW   [RSP]			// load CW from top-most stack word
  POP     RCX			// deallocate QWORD
  {$else}
  PUSH    AX			// push WORD with the MXCSR value
  FNCLEX				// don't raise pending exceptions enabled by the new flags
  FLDCW   [ESP]			// load CW from top-most stack word
  POP     AX			// deallocate WORD
  {$ifend}
end;


 //===================================================================================================================
 // Resets the value of the 8087 control word to default value used by Delphi.
 //===================================================================================================================
procedure Reset8087CW;
const
  DefaultFpuCfg = $1332;	// Start value of System.Default8087CW
begin
  Set8087CW(DefaultFpuCfg);
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
  System.MemoryBarrier;
  // only after setting und publishing FCancelled, otherwise CancelWH() might miss the true value:
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
	// put the status of FCancelled into the (possibly) new event:
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
begin
  Assert(FState = TTaskState.Pending);
  Assert(not Assigned(FUnhandledException));
  Assert(not Assigned(FCompleteHandle) or not FCompleteHandle.IsSignaled);

  try
	// always start task with the default FPU configuration:
	Reset8087CW;
	// always start task with the default SSE configuration (we assume that any CPU executing Windows 7 or above supports SSE):
	ResetMXCSR;

	try
	  FAction(self.CancelObj);
	finally
	  // an anonymous function may have captured important resources => release reference as soon as possible:
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

  System.MemoryBarrier;
  // only *after* setting and publishing FState:
  if Assigned(FCompleteHandle) then FCompleteHandle.SetEvent;
end;


 //===================================================================================================================
 // Implements ITask2.Abort: Set task to "Discarded".
 //===================================================================================================================
procedure TTaskWrapper.Discard;
begin
  Assert(FState = TTaskState.Pending);

  FAction := nil;
  FState := TTaskState.Discarded;

  System.MemoryBarrier;
  // only *after* setting and publishing FState:
  if Assigned(FCompleteHandle) then FCompleteHandle.SetEvent;
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
	// put the status of ITask.State into the (possibly) new event:
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
  if FState = TTaskState.Pending then begin
	if not Assigned(TThreadPool.GuiWaitFor) or System.IsConsole or (Windows.GetCurrentThreadId <> System.MainThreadID) then
	  self.CompleteWH.Wait(TimeoutMillisecs)
	else
	  TThreadPool.GuiWaitFor(self.CompleteWH.Handle, TimeoutMillisecs);
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
 // See description in interface section.
 //===================================================================================================================
class function TThreadPool.Run(Action: TTaskProc; CancelObj: ICancel = nil): ITask;
var
  tmp: ITaskProcRef;
begin
  tmp := Action;
  Result := self.Run(tmp, CancelObj);
end;


 //===================================================================================================================
 // See description in interface section.
 //===================================================================================================================
class function TThreadPool.Run(const Action: ITaskProcRef; CancelObj: ICancel = nil): ITask;
var
  tmp: TThreadPool;
begin
  if not Assigned(FDefaultPool) then begin
	tmp := TThreadPool.Create(2000, High(uint32), 15000, 0);
	if Windows.InterlockedCompareExchangePointer(pointer(FDefaultPool), tmp, nil) <> nil then tmp.Free;
  end;
  Result := FDefaultPool.Queue(Action, CancelObj);
end;


 //===================================================================================================================
 // See description in interface section.
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
 // Destroys the thread pool: First, all tasks not yet started are discarded. After that, it waits for all threads
 // in the pool to finish.
 // When Destroy is called, no other thread in the application may continue to use this object. However, if an attempt
 // is made to create new tasks in this pool while waiting for pending tasks to finish, they are discarded immediately.
 // This application malfunction can occur with the default thread pool because circular unit references
 // can lead to an unclear situation as to when the default thread pool will be destroyed.
 //===================================================================================================================
destructor TThreadPool.Destroy;
begin
  // no longer accept new tasks (default thread pool!):
  FDestroying := true;

  // threads that go idle should terminate immediately:
  FThreadIdleMillisecs := 0;

  // wake up all threads waiting in Get(), so that they see the new FThreadIdleMillisecs value:
  TSlimRWLock.WakeAllConditionVariable(FItemAvail);

  FLock.AcquireExclusive;
  // cancel all tasks that have not yet started (for faster completion if many tasks have accumulated):
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
 // See description in interface section.
 //===================================================================================================================
procedure TThreadPool.Wait;
begin
  // could be AcquireShared/ReleaseShared (but it would be the only place, so nothing is gained):
  FLock.AcquireExclusive;
  while (FThreads.IdleCount < FThreads.TotalCount) or (FTaskQueue.Count <> 0) do FLock.SleepConditionVariable(FIdle, INFINITE, 0);
  FLock.ReleaseExclusive;
end;


 //===================================================================================================================
 // Creates a TTaskWrapper object and places it in the task queue. It may need to wait for free space in the task queue.
 //===================================================================================================================
function TThreadPool.Put(const Action: ITaskProcRef; const CancelObj: ICancel): ITask2;
var
  ThreadAction: (WakeThread, CreateThread, Nothing);
begin
  Result := TTaskWrapper.Create(Action, CancelObj);

  if FDestroying then begin
	// signal that something special has happened to the task:
	Result.Discard;
	exit;
  end;

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
 // If the idle timeout expired while waiting, nil is returned. Otherwise the next object from the queue is returned,
 // which now belongs to the caller.
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
		// Timeout occurred => thread must *not* terminate if there are waiting tasks, since Put() then assumes that this thread is idle.
		if FTaskQueue.Count <> 0 then break;
		// calling thread will terminate:
		dec(FThreads.TotalCount);
		dec(FThreads.IdleCount);
		// wake up the destructor when there are no more threads:
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
 // See description in interface section.
 //===================================================================================================================
function TThreadPool.Queue(const Action: ITaskProcRef; CancelObj: ICancel): ITask;
begin
  Result := self.Put(Action, CancelObj);
end;


 //===================================================================================================================
 // See description in interface section.
 //===================================================================================================================
function TThreadPool.Queue(Action: TTaskProc; CancelObj: ICancel): ITask;
begin
  Result := self.Put(Action, CancelObj);
end;


 //===================================================================================================================
 // Creates an OS thread that immediately starts executing TThreadPool.OsThreadFunc.
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
 // Is executed in each pool thread and calls ITask.Execute.
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
	// - Task.Execute must catch all exceptions.
	Task.Execute;

	// release reference now:
	Task := nil;

  until false;

  // would be returned by Windows.GetExitCodeThread, but irrelevant here:
  Result := 0;
end;


{$if not declared(PF_XMMI_INSTRUCTIONS_AVAILABLE)}
// not defined in Delphi 2009:
const
  PF_XMMI_INSTRUCTIONS_AVAILABLE             =  6;
{$ifend}


initialization
  {$if sizeof(pointer) = 4}
	// In TTaskWrapper.Execute, we assume that the CPU supports SSE (only SSE, not SSE2), which is true since Pentium 3
	// (1999).
	// x86: Theoretically unsupported => Assert
	// x64: Supported by all CPUs.
	Assert(Windows.IsProcessorFeaturePresent(PF_XMMI_INSTRUCTIONS_AVAILABLE));
  {$ifend}
finalization
  TThreadPool.FDefaultPool.Free;
end.
