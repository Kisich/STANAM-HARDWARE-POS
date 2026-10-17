param(
    [string]$HostName = "127.0.0.1",
    [int]$Port = 5432,
    [string]$Database = "stanam_pos",
    [string]$Username = "postgres"
)

$ErrorActionPreference = "Stop"
$psql = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
$schema = Join-Path $PSScriptRoot "database\schema.sql"

if (-not (Test-Path $psql)) { throw "PostgreSQL client was not found at $psql." }
if (-not (Test-Path $schema)) { throw "Database schema was not found at $schema." }
if ($Database -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Database name must contain only letters, digits, and underscores." }
if ($Username -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Database username must contain only letters, digits, and underscores." }

$securePassword = Read-Host "Enter the PostgreSQL password for $Username (used only by this setup process)" -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

    $connectionArgs = @("-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-h", $HostName, "-p", "$Port", "-U", $Username)
    $databaseExists = @("SELECT 1 FROM pg_database WHERE datname = '$Database';") | & $psql @connectionArgs -d postgres 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not connect to PostgreSQL: $($databaseExists -join "`n")" }

    if (($databaseExists -join "").Trim() -ne "1") {
        $createOutput = & $psql @connectionArgs -d postgres -c "CREATE DATABASE `"$Database`";" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not create database '$Database': $($createOutput -join "`n")" }
        Write-Output "Created isolated database '$Database'."
    } else {
        Write-Output "Using existing database '$Database'."
    }

    $schemaOutput = & $psql @connectionArgs -d $Database -f $schema 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Database schema setup failed: $($schemaOutput -join "`n")" }
    Write-Output "Database schema and sample catalogue are ready."
    Write-Output "No password was saved to the project."
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    $securePassword.Dispose()
}
