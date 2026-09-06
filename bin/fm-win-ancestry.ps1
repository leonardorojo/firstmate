# fm-win-ancestry.ps1 - Windows process-ancestry source for fm-session-lock-lib.sh.
#
# Git Bash / MSYS ps cannot see native Windows processes, so firstmate's session
# lock reads the true parent chain and full command lines here instead. Given a
# start Windows pid, walk up the Win32_Process tree and print one tab-separated
# row per hop, innermost first:
#
#   <pid>\t<name>\t<commandline>
#
# With -ProcessId, emit only that live process using the same Win32_Process
# source. Name plays the role of `ps -o comm=` and commandline the role of
# `ps -o args=` for the harness matcher. The ancestry walk is bounded to 16
# hops; it stops at the first parent that is not a live process, is self/zero, or
# was created after its child. All processes are fetched once so a single CIM
# query serves either operation.

[CmdletBinding(DefaultParameterSetName = 'Ancestry')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Ancestry')]
  [int]$Start,
  [Parameter(Mandatory = $true, ParameterSetName = 'Process')]
  [int]$ProcessId
)

$ErrorActionPreference = 'Stop'

$byPid = @{}
Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CommandLine,CreationDate -ErrorAction Stop | ForEach-Object {
  $byPid[[int]$_.ProcessId] = $_
}

$TAB = [char]9
function Write-ProcessRow {
  param([Parameter(Mandatory = $true)]$Process)
  $name = $Process.Name
  $cmd = $Process.CommandLine
  # A tab or newline inside a value would corrupt the row the bash side splits on.
  if ($name) { $name = ($name -replace "[`t`r`n]", ' ') } else { $name = '' }
  if ($cmd)  { $cmd  = ($cmd  -replace "[`t`r`n]", ' ') } else { $cmd = '' }
  # Emit a bare LF, not the platform CRLF, so the bash reader sees clean rows.
  [Console]::Out.Write(('{0}{1}{2}{1}{3}' -f $Process.ProcessId, $TAB, $name, $cmd) + "`n")
}

if ($PSCmdlet.ParameterSetName -eq 'Process') {
  $process = $byPid[$ProcessId]
  if (-not $process) { exit 1 }
  Write-ProcessRow $process
  exit 0
}

$cur = $Start
for ($hop = 0; $hop -lt 16; $hop++) {
  $p = $byPid[$cur]
  if (-not $p) { break }
  Write-ProcessRow $p
  $parent = [int]$p.ParentProcessId
  if ($parent -le 0 -or $parent -eq $cur) { break }
  $parentProcess = $byPid[$parent]
  if (-not $parentProcess) { break }
  if ($p.CreationDate -and $parentProcess.CreationDate -and
      ([datetime]$parentProcess.CreationDate -gt [datetime]$p.CreationDate)) {
    break
  }
  $cur = $parent
}
