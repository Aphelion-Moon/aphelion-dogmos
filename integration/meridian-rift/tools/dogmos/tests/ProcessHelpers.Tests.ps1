$ErrorActionPreference = 'Stop'

$dogmosTools = Split-Path -Parent $PSScriptRoot
. (Join-Path $dogmosTools '_common.ps1')

Describe 'Dogmos verification process helpers' {
	It 'orders DreamDaemon arguments after the DMB and port' {
		$args = Get-DogmosDreamDaemonArguments -DmbPath 'test.dmb' -Port 1337 -AdditionalArguments @('-close')
		($args -join '|') | Should Be 'test.dmb|1337|-trusted|-logself|-close'
	}

	It 'recognizes an artifact written after the invocation began' {
		$path = Join-Path $TestDrive 'fresh.txt'
		$startedAt = (Get-Date).AddSeconds(-1)
		Set-Content -LiteralPath $path -Value 'fresh'
		(Test-DogmosArtifactFresh -Path $path -StartedAt $startedAt) | Should Be $true
	}

	It 'rejects a stale artifact' {
		$path = Join-Path $TestDrive 'stale.txt'
		Set-Content -LiteralPath $path -Value 'stale'
		(Get-Item -LiteralPath $path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-5)
		(Test-DogmosArtifactFresh -Path $path -StartedAt (Get-Date).AddMinutes(-1)) | Should Be $false
	}

	It 'captures a successful process result' {
		$result = Invoke-DogmosProcess -Executable 'powershell.exe' `
			-Arguments @('-NoProfile', '-Command', 'Write-Output success') `
			-WorkingDirectory $TestDrive -TimeoutSeconds 10
		$result.Status | Should Be 'COMPLETED'
		$result.ExitCode | Should Be 0
		$result.Output | Should Match 'success'
	}

	It 'preserves a nonzero process exit' {
		$result = Invoke-DogmosProcess -Executable 'powershell.exe' `
			-Arguments @('-NoProfile', '-Command', 'exit 7') `
			-WorkingDirectory $TestDrive -TimeoutSeconds 10
		$result.Status | Should Be 'COMPLETED'
		$result.ExitCode | Should Be 7
	}

	It 'reports a missing executable without leaking registry property errors' {
		{ Resolve-DogmosToolPath -Path 'dogmos-tool-that-does-not-exist.exe' -Label 'Test tool' } |
			Should Throw 'Test tool not found: dogmos-tool-that-does-not-exist.exe'
	}

	It 'resolves the installed Dream Maker path under strict mode' {
		{ Resolve-DogmosToolPath -Path 'dm.exe' -Label 'Dream Maker' } | Should Not Throw
	}

	It 'continues registry discovery after a missing BYOND registry key' {
		$installRoot = Join-Path $TestDrive 'BYOND'
		$binRoot = Join-Path $installRoot 'bin'
		$expectedPath = Join-Path $binRoot 'dm.exe'
		New-Item -ItemType Directory -Path $binRoot | Out-Null
		Set-Content -LiteralPath $expectedPath -Value 'test executable'
		Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'dm.exe' }
		Mock Get-ItemProperty {
			if ($LiteralPath -like '*WOW6432Node*') {
				return [pscustomobject]@{ installpath = $installRoot }
			}
			return $null
		}

		(Resolve-DogmosToolPath -Path 'dm.exe' -Label 'Dream Maker') | Should Be $expectedPath
	}

	It 'terminates a timed out process owned by the invocation' {
		$result = Invoke-DogmosProcess -Executable 'powershell.exe' `
			-Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
			-WorkingDirectory $TestDrive -TimeoutSeconds 1
		$result.Status | Should Be 'TIMED_OUT'
		$result.TimedOut | Should Be $true
		(Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
	}

	It 'normalizes runtime signatures' {
		$log = '[12:34:56.789] RUNTIME: runtime error: failure at [0x123abc] coordinate 42'
		$sigs = @(Get-DogmosRuntimeSignatures -LogText $log)
		$sigs.Count | Should Be 1
		$sigs[0] | Should Be 'runtime error: failure at [ref] coordinate N'
	}

	It 'detects a missing initialization marker' {
		(Test-DogmosLogMarker -Path (Join-Path $TestDrive 'missing.log') -Marker 'ready') | Should Be $false
	}

	It 'detects an initialization marker in a shared-read log' {
		$path = Join-Path $TestDrive 'runtime.log'
		Set-Content -LiteralPath $path -Value 'Initializations complete within 1.0 seconds!'
		(Test-DogmosLogMarker -Path $path -Marker 'Initializations complete within') | Should Be $true
	}

	It 'removes only the requested scratch paths' {
		$remove = Join-Path $TestDrive 'remove.txt'
		$keep = Join-Path $TestDrive 'keep.txt'
		Set-Content -LiteralPath $remove -Value 'remove'
		Set-Content -LiteralPath $keep -Value 'keep'
		Remove-DogmosScratchPaths -Paths @($remove)
		(Test-Path -LiteralPath $remove) | Should Be $false
		(Test-Path -LiteralPath $keep) | Should Be $true
	}

	It 'waits for a transient file lock before restoring bytes' {
		$path = Join-Path $TestDrive 'locked.bin'
		$marker = Join-Path $TestDrive 'locked.ready'
		[System.IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
		$job = Start-Job -ArgumentList $path, $marker -ScriptBlock {
			param($lockedPath, $readyPath)
			$stream = [System.IO.File]::Open($lockedPath, 'Open', 'ReadWrite', 'None')
			try {
				Set-Content -LiteralPath $readyPath -Value 'ready'
				Start-Sleep -Milliseconds 500
			} finally {
				$stream.Dispose()
			}
		}
		try {
			$deadline = (Get-Date).AddSeconds(5)
			while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) {
				Start-Sleep -Milliseconds 25
			}
			(Test-Path -LiteralPath $marker) | Should Be $true
			Write-DogmosFileBytesWithRetry -Path $path -Bytes ([byte[]](4, 5, 6)) -TimeoutSeconds 5
			([System.IO.File]::ReadAllBytes($path) -join ',') | Should Be '4,5,6'
		} finally {
			Wait-Job -Job $job -Timeout 5 | Out-Null
			Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
		}
	}
}
