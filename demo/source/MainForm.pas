unit MainForm;

{
  Highly theoretical example to demonstrate the usage of tasks with a Delphi form.

  *** Important note:

  If you start this program from the Delphi 2009 IDE and press the "Count Prime numbers" button, you will probably be
  disappointed, as the application and the IDE become slow and stuttering. This is due to the Delphi debugger reacting
  extremly slow to creation and destruction of threads. You can open the "Event Log" window to watch this.
  If the ThreadIdleMillisecs parameter is too low, and the debugger is extremly slowing down everyhing, it will cause
  all pool threads to timeout all the time, causing constant creating and finishing of the threads.
}

{$include CompilerOptions.inc}

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs, StdCtrls, ExtCtrls, Menus,
  Tasks, GuiTasks;

type
  TfMainForm = class(TForm)
    TMainMenu: TMainMenu;
    TMenu: TMenuItem;
    TMemuItem: TMenuItem;
    btCountPrimeNumbers: TButton;
    btOpenMsgBox: TButton;
    Panel1: TPanel;
    lblPrimeResult: TLabel;
    Panel2: TPanel;
    lblRGB: TLabel;
    procedure FormActivate(Sender: TObject);
	procedure FormClose(Sender: TObject; var Action: TCloseAction);
	procedure btCountPrimeNumbersClick(Sender: TObject);
    procedure btOpenMsgBoxClick(Sender: TObject);
  private
	FPool: TThreadPool;
	FTask: ITask;
	FCancel: ICancel;
	procedure UpdateGui(const CancelObj: ICancel; ThreadNum: integer);
	procedure PrimeTest(const CancelObj: ICancel);

	class function IsPrime(N: Integer): boolean;
  end;

var
  fMainForm: TfMainForm;

