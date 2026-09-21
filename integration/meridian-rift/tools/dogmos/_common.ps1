Set-StrictMode -Version 2.0

function Read-DogmosFileShared {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][string]$Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return ''
	}
	try {
		$stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
		try {
			$reader = New-Object System.IO.StreamReader($stream)
			try {
				return $reader.ReadToEnd()
			} finally {
				$reader.Dispose()
			}
		} finally {
			$stream.Dispose()
		}
	} catch {
		return ''
	}
}

function Resolve-DogmosToolPath {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Label
	)

	if (Test-Path -LiteralPath $Path -PathType Leaf) {
		return (Resolve-Path -LiteralPath $Path).Path
	}
	$command = Get-Command $Path -CommandType Application -ErrorAction SilentlyContinue
	if ($command) {
		return $command.Source
	}
	if (@('dm.exe', 'dreamdaemon.exe', 'dreamseeker.exe') -contains $Path.ToLowerInvariant()) {
		foreach ($registryPath in @(
			'HKLM:\SOFTWARE\Dantom\BYOND',
			'HKLM:\SOFTWARE\WOW6432Node\Dantom\BYOND',
			'HKCU:\SOFTWARE\Dantom\BYOND'
		)) {
			$registryEntry = Get-ItemProperty -LiteralPath $registryPath -Name installpath -ErrorAction SilentlyContinue
			if (-not $registryEntry -or -not $registryEntry.PSObject.Properties['installpath']) {
				continue
			}
			$installPath = $registryEntry.installpath
			if (-not $installPath) {
				continue
			}
			$candidate = Join-Path (Join-Path $installPath 'bin') $Path
			if (Test-Path -LiteralPath $candidate -PathType Leaf) {
				return (Resolve-Path -LiteralPath $candidate).Path
			}
		}
	}
	throw "$Label not found: $Path"
}

function ConvertTo-DogmosCommandLineArgument {
	[CmdletBinding()]
	param([AllowEmptyString()][string]$Value)

	if ($Value -notmatch '[\s"]') {
		return $Value
	}
	$builder = New-Object System.Text.StringBuilder
	[void]$builder.Append('"')
	$backslashes = 0
	foreach ($character in $Value.ToCharArray()) {
		if ($character -eq '\') {
			$backslashes++
			continue
		}
		if ($character -eq '"') {
			[void]$builder.Append(('\' * ($backslashes * 2 + 1)))
			[void]$builder.Append('"')
			$backslashes = 0
			continue
		}
		if ($backslashes -gt 0) {
			[void]$builder.Append(('\' * $backslashes))
			$backslashes = 0
		}
		[void]$builder.Append($character)
	}
	if ($backslashes -gt 0) {
		[void]$builder.Append(('\' * ($backslashes * 2)))
	}
	[void]$builder.Append('"')
	return $builder.ToString()
}

function Get-DogmosProcessTreeIds {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][int]$ProcessId)

	$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
	$ordered = New-Object System.Collections.Generic.List[int]
	function Add-Children([int]$ParentId) {
		foreach ($child in @($processes | Where-Object { $_.ParentProcessId -eq $ParentId })) {
			Add-Children -ParentId ([int]$child.ProcessId)
			$ordered.Add([int]$child.ProcessId)
		}
	}
	Add-Children -ParentId $ProcessId
	$ordered.Add($ProcessId)
	return @($ordered)
}

function Stop-DogmosOwnedProcessTree {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][int]$ProcessId)

	foreach ($ownedId in @(Get-DogmosProcessTreeIds -ProcessId $ProcessId)) {
		Stop-Process -Id $ownedId -Force -ErrorAction SilentlyContinue
	}
}

function Start-DogmosProcess {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Executable,
		[string[]]$Arguments = @(),
		[Parameter(Mandatory = $true)][string]$WorkingDirectory
	)

	$resolvedExecutable = Resolve-DogmosToolPath -Path $Executable -Label 'Executable'
	$resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
	$startInfo = New-Object System.Diagnostics.ProcessStartInfo
	$startInfo.FileName = $resolvedExecutable
	$startInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-DogmosCommandLineArgument -Value ([string]$_) }) -join ' ')
	$startInfo.WorkingDirectory = $resolvedWorkingDirectory
	$startInfo.UseShellExecute = $false
	$startInfo.CreateNoWindow = $true
	$startInfo.RedirectStandardOutput = $true
	$startInfo.RedirectStandardError = $true
	$process = New-Object System.Diagnostics.Process
	$process.StartInfo = $startInfo
	$startedAt = Get-Date
	if (-not $process.Start()) {
		throw "Failed to start $resolvedExecutable"
	}
	return [pscustomobject]@{
		Process = $process
		ProcessId = $process.Id
		Executable = $resolvedExecutable
		Arguments = @($Arguments)
		WorkingDirectory = $resolvedWorkingDirectory
		StartedAt = $startedAt
		StdoutTask = $process.StandardOutput.ReadToEndAsync()
		StderrTask = $process.StandardError.ReadToEndAsync()
	}
}

