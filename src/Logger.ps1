<#
.SYNOPSIS
    Logging module for the KBU Deployment Validator.

.DESCRIPTION
    Provides timestamped logging to a text file and optional console output.
    Designed to never crash the main tool even if the log file is unwritable.

.NOTES
    Auto-creates the log directory on first use. Cleans up old log files
    based on the configured retention period.
#>

$Script:KBULogPath = $null
$Script:KBULogLevel = "Info"

$LogLevelPriority = @{
    "Debug"   = 0
    "Info"    = 1
    "Warning" = 2
    "Error"   = 3
}

function Initialize-KBULogger {
    <#
    .SYNOPSIS
        Initialize the logger with a log directory and log level.

    .PARAMETER LogPath
        Directory where log files will be written.

    .PARAMETER LogLevel
        Minimum log level to record. One of: Debug, Info, Warning, Error.

    .PARAMETER RetentionDays
        Number of days to keep log files. Older files are deleted.
    #>
    param(
        [string]$LogPath,
        [ValidateSet("Debug", "Info", "Warning", "Error")]
        [string]$LogLevel = "Info",
        [int]$RetentionDays = 30
    )

    try {
        if (-not $LogPath) {
            $LogPath = Join-Path (Get-Location) "logs"
        }

        if (-not (Test-Path -LiteralPath $LogPath)) {
            New-Item -ItemType Directory -Path $LogPath -Force -ErrorAction Stop | Out-Null
        }

        $Script:KBULogPath = $LogPath
        $Script:KBULogLevel = $LogLevel

        if ($RetentionDays -gt 0) {
            Get-ChildItem -LiteralPath $LogPath -Filter "KBU_Validator_*.log" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }

        Write-KBUInfo "Logger initialized. Path: $LogPath, Level: $LogLevel"
    }
    catch {
        Write-Warning "Failed to initialize logger: $($_.Exception.Message)"
    }
}

function Write-KBULog {
    <#
    .SYNOPSIS
        Internal function to write a log entry.

    .PARAMETER Level
        Log level: Info, Warning, Error, Debug.

    .PARAMETER Message
        The message text to log.
    #>
    param(
        [string]$Level,
        [string]$Message
    )

    if (-not $Script:KBULogPath) { return }

    $configuredPriority = $LogLevelPriority[$Script:KBULogLevel]
    $messagePriority    = $LogLevelPriority[$Level]

    if ($messagePriority -lt $configuredPriority) { return }

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logFile   = Join-Path $Script:KBULogPath "KBU_Validator_$(Get-Date -Format 'yyyyMMdd').log"
        $entry     = "[$timestamp] [$Level] $Message"
        Add-Content -LiteralPath $logFile -Value $entry -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Silently fail — logger must never crash the tool
    }
}

function Write-KBUInfo {
    <#
    .SYNOPSIS
        Write an informational log message.
    #>
    param([string]$Message)
    Write-KBULog -Level "Info" -Message $Message
}

function Write-KBUWarning {
    <#
    .SYNOPSIS
        Write a warning log message.
    #>
    param([string]$Message)
    Write-KBULog -Level "Warning" -Message $Message
    Write-Warning $Message
}

function Write-KBUError {
    <#
    .SYNOPSIS
        Write an error log message.
    #>
    param([string]$Message)
    Write-KBULog -Level "Error" -Message $Message
    Write-Error $Message
}

function Write-KBUDebug {
    <#
    .SYNOPSIS
        Write a debug log message (only when LogLevel is Debug).
    #>
    param([string]$Message)
    Write-KBULog -Level "Debug" -Message $Message
}
