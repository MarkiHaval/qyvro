# Регистрирует сервер общего буфера (при загрузке, без входа, как BrainServer)
# и клиент буфера Windows (при входе, в сеансе пользователя, как Neyrych).
$ErrorActionPreference = 'Stop'
$dir = 'D:\QyvroClip'
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$name = "$env:COMPUTERNAME\$env:USERNAME"

function TaskXml($trigger, $logonType, $exe, $mode) {
@"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>$logonType</LogonType></Principal></Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <RestartOnFailure><Count>999</Count><Interval>PT1M</Interval></RestartOnFailure>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Triggers>$trigger</Triggers>
  <Actions Context="Author"><Exec>
    <Command>$dir\.venv\Scripts\$exe</Command>
    <Arguments>-X utf8 "$dir\qyvro_clip.py" $mode</Arguments>
    <WorkingDirectory>$dir</WorkingDirectory>
  </Exec></Actions>
</Task>
"@
}

Register-ScheduledTask -TaskName 'QyvroClipServer' -Force `
  -Xml (TaskXml '<BootTrigger />' 'S4U' 'python.exe' 'serve') | Out-Null
Register-ScheduledTask -TaskName 'QyvroClipClient' -Force `
  -Xml (TaskXml "<LogonTrigger><Delay>PT20S</Delay><UserId>$name</UserId></LogonTrigger>" 'InteractiveToken' 'pythonw.exe' 'client') | Out-Null

Start-ScheduledTask -TaskName 'QyvroClipServer'
Start-Sleep 2
Start-ScheduledTask -TaskName 'QyvroClipClient'
Start-Sleep 3
Get-ScheduledTask -TaskName 'QyvroClip*' | Select-Object TaskName, State | Format-Table -AutoSize