function Stop-DogmosProcess {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]$Handle,
		[switch]$Force
	)

	if (-not $Handle.Process.HasExited -and $Force) {
		Stop-DogmosOwnedProcessTree -ProcessId $Handle.ProcessId
	}
	if (-not $Handle.Process.HasExited) {
		$Handle.Process.WaitForExit(5000) | Out-Null
	}
	$exitCode = if ($Handle.Process.HasExited) { $Handle.Process.ExitCode } else { $null }
	$output = $Handle.StdoutTask.Result
	$errorOutput = $Handle.StderrTask.Result
	$Handle.Process.Dispose()
	return [pscustomobject]@{
		ProcessId = $Handle.ProcessId
		ExitCode = $exitCode
		Output = @($output, $errorOutput) -join "`n"
		Stdout = $output
		Stderr = $errorOutput
		ElapsedSeconds = ((Get-Date) - $Handle.StartedAt).TotalSeconds
	}
}

function Invoke-DogmosProcess {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Executable,
		[string[]]$Arguments = @(),
		[Parameter(Mandatory = $true)][string]$WorkingDirectory,
		[ValidateRange(1, 86400)][int]$TimeoutSeconds = 300
	)

	$handle = Start-DogmosProcess -Executable $Executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory
	$completed = $handle.Process.WaitForExit($TimeoutSeconds * 1000)
	if (-not $completed) {
		Stop-DogmosOwnedProcessTree -ProcessId $handle.ProcessId
		$handle.Process.WaitForExit(5000) | Out-Null
	}
	$result = Stop-DogmosProcess -Handle $handle
	return [pscustomobject]@{
		Status = if ($completed) { 'COMPLETED' } else { 'TIMED_OUT' }
		TimedOut = -not $completed
		ProcessId = $result.ProcessId
		ExitCode = $result.ExitCode
		Output = $result.Output
		Stdout = $result.Stdout
		Stderr = $result.Stderr
		ElapsedSeconds = $result.ElapsedSeconds
	}
}

function Test-DogmosArtifactFresh {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][datetime]$StartedAt
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return $false
	}
	return (Get-Item -LiteralPath $Path).LastWriteTimeUtc -ge $StartedAt.ToUniversalTime().AddSeconds(-1)
}

function Get-DogmosDreamDaemonArguments {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$DmbPath,
		[ValidateRange(1, 65535)][int]$Port = 1337,
		[string[]]$AdditionalArguments = @()
	)

	return @($DmbPath, [string]$Port, '-trusted', '-logself') + @($AdditionalArguments)
}

function Get-DogmosRuntimeSignatures {
	[CmdletBinding()]
	param([AllowEmptyString()][string]$LogText)

	if (-not $LogText) {
		return @()
	}
	$signatures = @()
	foreach ($line in ($LogText -split "`r?`n")) {
		if ($line -notmatch 'runtime error:') {
			continue
		}
		$message = $line -replace '^.*?(runtime error:)', '$1'
		$message = $message -replace '\[0x[0-9a-fA-F]+\]', '[ref]'
		$message = $message -replace '\d+', 'N'
		$signatures += $message.Trim()
	}
	return @($signatures)
}

function Test-DogmosLogMarker {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Marker
	)

	return (Read-DogmosFileShared -Path $Path).Contains($Marker)
}

function Write-DogmosFileBytesWithRetry {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][byte[]]$Bytes,
		[ValidateRange(1, 60)][int]$TimeoutSeconds = 10
	)

	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
	do {
		try {
			[System.IO.File]::WriteAllBytes($Path, $Bytes)
			return
		} catch [System.IO.IOException] {
			if ((Get-Date) -ge $deadline) {
				throw
			}
			Start-Sleep -Milliseconds 100
		}
	} while ($true)
}

function Remove-DogmosScratchPaths {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][string[]]$Paths)

	foreach ($path in $Paths) {
		if (-not $path) {
			throw 'Scratch path cannot be empty.'
		}
		Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
	}
}
