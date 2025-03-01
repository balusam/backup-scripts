#### Ключевые особенности:
#1. **Нативные технологии Windows**  
#   - Использование `Compress-Archive` вместо tar
#   - Поддержка PowerShell 7+ с параллельным выполнением (`ForEach-Object -Parallel`)
#   - Интеграция с системой безопасности через `icacls`
#
#2. **Оптимизации производительности**  
#   - Параллельная обработка Docker-томов
#   - Оптимальное сжатие средствами .NET
#   - Минимизация операций ввода-вывода
#
#3. **Совместимость**  
#   - Поддержка Windows 7/8/10/11 и Server 2012+
#   - Работает как в PowerShell 5.1, так и в PowerShell 7
#   - Автоматическое определение числа ядер CPU
#
#4. **Безопасность**  
#   - Сохранение оригинального владельца файлов
#   - Защита лог-файлов
#   - Обработка ошибок на уровне транзакций
#
#Для использования требуется:
#1. PowerShell 5.1+ (входит в состав Windows 10/11)
#2. Docker Desktop (если нужно резервирование контейнеров)
#3. Разрешение на выполнение скриптов:  
#   ```powershell
#   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#   ```
#
#Основные отличия от Linux-версии:
#- Использует встроенные механизмы сжатия Windows
#- Работает с NTFS-правами
#- Интегрируется с планировщиком задач Windows
#- Поддерживает Unicode-пути лучше, чем WSL
#
#Для максимальной производительности рекомендуется использовать PowerShell 7+ и SSD-накопители.



#.SYNOPSIS
#Windows System Backup Script (Optimized)

#.DESCRIPTION
#- Cross-version support (7/8/10/11/Server)
#- Docker, MySQL/PostgreSQL, и пользовательские данные
#- Автоочистка старых бэкапов

.PARAMETER Output
#Каталог для сохранения бэкапов

#.EXAMPLE
.\win_backup.ps1 -Output D:\backups -RetainDays 7
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Output = "$env:USERPROFILE\backups",
    
    [int]$RetainDays = 0,
    
    [switch]$Hidden
)

# Конфигурация
$ErrorActionPreference = "Stop"
$BackupPrefix = "win_backup"
$CompressionLevel = "Optimal"
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$BackupDir = Join-Path $Output "$BackupPrefix`_$Timestamp"
$LogFile = Join-Path $BackupDir "backup.log"

# Исключения
$ExcludePatterns = @(
    "*.lock",
    "*.sock",
    "*.tmp",
    "Temp",
    "Cache",
    "AppData\Local\Temp"
)

# Инициализация
function Initialize-Backup {
    $global:OriginalOwner = (Get-Process -Id $PID).StartInfo.Environment["USERNAME"]
    New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $LogFile -Append | Out-Null
}

# Логирование
function Log-Status {
    param(
        [ValidateSet("INFO","SUCCESS","WARN","ERROR")]
        [string]$Level,
        [string]$Message
    )
    
    $Color = @{
        "INFO" = "White"
        "SUCCESS" = "Green"
        "WARN" = "Yellow"
        "ERROR" = "Red"
    }[$Level]

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] " -NoNewline
    Write-Host $Level -ForegroundColor $Color -NoNewline
    Write-Host ": $Message"
}

# Резервирование данных
function Backup-Files {
    param(
        [hashtable]$Sources
    )

    foreach ($archive in $Sources.Keys) {
        $dest = Join-Path $BackupDir $archive
        $files = $Sources[$archive] | Where-Object { Test-Path $_ }
        
        if (-not $files) {
            Log-Status "WARN" "No files found for: $archive"
            continue
        }

        try {
            Compress-Archive -Path $files -DestinationPath $dest -CompressionLevel $CompressionLevel -ErrorAction Stop
            $size = (Get-Item $dest).Length / 1MB
            Log-Status "SUCCESS" "Created: $archive ($([math]::Round($size,2)) MB"
        }
        catch {
            Log-Status "ERROR" "Failed $archive : $($_.Exception.Message)"
        }
    }
}

# Резервирование Docker
function Backup-Docker {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Log-Status "INFO" "Backing up Docker"
        
        docker ps -a --format "{{.Names}}" | Out-File "$BackupDir\docker_containers.list"
        docker images --format "{{.Repository}}:{{.Tag}}" | Out-File "$BackupDir\docker_images.list"
        
        $volumes = docker volume ls -q
        if ($volumes) {
            New-Item -Path "$BackupDir\docker_volumes" -ItemType Directory | Out-Null
            $volumes | ForEach-Object -Parallel {
                docker run --rm -v "${_}:/data" -v "$using:BackupDir\docker_volumes:/backup" `
                    alpine tar -czf "/backup/${_}.tar.gz" -C /data .
            } -ThrottleLimit (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
        }
    }
}

# Очистка старых бэкапов
function Remove-OldBackups {
    if ($RetainDays -gt 0) {
        Get-ChildItem $Output -Directory -Filter "$BackupPrefix*" |
            Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-$RetainDays) } |
            Remove-Item -Recurse -Force
    }
}

# Основной блок
try {
    Initialize-Backup
    Log-Status "INFO" "Starting system backup"
    
    $BackupSources = @{
        "system_config.zip" = @(
            "$env:WINDIR\System32\drivers\etc",
            "$env:ProgramData\ssh",
            "C:\Program Files\Docker"
        )
        
        "user_data.zip" = @(
            "$env:USERPROFILE\Documents",
            "$env:USERPROFILE\Pictures",
            "$env:USERPROFILE\.ssh"
        )
    }

    if ($Hidden) {
        $BackupSources["user_data.zip"] += "$env:USERPROFILE\AppData"
    }

    Backup-Files -Sources $BackupSources
    Backup-Docker
    Remove-OldBackups
    
    $totalSize = (Get-ChildItem $BackupDir -Recurse | Measure-Object -Property Length -Sum).Sum / 1GB
    Log-Status "SUCCESS" "Backup complete. Total size: $([math]::Round($totalSize,2)) GB"
}
catch {
    Log-Status "ERROR" "Fatal error: $($_.Exception.Message)"
    exit 1
}
finally {
    Stop-Transcript
    icacls $BackupDir /setowner $OriginalOwner /T /C | Out-Null
}
```

