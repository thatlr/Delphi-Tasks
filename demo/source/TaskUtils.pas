unit TaskUtils;

{$include CompilerOptions.inc}

interface

uses
  SysUtils,
  Tasks;

type
  //===================================================================================================================
  // Represents an action that eventually produces an result of some given type.
  //===================================================================================================================
  ITask<TResult> = interface(ITask)
	// Waits infinitely for the task to complete and than returns its result, or throws the task's exception.
	function Value: TResult;
  end;


  //===================================================================================================================
  // Collection of methods to implement more or less useful functionality on top of threadpools and tasks.
  //===================================================================================================================
  TParallel = record
  public
	// Uses maximum <ParallelThreads> threads to execute <IteratorProc> as often as <LoopRuns> indicates.
	// <IteratorProc> is called with values according to the following pseudo-code:
	//
	//  while LoopRuns > 0 do begin
	//    InteratorProc(StartValue);
	//    inc(StartValue, Increment);
	//    dec(LoopRuns);
	//  end;
	//
	// Returns after all IteratorProc calls have been completed.
	class procedure ForEachInt(StartValue, Increment: int32; LoopRuns, ParallelThreads: uint32; const CancelObj: ICancel; const IteratorProc: TProc<int32>); static;

	// Creates a task to execute "Func" and queues it to the default thread pool. The result (once produced) is
	// accessible by the ITask<TResult>.Value method.
	class function QueueFunc<TResult>(const Func: TFunc<TResult>): ITask<TResult>; overload; static;

	// Creates a task to execute "Func(Arg)" and queues it to the default thread pool. The result (once produced) is
	// accessible by the ITask<TResult>.Value method.
	class function QueueFunc<T, TResult>(const Func: TFunc<T, TResult>; Arg: T): ITask<TResult>; overload; static;

  strict private
	type
	  // Basis for generics TFuture classes with arbitrary result types:
	  TFutureBase = class abstract (TInterfacedObject, ITask)
	  strict protected
		FTask: ITask;
	  protected
		// >> ITask
		function State: TTaskState;
		function CompleteWH: TWaitHandle;
		function UnhandledException: Exception;
		function CancelObj: ICancel;
		function Wait(ThrowOnError: boolean; TimeoutMillisecs: uint32): boolean;
		// << ITask
	  end;

	  // implements ITask<TResult> (this code is instanciated by the compiler for each indiviual type):
	  TFuture<TResult> = class sealed (TFutureBase, ITask<TResult>)
	  strict private
		FResult: TResult;
	  protected
		// >> ITask<TResult>
		function Value: TResult;
		// << ITask<TResult>
	  public
		constructor Create(const Func: TFunc<TResult>);
	  end;
  end;


{############################################################################}
implementation
{############################################################################}


{ TParallel.TFutureBase }

 //===================================================================================================================
 //===================================================================================================================
function TParallel.TFutureBase.State: TTaskState;
begin
  Result := FTask.State;
end;
function TParallel.TFutureBase.CompleteWH: TWaitHandle;
begin
  Result := FTask.CompleteWH;
end;
function TParallel.TFutureBase.UnhandledException: Exception;
begin
  Result := FTask.UnhandledException;
end;
function TParallel.TFutureBase.CancelObj: ICancel;
begin
  Result := FTask.CancelObj;
end;
function TParallel.TFutureBase.Wait(ThrowOnError: boolean; TimeoutMillisecs: uint32): boolean;
begin
  Result := FTask.Wait(ThrowOnError, TimeoutMillisecs);
end;


{ TParallel.TFuture<TResult> }

 //===================================================================================================================
 // Creates a task to execute <Func> and queues it to the default thread pool.
 //===================================================================================================================
constructor TParallel.TFuture<TResult>.Create(const Func: TFunc<TResult>);
begin
  inherited Create;

  FTask := TThreadPool.Run(
	procedure (const CancelObj: ICancel)
	begin
	  FResult := Func();
	end
  );
end;


 //===================================================================================================================
 // Implementes ITask<TResult>.Value
 //===================================================================================================================
function TParallel.TFuture<TResult>.Value: TResult;
begin
  FTask.Wait(true);
  Result := FResult;
end;


{ TParallel }

 //===================================================================================================================
 //===================================================================================================================
class function TParallel.QueueFunc<TResult>(const Func: TFunc<TResult>): ITask<TResult>;
begin
  Result := TFuture<TResult>.Create(
	function (): TResult
	begin
	  Result := Func();
	end
  );
end;


 //===================================================================================================================
 //===================================================================================================================
class function TParallel.QueueFunc<T, TResult>(const Func: TFunc<T, TResult>; Arg: T): ITask<TResult>;
begin
  Result := TFuture<TResult>.Create(
	function (): TResult
	begin
	  Result := Func(Arg);
	end
  );
end;


 //===================================================================================================================
 //===================================================================================================================
class procedure TParallel.ForEachInt(StartValue, Increment: int32; LoopRuns, ParallelThreads: uint32; const CancelObj: ICancel; const IteratorProc: TProc<int32>);

  function _Capture(Value: int32): ITaskProcRef;
  begin
	Result := procedure (const CancelObj: ICancel) begin IteratorProc(Value); end;
  end;

var
  Pool: TThreadPool;
begin
  // Use a separate pool to easily wait for the completion of all tasks:
  Pool := TThreadPool.Create(ParallelThreads, 16 * ParallelThreads, 10000, 0);
  try
	while (LoopRuns > 0) and not CancelObj.IsCancelled do begin
	  Pool.Queue(_Capture(StartValue), CancelObj);
	  inc(StartValue, Increment);
	  dec(LoopRuns);
	end;
	Pool.Wait;
  finally
	Pool.Free;
  end;
end;

end.

