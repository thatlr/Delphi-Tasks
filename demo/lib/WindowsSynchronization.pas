unit WindowsSynchronization;

{
  Implements classes that wrap Windows synchronization objects such as timers, events, mutexes, files, threads and
  processes:

  - TWaitHandle: (abstract) represents a Windows synchronization handle.
  - TNonFileHandle: represents a handle for which the value 0 is invalid.
  - TFileHandle: represents a handle for which the value INVALID_HANDLE_VALUE is invalid.
  - TEvent: represents a Windows event (https://docs.microsoft.com/en-us/windows/win32/sync/using-event-objects)
  - TWaitableTimer: represents a Timer (https://docs.microsoft.com/en-us/windows/win32/sync/using-waitable-timer-objects).
  - TMutex: represents a Mutex (https://docs.microsoft.com/en-us/windows/win32/sync/using-mutex-objects).
}


{$include LibOptions.inc}

interface

uses
  Windows,
  TimeoutUtil;


type
  //===================================================================================================================
  // Base class for encapsulation of Windows kernel objects that have a 'signaled' state.
  //===================================================================================================================
  TWaitHandle = class abstract
  strict protected
	FHandle: THandle;

	class function WaitMultiple(const Handles: array of THandle; MilliSecondsTimeout: uint32; WaitAll: boolean): integer;
  public

	// Waits until either the timeout has expired or the Windows object has been set to 'signaled'.
	// For {MilliSecondsTimeout} = 0 the state of the synchronization object is tested without waiting.
	// For {MilliSecondsTimeout} = INFINITE there is no timeout.
	// Returns false for timeout, else true.
	function Wait(MilliSecondsTimeout: uint32): boolean; overload;
	function Wait(const Timeout: TTimeoutTime): boolean; overload;

	// Waits until either the timeout has expired or one of the Windows objects has been set to 'signaled'.
	// For {MilliSecondsTimeout} = 0 the state of the synchronization objects is tested without waiting.
	// For {MilliSecondsTimeout} = INFINITE there is no timeout.
	// Returns -1 on return due to timeout, else the index of the 'signaled' handle. If multiple handles are
	// signaled at the same time, the handle with the smallest index is processed and its index is returned.
	class function WaitAny(const Handles: array of THandle; MilliSecondsTimeout: uint32): integer; overload;
	class function WaitAny(const Handles: array of THandle; const Timeout: TTimeoutTime): integer; overload;

	// Waits until either the timeout has expired or all of the Windows objects has been set to 'signaled'.
	// For {MilliSecondsTimeout} = 0 the state of the synchronization objects is tested without waiting.
	// For {MilliSecondsTimeout} = INFINITE there is no timeout.
	// Returns false for timeout, else true.
	class function WaitAll(const Handles: array of THandle; MilliSecondsTimeout: uint32): boolean; overload;
	class function WaitAll(const Handles: array of THandle; const Timeout: TTimeoutTime): boolean; overload;

	// Returns true if the handle is currently 'signaled'. Equivalent to Wait(0), in particular it also resets
	// auto-reset objects and requests ownership of a mutex.
	function IsSignaled: boolean;

	// Makes the Windows handle available for use in Windows functions. The handle must not be released.
	property Handle: THandle read FHandle;
  end;


  //===================================================================================================================
  // Encapsulates Windows kernel objects that have a 'signaled' state and whose invalid value is 0, which applies
  // to thread and process handles as well as to handles of synchronization objects.
  //===================================================================================================================
  TNonFileHandle = class(TWaitHandle)
  public
	// Stores the given handle in a private field.
	// If the given handle is 0, an EOSSysError exception is thrown for the Windows error code <ErrorCode>.
	constructor Create(Handle: THandle; ErrorCode: DWORD);

	// Closes the handle.
	destructor Destroy; override;
  end;


  //===================================================================================================================
  // Encapsulates Windows kernel objects that have a 'signaled' state and whose handle invalid value is INVALID_HANDLE_VALUE,
  // which applies to file handle, directory handles and directory-change-notification handles.
  //===================================================================================================================
  TFileHandle = class(TWaitHandle)
  public
	// Stores the given handle in a private field.
	// If the given handle is INVALID_HANDLE_VALUE, an EOSSysError exception is thrown for the Windows error code <ErrorCode>.
	constructor Create(Handle: THandle; ErrorCode: DWORD);

	// Closes the handle.
	destructor Destroy; override;
  end;


  // How CreateNamed constructors work regarding named synchronization objects:
  THandleOpenMode = (
	homOpen,			// the Windows object must already exist, otherwise an exception is thrown
	homCreateNew,		// the Windows object must not yet exist, otherwise an exception is thrown
	homCreateOrOpen		// if the Windows object exists it will be opened, otherwise it will be created
  );


  //===================================================================================================================
  // Implements an event. The 'signaled' state can explicitly be set and reset by the application.
  //===================================================================================================================
  TEvent = class(TNonFileHandle)
  public
	// Createas an anonymous Windows Event object.
	// If {ManualReset} is false, the signaled state is automatically reset by the operating system when a wait call
	// has reacted to the signaled state of the event object.
	// If {ManualReset} is true, the signaled state is retained until it is explicitly reset by the application.
	constructor Create(ManualReset: boolean);

	// Createas a named Windows Event object.
	// If an existing event is openend, {ManualReset} is ignored.
	constructor CreateNamed(OpenMode: THandleOpenMode; const Name: string; ManualReset: boolean);

	// Sets the event to the 'signaled' state.
	procedure SetEvent;

	// Sets the event to the 'not signaled' state.
	procedure ResetEvent;
  end;


  //===================================================================================================================
  // Implements a mutex. The state of a mutex object is signaled when it is not owned by any thread.
  // A thread must use one of the wait functions to request ownership. Note, that calling IsSignaled() *also* requests
  // ownership!
  //
  // If an owned Windows Mutex object is closed without being explicitly released, the act of closing will *not* change
  // its state (the owning thread still owns it). Only when the owning thread ends, the status of the mutex changes to
  // "abandoned". This special status is not returned by this wrapper, as it does not come into play when mutex objects
  // are used within the same process and by using this wrapper class.
  //===================================================================================================================
  TMutex = class(TNonFileHandle)
  public
	// Creates an anonymous unowned Windows Mutex object.
	constructor Create;

	// Createas a named unowned Windows Mutex object.
	constructor CreateNamed(OpenMode: THandleOpenMode; const Name: string);

	// Releases the mutex and closes the handle.
	destructor Destroy; override;

	// Releases ownership, which sets the object to 'signaled'.
	// If the calling thread does not own the mutex, an exception is thrown.
	procedure Release;
  end;


  //===================================================================================================================
  // Implements a timer that is 'signaled' once after a given time or at periodic intervals.
  // If the timer expires, although it is still 'signaled' from the last expiration, nothing happens and the timer
  // object remains 'signaled'.
  //===================================================================================================================
  TWaitableTimer = class(TNonFileHandle)
  public
	// Creates a Windows Waitable Timer object that is not initially signaled.
	// If {ManualReset} is false, the signaled state is automatically reset by the operating system when a wait call
	// has reacted to the signaled state of the timer object.
	// If {ManualReset} is true, the signaled state is retained until it is explicitly reset by the application.
	constructor Create(ManualReset: boolean);

	// Starts or restarts the timer with the given parameters.
	// FirstTimeMilliSeconds: If non-zero, the timer is set to 'not signaled' and it will become 'signaled' after this
	// time has elapsed; if zero, the timer is immediately set to 'signaled'.
	// RepeatTimeMilliSeconds: If not zero, the timer is restarted automatically after each expiration.
	// (this restart does not reset the signaled state).
	procedure Start(FirstTimeMilliSeconds: uint32; RepeatTimeMilliSeconds: uint32 = 0);

	// Stops the timer. The signaled state of the timer object is *not* changed.
	// If the timer is not started, nothing happens.
	procedure Stop;

	// Stops the timer and resets the signaled state of the timer object.
	// If the timer is not started, nothing happens.
	procedure Reset;
  end;


{############################################################################}
implementation
{############################################################################}

uses
  StdLib;

const
  TicksPerMillisec = int64(10 * 1000);		// 100ns intervals per ms


{ TWaitHandle }

 //===================================================================================================================
 // Returns -1 for timeout, otherwise the index of the signaled handle.
 // The wait is not "alertable". Abandoned mutexes are considered 'signaled'.
 // <Handles> must contain between 1 and 64 elements.
 //===================================================================================================================
class function TWaitHandle.WaitMultiple(const Handles: array of THandle; MilliSecondsTimeout: uint32; WaitAll: boolean): integer;
var
  res: DWORD;
begin
  // up to MAXIMUM_WAIT_OBJECTS handles:
  res := Windows.WaitForMultipleObjects(System.Length(Handles), PWOHandleArray(@Handles[0]), WaitAll, MilliSecondsTimeout);
  case res of
  WAIT_OBJECT_0 .. WAIT_OBJECT_0 + MAXIMUM_WAIT_OBJECTS - 1:       exit(integer(res) - WAIT_OBJECT_0);
  WAIT_ABANDONED_0 .. WAIT_ABANDONED_0 + MAXIMUM_WAIT_OBJECTS - 1: exit(integer(res) - WAIT_ABANDONED_0);
  WAIT_TIMEOUT:       exit(-1);
  else                raise EOSSysError.Create(Windows.GetLastError);
  end;
end;


 //===================================================================================================================
 //===================================================================================================================
function TWaitHandle.Wait(MilliSecondsTimeout: uint32): boolean;
begin
  case Windows.WaitForSingleObject(FHandle, MilliSecondsTimeout) of
  WAIT_OBJECT_0, WAIT_ABANDONED_0:    exit(true);
  WAIT_TIMEOUT:                       exit(false);
  else                                raise EOSSysError.Create(Windows.GetLastError);
  end;
end;


 //===================================================================================================================
 //===================================================================================================================
function TWaitHandle.IsSignaled: boolean;
begin
  Result := self.Wait(0);
end;


 //===================================================================================================================
 //===================================================================================================================
function TWaitHandle.Wait(const Timeout: TTimeoutTime): boolean;
begin
  Result := self.Wait(Timeout.AsMilliSecs);
end;


 //===================================================================================================================
 //===================================================================================================================
class function TWaitHandle.WaitAny(const Handles: array of THandle; MilliSecondsTimeout: uint32): integer;
begin
  Result := self.WaitMultiple(Handles, MilliSecondsTimeout, false);
end;


 //===================================================================================================================
 //===================================================================================================================
class function TWaitHandle.WaitAny(const Handles: array of THandle; const Timeout: TTimeoutTime): integer;
begin
  Result := self.WaitMultiple(Handles, Timeout.AsMilliSecs, false);
end;


 //===================================================================================================================
 //===================================================================================================================
class function TWaitHandle.WaitAll(const Handles: array of THandle; MilliSecondsTimeout: uint32): boolean;
begin
  Result := self.WaitMultiple(Handles, MilliSecondsTimeout, true) <> -1;
end;


 //===================================================================================================================
 //===================================================================================================================
class function TWaitHandle.WaitAll(const Handles: array of THandle; const Timeout: TTimeoutTime): boolean;
begin
  Result := self.WaitMultiple(Handles, Timeout.AsMilliSecs, true) <> -1;
end;


{ TNonFileHandle }

 //===================================================================================================================
 //===================================================================================================================
constructor TNonFileHandle.Create(Handle: THandle; ErrorCode: DWORD);
begin
  FHandle := Handle;
  if Handle = 0 then raise EOSSysError.Create(ErrorCode);

  inherited Create;
end;


 //===================================================================================================================
 //===================================================================================================================
destructor TNonFileHandle.Destroy;
begin
  if FHandle <> 0 then begin
	Windows.CloseHandle(FHandle);
	FHandle := 0;
  end;

  inherited;
end;


{ TFileHandle }

 //===================================================================================================================
 //===================================================================================================================
constructor TFileHandle.Create(Handle: THandle; ErrorCode: DWORD);
begin
  FHandle := Handle;
  if Handle = INVALID_HANDLE_VALUE then raise EOSSysError.Create(ErrorCode);

  inherited Create;
end;


 //===================================================================================================================
 //===================================================================================================================
destructor TFileHandle.Destroy;
begin
  if FHandle <> INVALID_HANDLE_VALUE then begin
	Windows.CloseHandle(FHandle);
	FHandle := INVALID_HANDLE_VALUE;
  end;

  inherited;
end;


{ TWaitableTimer }

 //===================================================================================================================
 //===================================================================================================================
constructor TWaitableTimer.Create(ManualReset: boolean);
var
  Handle: THandle;
begin
  Handle := Windows.CreateWaitableTimer(nil, ManualReset, nil);
  inherited Create(Handle, Windows.GetLastError);
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TWaitableTimer.Start(FirstTimeMilliSeconds: uint32; RepeatTimeMilliSeconds: uint32 = 0);
var
  DueTimeArg: int64;
begin
  DueTimeArg := int64(FirstTimeMilliSeconds) * -TicksPerMillisec;

  Win32Check( Windows.SetWaitableTimer(FHandle, DueTimeArg, RepeatTimeMilliSeconds, nil, nil, false) );
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TWaitableTimer.Stop;
begin
  Win32Check( Windows.CancelWaitableTimer(FHandle) );
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TWaitableTimer.Reset;
const
  TicksPerDay = 24 * 60 * 60 * 1000 * TicksPerMillisec;
var
  DueTimeArg: int64;
begin
  DueTimeArg := -TicksPerDay;

  // to reset the signaled state (without signaling it when currently non-signaled!), a non-null dummy period must be set briefly:
  Win32Check(
		Windows.SetWaitableTimer(FHandle, DueTimeArg, 0, nil, nil, false)
	and Windows.CancelWaitableTimer(FHandle)
  );
end;


{ TEvent }

{$if not declared(CreateEventEx)}
function CreateEventEx(
	lpMutexAttributes: PSecurityAttributes;
	lpName: PChar;
	dwFlags: DWORD;
	dwDesiredAccess: DWORD
  ): THandle; stdcall; external Windows.kernel32 name {$ifdef UNICODE}'CreateEventExW'{$else}'CreateEventExA'{$endif};
{$ifend}

const
  CREATE_EVENT_MANUAL_RESET = $00000001;

 //===================================================================================================================
 //===================================================================================================================
constructor TEvent.Create(ManualReset: boolean);
var
  Flags: DWORD;
  Handle: THandle;
begin
  Flags := 0;
  if ManualReset then Flags := Flags or CREATE_EVENT_MANUAL_RESET;
  Handle := CreateEventEx(nil, nil, Flags, SYNCHRONIZE or EVENT_MODIFY_STATE);
  inherited Create(Handle, Windows.GetLastError);
end;


 //===================================================================================================================
 //===================================================================================================================
constructor TEvent.CreateNamed(OpenMode: THandleOpenMode; const Name: string; ManualReset: boolean);
var
  Flags: DWORD;
  Handle: THandle;
begin
  if OpenMode = homOpen then begin
	// open an existing Windows event:
	Handle := Windows.OpenEvent(SYNCHRONIZE or EVENT_MODIFY_STATE, false, PChar(Name));
  end
  else begin
	// create an new Windows event (but it will be opened, if it already exists and the permissions are right):
	Flags := 0;
	if ManualReset then Flags := Flags or CREATE_EVENT_MANUAL_RESET;

	Handle := CreateEventEx(nil, PChar(Name), Flags, SYNCHRONIZE or EVENT_MODIFY_STATE);

	if (Handle <> 0) and (OpenMode = homCreateNew) and (Windows.GetLastError = ERROR_ALREADY_EXISTS) then begin
	  // already exists, but a new one is demanded:
	  Windows.CloseHandle(Handle);
	  raise EOSSysError.Create(ERROR_ALREADY_EXISTS);
	end;
  end;

  inherited Create(Handle, Windows.GetLastError);
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TEvent.SetEvent;
begin
  Win32Check( Windows.SetEvent(FHandle) );
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TEvent.ResetEvent;
begin
  Win32Check( Windows.ResetEvent(FHandle) );
end;


{ TMutex }

// better prototype than in WinApi.Windows:
function CreateMutexEx(
	lpMutexAttributes: PSecurityAttributes;
	lpName: PChar;
	dwFlags: DWORD;
	dwDesiredAccess: DWORD
  ): THandle; stdcall; external Windows.kernel32 name {$ifdef UNICODE}'CreateMutexExW'{$else}'CreateMutexExA'{$endif};


 //===================================================================================================================
 //===================================================================================================================
constructor TMutex.Create;
var
  Handle: THandle;
begin
  Handle := CreateMutexEx(nil, nil, 0, SYNCHRONIZE or MUTEX_MODIFY_STATE);
  inherited Create(Handle, Windows.GetLastError);
end;


 //===================================================================================================================
 //===================================================================================================================
constructor TMutex.CreateNamed(OpenMode: THandleOpenMode; const Name: string);
var
  Handle: THandle;
begin
  if OpenMode = homOpen then begin
	// open an existing Windows mutex:
	Handle := Windows.OpenMutex(SYNCHRONIZE or MUTEX_MODIFY_STATE, false, PChar(Name));
  end
  else begin
	// create an new Windows mutex (but it will be opened, if it already exists and the permissions are right):
	Handle := CreateMutexEx(nil, PChar(Name), 0, SYNCHRONIZE or MUTEX_MODIFY_STATE);

	if (Handle <> 0) and (OpenMode = homCreateNew) and (Windows.GetLastError = ERROR_ALREADY_EXISTS) then begin
	  // already exists, but a new one is demanded:
	  Windows.CloseHandle(Handle);
	  raise EOSSysError.Create(ERROR_ALREADY_EXISTS);
	end;
  end;

  inherited Create(Handle, Windows.GetLastError);
end;


 //===================================================================================================================
 //===================================================================================================================
destructor TMutex.Destroy;
begin
  // always try to release ownership before closing the handle:
  if FHandle <> 0 then Windows.ReleaseMutex(FHandle);
  inherited;
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TMutex.Release;
begin
  Win32Check( Windows.ReleaseMutex(FHandle) );
end;


end.
