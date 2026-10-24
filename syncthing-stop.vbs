' ============================================================
' Stargazer Media Services — Syncthing Stop Script
' File: C:\PortableApps\syncthing\syncthing-stop.vbs
'
' Usage:
'   wscript.exe syncthing-stop.vbs          (interactive with completion popup)
'   wscript.exe syncthing-stop.vbs /silent  (headless stop without MsgBox)
' ============================================================
Option Explicit
Dim WshShell, i, silent

Set WshShell = CreateObject("WScript.Shell")
silent = False

For i = 0 To WScript.Arguments.Count - 1
    If LCase(WScript.Arguments(i)) = "/silent" Or LCase(WScript.Arguments(i)) = "-silent" Then
        silent = True
    End If
Next

' 1. Graceful API shutdown via REST API
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""try { Invoke-RestMethod -Uri 'http://127.0.0.1:8384/rest/system/shutdown' -Headers @{'X-API-Key'='gqQarZYXJkHDva9qZiEgVTe293AgmxY9'} -Method Post -TimeoutSec 2 | Out-Null; Start-Sleep -Milliseconds 800 } catch {}""", 0, True

' 2. Stop any remaining syncthing processes
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""Get-CimInstance Win32_Process | Where-Object { $_.Name -like '*syncthing*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }""", 0, True

' 3. Session 0 / SYSTEM fallback if port 8384 is still open
Dim FSO, scriptDir, flagFile, checkCmd, portOpen, flagStream
Set FSO = CreateObject("Scripting.FileSystemObject")
scriptDir = FSO.GetParentFolderName(WScript.ScriptFullName)
checkCmd = "powershell.exe -NoProfile -Command ""if (Get-NetTCPConnection -LocalPort 8384 -State Listen -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }"""
portOpen = WshShell.Run(checkCmd, 0, True)
If portOpen = 1 Then
    flagFile = FSO.BuildPath(scriptDir, "syncthing.flag")
    Set flagStream = FSO.CreateTextFile(flagFile, True)
    flagStream.WriteLine "stop"
    flagStream.Close
    WshShell.Run "schtasks /run /tn StargazerWinGetElevatedUpdater", 0, True
    WScript.Sleep 2500
End If

If Not silent And WScript.Arguments.Count = 0 Then
    MsgBox "Syncthing has been stopped.", 64, "Syncthing Status"
End If
