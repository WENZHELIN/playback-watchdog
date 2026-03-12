$AgentDir = "C:\PlaybackAgent"
$NodePath = "C:\Program Files\nodejs\node.exe"
$ScriptPath = "$AgentDir\dist\agent.js"

$Action = New-ScheduledTaskAction -Execute $NodePath -Argument $ScriptPath -WorkingDirectory $AgentDir
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

Register-ScheduledTask -TaskName "PlaybackAgent" -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force
Write-Host "Task Scheduler task registered. Will start on next boot."
