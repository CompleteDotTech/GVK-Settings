[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$CompilerPath,
    [Parameter(Mandatory=$true)][string[]]$ReferencePaths,
    [Parameter(Mandatory=$true)][string]$InputHashesJson
)
$ErrorActionPreference = 'Stop'
$expected = [ordered]@{
    'ModScripts/GVK_KothClient.cs' = '8b8f8991ea7bf5b3fb42bef6ed053cce94005586b3b62b690d1a4372c4d59937'
    'ModScripts/GVK_ZoneNavCommand.cs' = 'dbb0260016177c27c46d5f364360ed28308eef987c61da92d1275a8c9ba37d10'
    'ModScripts/API/HudAPIv2.cs' = '04c54d617254c5f423d4d4f9f386a9448b51057ed32f0a9b11121c1b9e7714a2'
}
$root = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
$compiler = (Resolve-Path -LiteralPath $CompilerPath).ProviderPath
$hashFile = (Resolve-Path -LiteralPath $InputHashesJson).ProviderPath
$refs = @($ReferencePaths | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath })
if ($refs.Count -eq 0) { throw 'ReferencePaths must contain explicit compiler reference paths.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'OutputDirectory must not already exist.' }
$pins = Get-Content -LiteralPath $hashFile -Raw | ConvertFrom-Json
if ($null -eq $pins -or @($pins.PSObject.Properties).Count -ne $expected.Count) { throw 'InputHashesJson must be an object with exactly the three required source paths.' }
$source=@{}; $paths=@{}; $provenance=[Collections.Generic.List[string]]::new()
foreach ($key in $expected.Keys) {
    $p=$pins.PSObject.Properties[$key]
    if ($null -eq $p -or $p.Value -isnot [string] -or $p.Value -notmatch '^[0-9a-fA-F]{64}$' -or $p.Value -ne $expected[$key]) { throw "Missing or incorrect settled pin: $key" }
    $path=(Resolve-Path -LiteralPath (Join-Path $root $key)).ProviderPath
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne $p.Value) { throw "Source hash mismatch: $key" }
    $paths[$key]=$path; $source[$key]=[IO.File]::ReadAllText($path)
    $provenance.Add("input $key $hash")
}
foreach ($path in @($hashFile,$compiler)+$refs) { $provenance.Add("tool/input $path $((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)") }
function HashText([string]$value) {
    $h=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($value))).Replace('-','') } finally { $h.Dispose() }
}
function UniqueIndex([string]$text,[string]$needle) {
    $i=$text.IndexOf($needle,[StringComparison]::Ordinal)
    if ($i -lt 0 -or $text.IndexOf($needle,$i+$needle.Length,[StringComparison]::Ordinal) -ge 0) { throw "Extraction anchor missing or ambiguous: $needle" }
    return $i
}
function Slice([string]$text,[string]$start,[string]$end,[string]$id) {
    $a=UniqueIndex $text $start; $b=$text.IndexOf($end,$a+$start.Length,[StringComparison]::Ordinal)
    if ($b -le $a) { throw "Extraction order invalid: $id" }
    $piece=$text.Substring($a,$b-$a)
    $provenance.Add("extracted $id UTF8-SHA256 $(HashText $piece)")
    return $piece
}
# All anchors are unique in the pinned files. Slice boundaries retain production text verbatim.
$vendor=$source['ModScripts/API/HudAPIv2.cs']
$fields=Slice $vendor 'private static HudAPIv2 instance;' 'public enum TextOrientation : byte' 'HudAPIv2.fields-and-OnScreenDimensionsChanged'
$lifecycle=Slice $vendor 'public HudAPIv2(Action onRegisteredAction = null)' '#region Intercomm' 'HudAPIv2.constructor-Close-Unload-RegistrationEnum-RegisterComponents-Heartbeat'
$set=Slice $vendor 'private void MessageSet(object BackingObject, int Member, object Value)' 'private void RegisterCheck()' 'HudAPIv2.MessageSet'
$screen=Slice $vendor 'private void ScreenChangedHandle()' '#endregion' 'HudAPIv2.ScreenChangedHandle'
$koth=$source['ModScripts/GVK_KothClient.cs']; $nav=$source['ModScripts/GVK_ZoneNavCommand.cs']
$broker=Slice $koth 'internal static class GvkHudBroker' '    /// <summary>' 'GVK.Navigation.GvkHudBroker.complete-class'
# These checks are static source checks; no consumer code executes in the harness.
foreach ($entry in @(@('KOTH',$koth),@('navigation',$nav))) {
    $label=$entry[0]; $text=$entry[1]
    if ([regex]::Matches($text,'GvkHudBroker\.Acquire\(OnHudApiRegistered\)').Count -ne 1 -or [regex]::Matches($text,'GvkHudBroker\.Release\(OnHudApiRegistered\)').Count -ne 1 -or $text -notmatch 'MyAPIGateway\.Utilities\.IsDedicated') { throw "Consumer wiring check failed: $label" }
    if ($label -eq 'KOTH') { $text=$text.Replace($broker,'') }
    if ($text -match 'new\s+HudAPIv2\s*\(' -or $text -match '\bhudApi\s*\.\s*Close\s*\(') { throw "Direct consumer lifecycle found: $label" }
    $provenance.Add("source-check PASS $label Acquire/Release and dedicated guard; no direct wrapper constructor/Close")
}
if ([regex]::Matches($broker,'new\s+HudAPIv2\s*\(').Count -ne 1 -or [regex]::Matches($broker,'\bclosing\.Close\s*\(').Count -ne 1) { throw 'Broker constructor/close source check failed.' }
$provenance.Add('scope: exact extracted lifecycle and broker; UI, APIDialog, game gateway, provider and logging are mocks. No rendering, real provider scheduling, sender/scanner, multiplayer, MES, persistence/queue or VM claim.')
$prefix=@'
using System;
using System.Collections.Generic;
using Draygo.API;
using Sandbox.ModAPI;
using VRage;
using VRage.Utils;
namespace VRage {
 public struct MyTuple<T> { public T Item1; public MyTuple(T a) { Item1=a; } }
 public struct MyTuple<T1,T2,T3,T4> { public T1 Item1; public T2 Item2; public T3 Item3; public T4 Item4; public MyTuple(T1 a,T2 b,T3 c,T4 d) { Item1=a; Item2=b; Item3=c; Item4=d; } }
}
namespace Sandbox.ModAPI {
 public static class MyAPIGateway { public static UtilitiesMock Utilities=new UtilitiesMock(); }
 public class UtilitiesMock {
  public readonly List<Action<object>> handlers=new List<Action<object>>(); public int registrations,unregistrations,sets;
  public void RegisterMessageHandler(long id,Action<object> h) { registrations++; handlers.Add(h); }
  public void UnregisterMessageHandler(long id,Action<object> h) { unregistrations++; handlers.Remove(h); }
  public void Notify() {
   var tuple=new MyTuple<Func<int,object>,Action<object,int,object>,Func<object,int,object>,Action<object>>(i=>null,(o,i,v)=>{sets++;},(o,i)=>null,o=>{});
   foreach(var h in handlers.ToArray()) h(tuple);
  }
 }
}
namespace VRage.Utils { public class MyLog { public static MyLog Default=new MyLog(); public void WriteLineAndConsole(string s) { Console.WriteLine("LOG "+s); } } }
namespace Draygo.API {
 public static class APIDialog { public static void GetDialogMethods(Func<object,int,object> getter) {} }
 public class HudAPIv2 {
'@
$middle="`n }`n}`nnamespace GVK.Navigation {`n" + $broker + "`n}`n"
$runner=@'
namespace Probe {
 using GVK.Navigation;
 class Program {
  static int pass,fail;
  static void Check(string name,bool value) { Console.WriteLine((value?"PASS ":"FAIL ")+name); if(value) pass++; else fail++; }
  static int Main(string[] args) {
   try {
    string mode=args[0]; bool reverse=args[1]=="reverse"; var u=MyAPIGateway.Utilities;
    int a=0,b=0; Action ca=()=>a++; Action cb=()=>b++; Action first=reverse?cb:ca, second=reverse?ca:cb;
    if(mode=="negative") {
     var one=new HudAPIv2(first); var two=new HudAPIv2(second); u.Notify(); u.Notify();
     Console.WriteLine("negative observed firstCallback="+(reverse?b:a)+" secondCallback="+(reverse?a:b)+" firstHeartbeat="+one.Heartbeat+" secondHeartbeat="+two.Heartbeat);
     Check("negative first callback=1 second callback=0",(reverse?b:a)==1 && (reverse?a:b)==0);
     Check("negative first heartbeat=true second heartbeat=false",one.Heartbeat && !two.Heartbeat);
     one.Close();
    } else if(mode=="fixed" || mode=="late") {
     var one=GvkHudBroker.Acquire(first); if(mode=="late") u.Notify();
     var two=GvkHudBroker.Acquire(second); var duplicate=GvkHudBroker.Acquire(first);
     Check("shared reference and duplicate acquire",Object.ReferenceEquals(one,two) && Object.ReferenceEquals(one,duplicate) && u.registrations==1);
     u.Notify(); u.Notify(); Check("both callbacks exactly once",a==1 && b==1 && one.Heartbeat && two.Heartbeat);
     GvkHudBroker.Release(()=>{}); GvkHudBroker.Release(first); GvkHudBroker.Release(first);
     Check("survivor heartbeat and delegates",two.Heartbeat && u.unregistrations==0 && u.handlers.Count==1 && u.sets==1);
     GvkHudBroker.Release(second); Check("last release unregisters once",u.unregistrations==1 && u.handlers.Count==0 && !one.Heartbeat);
     int fresh=0; Action next=()=>fresh++; var three=GvkHudBroker.Acquire(next); u.Notify();
     Check("fresh lifecycle and subscribers",!Object.ReferenceEquals(one,three) && fresh==1 && a==1 && b==1 && three.Heartbeat && u.registrations==2);
     GvkHudBroker.Release(next); Check("fresh lifecycle closes",u.unregistrations==2 && u.handlers.Count==0);
    } else if(mode=="exception") {
     int delivered=0; Action bad=()=>{throw new Exception("expected callback exception");}; Action good=()=>delivered++;
     GvkHudBroker.Acquire(bad); GvkHudBroker.Acquire(good); u.Notify(); u.Notify();
     Check("callback exception isolated",delivered==1); GvkHudBroker.Release(bad); GvkHudBroker.Release(good);
    } else if(mode=="reentrant") {
     int delivered=0; Action secondCallback=()=>delivered++; Action firstCallback=()=>GvkHudBroker.Release(secondCallback);
     GvkHudBroker.Acquire(firstCallback); GvkHudBroker.Acquire(secondCallback); u.Notify();
     Check("release during snapshot skips removed listener",delivered==0 && u.handlers.Count==1); GvkHudBroker.Release(firstCallback);
     Check("reentrant lifecycle closes",u.unregistrations==1 && u.handlers.Count==0);
    } else throw new Exception("unknown mode");
   } catch(Exception ex) { Console.WriteLine("ERROR "+ex); fail++; }
   Console.WriteLine("TOTAL PASS="+pass+" FAIL="+fail); return fail==0 && pass>0?0:1;
  }
 }
}
'@
$program=$prefix+"`n"+$fields+"`n"+$lifecycle+"`n"+$set+"`n"+$screen+$middle+$runner
$provenance.Add("generated Probe.cs UTF8-SHA256 $(HashText $program)")
foreach ($key in $expected.Keys) { if ((Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash -ne $expected[$key]) { throw "Input changed during extraction: $key" } }
$out=[IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($out) | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$src=Join-Path $out 'Probe.cs'; $exe=Join-Path $out 'Probe.exe'
[IO.File]::WriteAllText($src,$program,$utf8)
[IO.File]::WriteAllLines((Join-Path $out 'provenance.txt'),$provenance,$utf8)
$oldTemp=$env:TEMP; $oldTmp=$env:TMP
try {
 $env:TEMP=$out; $env:TMP=$out
 Push-Location -LiteralPath $out
 try {
  $arguments=@('/nologo','/target:exe','/langversion:6',"/out:$exe")
  foreach ($ref in $refs) { $arguments += "/reference:$ref" }; $arguments += $src
  & $compiler @arguments *> (Join-Path $out 'compiler.log')
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw 'Compilation failed; inspect compiler.log.' }
  $failed=0; $totalPass=0; $totalFail=0
  foreach ($case in @('negative forward','negative reverse','fixed forward','fixed reverse','late forward','late reverse','exception forward','reentrant forward')) {
   $parts=$case.Split(' '); $log=Join-Path $out ("result-"+$parts[0]+"-"+$parts[1]+'.log')
   & $exe $parts[0] $parts[1] *> $log
   $exitCode=$LASTEXITCODE
   $totals=@(Select-String -LiteralPath $log -Pattern '^TOTAL PASS=(\d+) FAIL=(\d+)$')
   if ($totals.Count -ne 1) { $failed++; continue }
   $totalPass += [int]$totals[0].Matches[0].Groups[1].Value
   $totalFail += [int]$totals[0].Matches[0].Groups[2].Value
   if ($exitCode -ne 0) { $failed++ }
  }
  Write-Output "Behavioral assertion totals: PASS=$totalPass FAIL=$totalFail; process failures=$failed"
  if ($failed -ne 0 -or $totalFail -ne 0) { throw "$failed behavioral process(es) failed; inspect result logs." }
  Write-Output "PASS: source checks and all eight isolated behavioral processes; artifacts: $out"
 } finally { Pop-Location }
} catch { Write-Output "FAIL: $_"; throw } finally { $env:TEMP=$oldTemp; $env:TMP=$oldTmp }
