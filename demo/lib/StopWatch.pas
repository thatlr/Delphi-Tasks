unit StopWatch;

{
  - TStopWatch: Supports accurate time measurements

}

{$include LibOptions.inc}

interface

type
  //=============================================================================
  // High resolution stopwatch (approximately 1 microsecond).
  //=============================================================================
  TStopWatch = record
  strict private
	FCounts: int64;
	function GetElapsed: double;
  public
	procedure Start;
	procedure Stop;
	property ElapsedSecs: double read GetElapsed;
  end;


{############################################################################}
implementation
{############################################################################}

uses Windows;


{ TStopWatch }

 //=============================================================================
 // Starts the measurement.
 //=============================================================================
procedure TStopWatch.Start;
begin
  // On systems that run Windows XP or later, the function will always succeed:
  Windows.QueryPerformanceCounter(FCounts);
end;


 //=============================================================================
 // Stops the measurement.
 //=============================================================================
procedure TStopWatch.Stop;
var
  EndCount: int64;
begin
  Windows.QueryPerformanceCounter(EndCount);
  FCounts := EndCount - FCounts;
end;


 //=============================================================================
 // Returns the duration from Start() to Stop().
 //=============================================================================
function TStopWatch.GetElapsed: double;
var
  CountsPerSecond: int64;
begin
  // On systems that run Windows XP or later, the function will always succeed:
  Windows.QueryPerformanceFrequency(CountsPerSecond);
  Result := FCounts / CountsPerSecond;
end;

end.