{############################################################################}
implementation
{############################################################################}

uses
  AppEvnts,
  StdLib,
  MsgBox,
  StopWatch,
  TaskUtils;

{$R *.dfm}

 //===================================================================================================================
 //===================================================================================================================
procedure TfMainForm.FormActivate(Sender: TObject);
{
var
  Task: ITask;
}
begin
  self.Constraints.MinWidth := self.Width;
  self.Constraints.MinHeight := self.Height;

{
  Task := TThreadPool.Run(procedure (const C: ICancel) begin Abort; end);
  Task.Wait;
  Assert(Task.State = TTaskState.Completed);
  Assert(Task.UnhandledException = nil);

  Task := TThreadPool.Run(procedure (const C: ICancel) begin raise Exception.Create('test'); end);
  Task.Wait(false);
  Assert(Task.State = TTaskState.Failed);
  Assert(Task.UnhandledException <> nil);

  TMsgBox.Show(Task.UnhandledException.StackTrace);
}

  // create one single cancellation object for all tasks created by this form:
  FCancel := TCancelFlag.Create;

  // create a thread pool with two tasks:
  FPool := TThreadPool.Create(3, 10000, 1000, 64);

  FPool.Queue(
	procedure (const CancelObj: ICancel)
	begin
	  UpdateGui(CancelObj, 1);
	end,
	FCancel
  );

  FPool.Queue(
	procedure (const CancelObj: ICancel)
	begin
	  UpdateGui(CancelObj, 2);
	end,
	FCancel
  );

  // create another task in the default thread pool:
  FTask := TThreadPool.Run(
	procedure (const CancelObj: ICancel)
	begin
	  UpdateGui(CancelObj, 3);
	end,
	FCancel
  );
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TfMainForm.FormClose(Sender: TObject; var Action: TCloseAction);
var
  i: integer;
begin
  self.ModalResult := mrCancel;

  // terminate all tasks running in the context of this form:
  FCancel.Cancel;

  // wait for this task with reduced message-processing:
  FTask.Wait;

  // just test: queue a large number of tasks, then destroy the thread pool:
  for i := 1 to 5000 do begin
	FPool.Queue(procedure (const Cancel: ICancel) begin end, nil);
  end;

  // The thread pool destructor waits for all its tasks to finish. To prevent a deadlock here, it is mandatory that all
  // this tasks use FCancel, and FCancel is set at this point. (This would not apply if the tasks in question do not
  // call TGuiThread.Perform().)
  FreeObj(FPool);
end;


 //===================================================================================================================
 // Executed in a task of the <FPool> thread pool.
 // Manipulates one of the RGB channels of the form's background color.
 //===================================================================================================================
procedure TfMainForm.UpdateGui(const CancelObj: ICancel; ThreadNum: integer);
var
  Color: byte;
  Up: boolean;
begin
  Up := true;
  repeat
	Windows.Sleep(15 + 5 * ThreadNum);

	// make i to count up and down between 0 and 255:
	if Up then inc(Color) else dec(Color);
	if Color = 0 then Up := true
	else if Color = 255 then Up := false;

	TGuiThread.Perform(
	  procedure ()
	  var
		TmpCol: DWORD;
		r, g, b: byte;
	  begin
		TmpCol := DWORD(Graphics.ColorToRGB(self.Color));
		r := Windows.GetRValue(TmpCol);
		g := Windows.GetGValue(TmpCol);
		b := Windows.GetBValue(TmpCol);
		case ThreadNum of
		1: r := Color;
		2: g := Color;
		3: b := Color;
		end;
		self.Color := TColor(Windows.RGB(r,g,b));
		self.lblRGB.Caption := Format('R=%u G=%u B=%u', [r, g, b]);
	  end,
	  CancelObj
	);

  until CancelObj.IsCancelled;
end;


 //===================================================================================================================
 // CPU-burning function: Returns true, if N is a prime number (2, 3, 5, 7, ...)
 //===================================================================================================================
class function TfMainForm.IsPrime(N: int32): boolean;
var
  Test: int32;
begin
  for Test := 2 to N div 2 do begin
	if N mod Test = 0 then exit(false);
  end;
  exit(true);
end;


 //===================================================================================================================
 // Executed in a task of the default thread pool.
 // https://en.wikipedia.org/wiki/Prime-counting_function
 //===================================================================================================================
procedure TfMainForm.PrimeTest(const CancelObj: ICancel);
const
  LowerBound = 2;
  //UpperBound = 10;			// => 4
  //UpperBound = 100;			// => 25
  //UpperBound = 1000;			// => 168
  //UpperBound = 100 * 1000;	// => 9592
  UpperBound = 1000 * 1000;		// => 78498
  //UpperBound = 10 * 1000 * 1000;	// => 664579
var
  total: int32;
  Watch: TStopWatch;
  Seconds: double;
begin
  Watch.Start;

  total := 0;

  // count from <LowerBound> to <UpperBound> and create one task for each value:

  // Under the hoods, this employs a temporary thread pool which only allows the given number of threads to run in
  // parallel.
  // Personally, I don't think that things like that are a good programming practice, as the overhead is still too
  // high for real "high-performance computing". One should not create a high number of some tasks (by using a
  // generic ForEach method) without taking the nature of the tasks into account. At the very least, when something is
  // supposed to use all available CPU power, the priority of all participating threads should probably be the lowest
  // possible. On the other hand, if the tasks are long-running and yield often (for example, database operations),
  // such tasks should be queued to the default pool, and this default pool should *not* be limited to the number of
  // available CPU cores.

  TParallel.ForEachInt(
	LowerBound,						// first value
	1,								// increment
	UpperBound - LowerBound + 1,	// number of iterations
	System.CPUCount,				// number of threads
	CancelObj,                      // to stop when the form is closed
	procedure (i: Integer)
	begin
	  if IsPrime(i) then Windows.InterlockedIncrement(total);
	end
  );

  Seconds := Watch.ElapsedSecs;

  // displaying the result must be delegated to the GUI thread:
  TGuiThread.Perform(
	procedure ()
	begin
	  lblPrimeResult.Caption := Format('CPU cores used: %d' + CrLf + 'Number of prime numbers between %d and %d: %d' + CrLf + 'Duration: %.3f seconds', [
		System.CPUCount,
		LowerBound,
		UpperBound,
		Total,
		Seconds
	  ]);
	  TMsgBox.Show('Displayed through TGuiThread.Perform(), blocking the respective task.');
	  btCountPrimeNumbers.Enabled := true;
	end,
	CancelObj
  );
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TfMainForm.btCountPrimeNumbersClick(Sender: TObject);
begin
  btCountPrimeNumbers.Enabled := false;
  lblPrimeResult.Caption := 'Counting...';

  TThreadPool.Run(self.PrimeTest, FCancel);
end;


 //===================================================================================================================
 //===================================================================================================================
procedure TfMainForm.btOpenMsgBoxClick(Sender: TObject);
begin
  TMsgBox.Show('Displayed by a regular click event.');
end;

end.
