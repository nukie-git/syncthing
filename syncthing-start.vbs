' ==============================================================================
' Syncthing - Silent Background Launcher (WMI Detached)
' Stargazer Media Services Portable Deployment
' Launches syncthing.exe completely detached via WMI Win32_Process.Create
' (parent PID 4 / System) so it survives parent-shell and subshell teardowns.
' Includes native WMI process guard for safe idempotent execution.
' ==============================================================================

Option Explicit

Dim WshShell, FSO, WMI, ScriptDir, SyncthingExe, DataDir, Cmd, colProcs

Set WshShell = CreateObject("WScript.Shell")
Set FSO      = CreateObject("Scripting.FileSystemObject")
Set WMI      = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")

ScriptDir    = FSO.GetParentFolderName(WScript.ScriptFullName)
SyncthingExe = FSO.BuildPath(ScriptDir, "syncthing.exe")
DataDir      = FSO.BuildPath(ScriptDir, "data")

If Not FSO.FileExists(SyncthingExe) Then
    WshShell.Popup "Syncthing binary not found at " & SyncthingExe, 5, "Syncthing", 16
    WScript.Quit 1
End If

If Not FSO.FolderExists(DataDir) Then
    FSO.CreateFolder(DataDir)
End If

' 1. Clean up stale sentinel flag if leftover
Dim SentinelFlag
SentinelFlag = FSO.BuildPath(ScriptDir, "syncthing.flag")
If FSO.FileExists(SentinelFlag) Then
    On Error Resume Next
    FSO.DeleteFile SentinelFlag, True
    On Error GoTo 0
End If

' 2. Guard: Check if Syncthing is already running (native fast WMI query)
Set colProcs = WMI.ExecQuery("Select ProcessId from Win32_Process Where Name = 'syncthing.exe'")
If colProcs.Count > 0 Then
    ' Already running - exit silently (idempotent)
    WScript.Quit 0
End If

' 3. Launch fully detached via WMI Win32_Process.Create
Cmd = Chr(34) & SyncthingExe & Chr(34) & " serve --no-browser --no-console --home=" & Chr(34) & DataDir & Chr(34)

Dim ProcessStartup, Config, Process, ReturnValue
Set ProcessStartup = WMI.Get("Win32_ProcessStartup")
Set Config = ProcessStartup.SpawnInstance_
Config.ShowWindow = 0

Set Process = WMI.Get("Win32_Process")
ReturnValue = Process.Create(Cmd, ScriptDir, Config, Nothing)

If ReturnValue <> 0 Then
    WshShell.Popup "Failed to start Syncthing (WMI error " & ReturnValue & ")", 5, "Syncthing", 16
    WScript.Quit ReturnValue
End If
