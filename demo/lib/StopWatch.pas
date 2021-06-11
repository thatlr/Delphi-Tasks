unit StopWatch;

{
  - TStopWatch: Stoppuhr für genaue Zeitmessungen.


  Änderungen:
}

{$include LibOptions.inc}

interface

type
  //=============================================================================
  // Stoppuhr mit hoher Auflösung (ungefähr 1 Mikrosekunde).
  //=============================================================================
  TStopWatch = record
  strict private
	class var FCountsPerSecond: int64;
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
 // Liefert die aufgelaufende Dauer als TTimeSpan.
 //=============================================================================
function TStopWatch.GetElapsed: double;
begin
  // On systems that run Windows XP or later, the function will always succeed:
  if FCountsPerSecond = 0 then Windows.QueryPerformanceFrequency(FCountsPerSecond);;
  Result := FCounts / FCountsPerSecond;
end;

end.
