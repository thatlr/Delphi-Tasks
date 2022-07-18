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
	class var
	  FCountsPerSecond: int64;
	var
	  FStartCounts: int64;
  public
	procedure Start;
	function ElapsedSecs: double;
  end;


{############################################################################}
implementation
{############################################################################}

uses Windows;


{ TStopWatch }

 //=============================================================================
 // Starts the measurement, by capturing the current point-in-time.
 //=============================================================================
procedure TStopWatch.Start;
begin
  // On systems that run Windows XP or later, the function will always succeed:
  if FCountsPerSecond = 0 then Windows.QueryPerformanceFrequency(FCountsPerSecond);
  // On systems that run Windows XP or later, the function will always succeed:
  Windows.QueryPerformanceCounter(FStartCounts);
end;


 //=============================================================================
 // Returns the time elapsed since Start() was called. Can be called repeatly.
 //=============================================================================
function TStopWatch.ElapsedSecs: double;
var
  EndCounts: int64;
begin
  Windows.QueryPerformanceCounter(EndCounts);
  Result := (EndCounts - FStartCounts) / FCountsPerSecond;
end;

end.
