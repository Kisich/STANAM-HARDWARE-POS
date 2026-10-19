param(
    [string]$HostName = "127.0.0.1",
    [int]$Port = 5432,
    [string]$Database = "stanam_pos",
    [string]$Username = "postgres",
    [int]$WebPort = 8080
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$Psql = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
$PgDump = "C:\Program Files\PostgreSQL\18\bin\pg_dump.exe"
$PgRestore = "C:\Program Files\PostgreSQL\18\bin\pg_restore.exe"
$BackupDirectory = "D:\STANAM POS Backups"
$BackupRetentionDays = 180
$AutomaticBackupTime = [TimeSpan]::FromHours(17)
$ConnectionArgs = @("-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-h", $HostName, "-p", "$Port", "-U", $Username, "-d", $Database)
$AllowedModules = @("Home", "Settings", "Products", "Stock", "Counter", "Expenses", "Customers", "Reports", "Staff")
$Roles = @("Admin", "Manager", "Cashier", "Stock Controller", "Reports")
$script:Sessions = @{}
$script:LastAutomaticBackupDate = ""
$Root = [IO.Path]::GetFullPath($PSScriptRoot)
$RootPrefix = $Root.TrimEnd("\") + "\"
$listener = $null

if (-not (Test-Path $Psql)) { throw "PostgreSQL client was not found at $Psql." }
if (-not (Test-Path (Join-Path $Root "BIZCARE - POS SYSTEM.html"))) { throw "POS HTML file was not found in $Root." }
if ($Database -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $Username -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    throw "Database and username may contain only letters, digits, and underscores."
}

$securePassword = Read-Host "Enter the PostgreSQL password for $Username (used only by this server process)" -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

function Invoke-Database([string]$Sql) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $command = "SET client_min_messages TO warning;`n$Sql"
        $output = @($command | & $script:Psql @script:ConnectionArgs 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "PostgreSQL request failed: $($output -join "`n")"
    }
    $result = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return ($result -join "`n").Trim()
}

function ConvertTo-JsonResponse([object]$Value) {
    return ConvertTo-Json -InputObject $Value -Depth 30 -Compress
}

function Get-EncodedPayload([object]$Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 30 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function Write-AuditLog($User, [string]$Action, [string]$Entity, [hashtable]$Details = @{}) {
    $payload = Get-EncodedPayload @{
        actorId = if ($User.id) { [long]$User.id } else { $null }
        actorName = if ($User.fullName) { [string]$User.fullName } else { "System" }
        actorUsername = if ($User.username) { [string]$User.username } else { "system" }
        action = $Action
        entity = $Entity
        details = $Details
    }
    Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) INSERT INTO audit_logs(actor_id,actor_name,actor_username,action,entity,details) SELECT NULLIF(data->>'actorId','')::bigint, data->>'actorName', data->>'actorUsername', data->>'action', data->>'entity', data->'details' FROM p;"
}

function Write-BackupRecord([string]$FileName, [string]$FilePath, [string]$Kind, [string]$Status, [long]$SizeBytes, [string]$CreatedBy, [string]$ErrorMessage = "") {
    $payload = Get-EncodedPayload @{
        fileName = $FileName
        filePath = $FilePath
        kind = $Kind
        status = $Status
        sizeBytes = $SizeBytes
        createdBy = $CreatedBy
        errorMessage = $ErrorMessage
    }
    return [long](Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) INSERT INTO pos_backups(file_name,file_path,kind,status,size_bytes,created_by,error_message) SELECT data->>'fileName',data->>'filePath',data->>'kind',data->>'status',(data->>'sizeBytes')::bigint,data->>'createdBy',data->>'errorMessage' FROM p RETURNING id;")
}

function Remove-ExpiredAutomaticBackups {
    $expired = Invoke-Database "SELECT COALESCE(json_agg(json_build_object('id',id,'filePath',file_path)),'[]'::json)::text FROM pos_backups WHERE kind='automatic' AND created_at < now() - interval '$($script:BackupRetentionDays) days';" | ConvertFrom-Json
    $backupRoot = [IO.Path]::GetFullPath($script:BackupDirectory).TrimEnd("\") + "\"
    foreach ($item in $expired) {
        $filePath = [IO.Path]::GetFullPath([string]$item.filePath)
        if (-not $filePath.StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove an automatic backup outside the configured backup folder."
        }
        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            Remove-Item -LiteralPath $filePath -ErrorAction Stop
        }
        Invoke-Database "DELETE FROM pos_backups WHERE id=$([long]$item.id) AND kind='automatic';"
    }
}

function New-PosDatabaseBackup([ValidateSet("manual", "automatic")][string]$Kind, [string]$CreatedBy, $User = $null) {
    $stamp = [DateTime]::Now.ToString("yyyyMMdd-HHmmssfff", [Globalization.CultureInfo]::InvariantCulture)
    $fileName = "stanam_pos-$Kind-$stamp.dump"
    $filePath = Join-Path $script:BackupDirectory $fileName
    $arguments = @("--no-password", "--format=custom", "--file=$filePath", "--host=$script:HostName", "--port=$script:Port", "--username=$script:Username", "--dbname=$script:Database")

    try {
        if (-not (Test-Path $script:PgDump -PathType Leaf)) { throw "PostgreSQL backup tool was not found at $script:PgDump." }
        if (-not (Test-Path $script:PgRestore -PathType Leaf)) { throw "PostgreSQL restore validation tool was not found at $script:PgRestore." }
        if (-not (Test-Path -LiteralPath $script:BackupDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $script:BackupDirectory -Force -ErrorAction Stop | Out-Null
        }
        $dumpOutput = @(& $script:PgDump @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "pg_dump failed: $($dumpOutput -join "`n")" }
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf) -or (Get-Item -LiteralPath $filePath).Length -le 0) {
            throw "pg_dump completed without creating a non-empty backup file."
        }
        $validationOutput = @(& $script:PgRestore --list $filePath 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "The backup could not be validated: $($validationOutput -join "`n")" }

        $sizeBytes = (Get-Item -LiteralPath $filePath).Length
        $backupId = Write-BackupRecord $fileName $filePath $Kind "completed" $sizeBytes $CreatedBy
        if ($Kind -eq "automatic") {
            try {
                Write-AuditLog $null "Automatic database backup completed" "Database backup" @{ fileName = $fileName; sizeBytes = $sizeBytes }
            } catch {
                Write-Warning "The automatic backup completed, but its audit event could not be recorded: $($_.Exception.Message)"
            }
            try { Remove-ExpiredAutomaticBackups }
            catch { Write-Warning "The backup completed, but expired backups could not be pruned: $($_.Exception.Message)" }
        }
        return @{
            id = $backupId
            fileName = $fileName
            kind = $Kind
            status = "completed"
            sizeBytes = $sizeBytes
            createdBy = $CreatedBy
            createdAt = [DateTime]::Now.ToString("o")
        }
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage.Length -gt 1000) { $errorMessage = $errorMessage.Substring(0, 1000) }
        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            Remove-Item -LiteralPath $filePath -ErrorAction SilentlyContinue
        }
        try { $null = Write-BackupRecord $fileName $filePath $Kind "failed" 0 $CreatedBy $errorMessage }
        catch { Write-Warning "Could not record the failed database backup: $($_.Exception.Message)" }
        try {
            Write-AuditLog $User "Database backup failed" "Database backup" @{ fileName = $fileName; kind = $Kind; error = $errorMessage }
        } catch {
            Write-Warning "The failed database backup could not be written to the audit log: $($_.Exception.Message)"
        }
        throw "Database backup failed: $errorMessage"
    }
}

function Get-BackupStatus {
    $rows = Invoke-Database "SELECT COALESCE(json_agg(json_build_object('id',id,'fileName',file_name,'kind',kind,'status',status,'sizeBytes',size_bytes,'createdBy',created_by,'errorMessage',error_message,'createdAt',created_at) ORDER BY created_at DESC),'[]'::json)::text FROM (SELECT * FROM pos_backups ORDER BY created_at DESC LIMIT 100) recent;" | ConvertFrom-Json
    $lastAutomaticDate = Invoke-Database "SELECT COALESCE((SELECT value FROM pos_maintenance_state WHERE key='last_automatic_backup_date'),'');"
    return ConvertTo-JsonResponse @{
        backups = @($rows)
        backupDirectory = $script:BackupDirectory
        automaticBackupTime = "17:00"
        retentionDays = $script:BackupRetentionDays
        lastAutomaticBackupDate = $lastAutomaticDate
    }
}

function Invoke-ScheduledBackup {
    $now = [DateTime]::Now
    if ($now.TimeOfDay -lt $script:AutomaticBackupTime) { return }
    $today = $now.ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    if ($script:LastAutomaticBackupDate -eq $today) { return }

    try {
        $backup = New-PosDatabaseBackup "automatic" "System (scheduled)"
        Write-Output "Daily PostgreSQL backup created: $($backup.fileName)"
    } catch {
        Write-Warning $_.Exception.Message
    } finally {
        $payload = Get-EncodedPayload @{ date = $today }
        Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) INSERT INTO pos_maintenance_state(key,value,updated_at) SELECT 'last_automatic_backup_date',data->>'date',now() FROM p ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value,updated_at=now();"
        $script:LastAutomaticBackupDate = $today
    }
}

function Get-AuditEvent($ResponseBody) {
    $requestInfo = $script:AuditRequest
    if (-not $requestInfo) { return $null }
    $method = [string]$requestInfo.method
    $path = [string]$requestInfo.path
    $action = $null
    $entity = $path
    $details = @{}
    switch -Regex ($path) {
        '^/api/auth/login$' { $action = "Signed in"; $entity = "Staff account"; break }
        '^/api/auth/logout$' { $action = "Signed out"; $entity = "Staff account"; break }
        '^/api/auth/password$' { $action = "Changed own password"; $entity = "Staff account"; break }
        '^/api/staff$' { $action = "Added staff account"; $entity = "Staff"; break }
        '^/api/staff/([0-9]+)/(role|active|reset-password)$' {
            $action = switch ($Matches[2]) { "role" { "Changed staff role" } "active" { "Changed staff account status" } default { "Reset staff password" } }
            $entity = "Staff account"
            $details.staffId = [long]$Matches[1]
            break
        }
        '^/api/sales$' { $action = "Completed sale"; $entity = "Sale"; break }
        '^/api/customers$' { $action = "Added customer"; $entity = "Customer"; break }
        '^/api/customer-returns$' { $action = "Recorded customer return"; $entity = "Customer return"; break }
        '^/api/products$' { $action = "Added product"; $entity = "Product"; break }
        '^/api/products/([0-9]+)$' { $action = "Updated product pricing"; $entity = "Product"; $details.productId = [long]$Matches[1]; break }
        '^/api/stock/movements$' { $action = "Recorded stock movement"; $entity = "Stock"; break }
        '^/api/module$' {
            $module = [string]$requestInfo.module
            $submodule = [string]$requestInfo.submodule
            $action = "Saved module record"
            $entity = if ($submodule) { "$module / $submodule" } else { "Module record" }
            if ($module) { $details.module = $module }
            if ($submodule) { $details.submodule = $submodule }
            if ($requestInfo.workflowType) { $details.workflowType = $requestInfo.workflowType }
            break
        }
        '^/api/held-sales$' { $action = "Held sale"; $entity = "Held sale"; break }
        '^/api/held-sales/([0-9]+)$' { $action = "Deleted held sale"; $entity = "Held sale"; $details.heldSaleId = [long]$Matches[1]; break }
        '^/api/settings/backups$' { $action = "Created manual database backup"; $entity = "Database backup"; break }
    }
    if (-not $action -or $method -notin @("POST", "PATCH", "DELETE")) { return $null }

    try {
        $result = $ResponseBody | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @("id", "entryId", "receiptNumber", "username", "role", "kind", "fileName", "sizeBytes", "creditAmount")) {
            if ($result.PSObject.Properties.Name -contains $key) { $details[$key] = $result.$key }
        }
    } catch {
        # Successful mutation responses may be empty or non-JSON.
    }
    return @{ action = $action; entity = $entity; details = $details }
}

function Send-Response($Context, [int]$Status, [string]$ContentType, [string]$Body) {
    if ($Status -lt 400 -and $script:AuditUser -and $script:AuditRequest) {
        $event = Get-AuditEvent $Body
        if ($event) {
            try {
                Write-AuditLog $script:AuditUser $event.action $event.entity $event.details
            } catch {
                Write-Warning "A $($event.entity) operation completed, but its audit event could not be recorded: $($_.Exception.Message)"
                $Status = 500
                $Body = '{"error":"The operation may have been saved, but its required audit event could not be recorded. Contact an administrator before retrying."}'
            }
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Read-RequestJson($Request) {
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
    finally { $reader.Dispose() }
}

function New-PasswordHash([Security.SecureString]$Password) {
    $salt = New-Object byte[] 16
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $random.GetBytes($salt)
    $iterations = 210000
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $passwordText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($passwordText, $salt, $iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $hash = $derive.GetBytes(32)
            return "$iterations`:$([Convert]::ToBase64String($salt))`:$([Convert]::ToBase64String($hash))"
        } finally {
            $derive.Dispose()
        }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        $passwordText = $null
        $random.Dispose()
        [Array]::Clear($salt, 0, $salt.Length)
    }
}

function Test-Password([Security.SecureString]$Password, [string]$StoredHash) {
    $parts = $StoredHash.Split(":")
    if ($parts.Count -ne 3) { return $false }
    $iterations = 0
    if (-not [int]::TryParse($parts[0], [ref]$iterations) -or $iterations -lt 100000) { return $false }
    try {
        $salt = [Convert]::FromBase64String($parts[1])
        $expected = [Convert]::FromBase64String($parts[2])
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $passwordText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
            $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($passwordText, $salt, $iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
            try { $actual = $derive.GetBytes($expected.Length) }
            finally { $derive.Dispose() }
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
            $passwordText = $null
        }
        if ($actual.Length -ne $expected.Length) { return $false }
        $difference = 0
        for ($index = 0; $index -lt $actual.Length; $index++) { $difference = $difference -bor ($actual[$index] -bxor $expected[$index]) }
        [Array]::Clear($actual, 0, $actual.Length)
        [Array]::Clear($expected, 0, $expected.Length)
        [Array]::Clear($salt, 0, $salt.Length)
        return $difference -eq 0
    } catch {
        return $false
    }
}

function Get-PublicUser($User) {
    return @{
        id = [long]$User.id
        name = [string]$User.fullName
        username = [string]$User.username
        role = [string]$User.role
        mustChangePassword = [bool]$User.mustChangePassword
    }
}

function New-SessionToken {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
        return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    } finally {
        $random.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-SessionUser($Request) {
    $authorization = $Request.Headers["Authorization"]
    if ($authorization -notmatch '^Bearer ([A-Za-z0-9_-]+)$') { return $null }
    $token = $Matches[1]
    if (-not $script:Sessions.ContainsKey($token)) { return $null }
    $session = $script:Sessions[$token]
    if ($session.expiresAt -le [DateTime]::UtcNow) {
        $script:Sessions.Remove($token)
        return $null
    }
    $session.lastSeen = [DateTime]::UtcNow
    return $session
}

function Remove-UserSessions([long]$UserId) {
    foreach ($token in @($script:Sessions.Keys)) {
        if ($script:Sessions[$token].id -eq $UserId) { $script:Sessions.Remove($token) }
    }
}

function Remove-OtherUserSessions([long]$UserId, [string]$KeepToken) {
    foreach ($token in @($script:Sessions.Keys)) {
        if ($script:Sessions[$token].id -eq $UserId -and $token -ne $KeepToken) { $script:Sessions.Remove($token) }
    }
}

function Test-ModuleAccess($User, [string]$Module, [string]$Submodule) {
    if ($Module -eq "Settings" -and $User.role -eq "Admin") { return $true }
    if ($Module -eq "Settings") { return $Submodule -in @("My Password", "My Profile") }
    switch ($User.role) {
        "Admin" { return $Module -in $script:AllowedModules }
        "Manager" { return $Module -in $script:AllowedModules -and $Module -ne "Staff" }
        "Cashier" { return $Module -in @("Home", "Counter", "Customers") }
        "Stock Controller" { return $Module -in @("Home", "Products", "Stock") }
        "Reports" { return $Module -in @("Home", "Reports") }
        default { return $false }
    }
}

function Test-ApiAccess($User, [string]$Method, [string]$Path, $Request) {
    if ($Path -match '^/api/auth/') { return $true }
    if ($Path -in @("/api/settings/changelog", "/api/settings/audit-logs", "/api/settings/backups")) {
        if ($User.role -ne "Admin") { return $false }
        if ($Path -eq "/api/settings/backups") { return $Method -in @("GET", "POST") }
        return $Method -eq "GET"
    }
    if ($Path -match '^/api/staff(?:/|$)') { return $User.role -eq "Admin" }
    if ($Path -eq "/api/module") {
        $module = $Request.QueryString["module"]
        $submodule = $Request.QueryString["submodule"]
        if ($Method -eq "POST") {
            $script:ParsedRequestBody = Read-RequestJson $Request
            $module = $script:ParsedRequestBody.module
            $submodule = $script:ParsedRequestBody.submodule
        }
        if ($Method -eq "POST" -and $User.role -eq "Reports") { return $false }
        if ($Method -eq "POST" -and $module -eq "Customers" -and $submodule -in @("Set Initial Customer Balances", "Customer Credit / Debit Notes")) {
            return $User.role -in @("Admin", "Manager")
        }
        if ($Method -eq "GET" -and $User.role -eq "Cashier" -and $module -eq "Expenses") {
            return $submodule -eq "Add / Pay For Expenses"
        }
        if ($Method -eq "POST" -and $module -eq "Expenses" -and $submodule -eq "Add / Pay For Expenses") {
            if ($User.role -eq "Cashier") {
                return $script:ParsedRequestBody.record.workflow.type -eq "counter-expense"
            }
        }
        if ($Method -eq "POST" -and $module -eq "Counter" -and $submodule -eq "Post Sales & Approve" -and $script:ParsedRequestBody.record.workflow.action -eq "decision") {
            return $User.role -in @("Admin", "Manager")
        }
        return (Test-ModuleAccess $User $module $submodule)
    }
    if ($Path -eq "/api/products" -or $Path -match '^/api/products/[0-9]+$') {
        if ($Method -eq "GET") { return $User.role -ne "Reports" }
        return $Method -in @("POST", "PATCH") -and $User.role -in @("Admin", "Manager", "Stock Controller")
    }
    if ($Path -eq "/api/stock/movements") {
        return $User.role -in @("Admin", "Manager", "Stock Controller")
    }
    if ($Path -eq "/api/customers") {
        return $User.role -in @("Admin", "Manager", "Cashier")
    }
    if ($Path -eq "/api/customer-returns") {
        return $Method -eq "POST" -and $User.role -in @("Admin", "Manager", "Cashier")
    }
    if ($Path -in @("/api/sales", "/api/held-sales") -or $Path -match '^/api/held-sales/[0-9]+$') {
        if ($Method -eq "GET" -and $Path -eq "/api/sales") { return $User.role -ne "Stock Controller" }
        return $User.role -in @("Admin", "Manager", "Cashier")
    }
    return $false
}

function Initialize-InitialAdmin {
    $count = [int](Invoke-Database "SELECT count(*) FROM staff_users WHERE active;")
    if ($count -gt 0) { return }

    Write-Output "No active POS staff accounts exist. Create the first administrator account."
    do { $adminName = (Read-Host "Administrator full name").Trim() } while ([string]::IsNullOrWhiteSpace($adminName))
    do {
        $adminUsername = (Read-Host "Administrator login name (letters, digits, . _ -)").Trim().ToLowerInvariant()
        if ($adminUsername -notmatch '^[a-z0-9._-]{3,40}$') { Write-Warning "Use 3-40 letters, digits, periods, underscores, or hyphens." }
    } while ($adminUsername -notmatch '^[a-z0-9._-]{3,40}$')

    $adminPassword = $null
    while ($true) {
        $first = Read-Host "Create administrator password (at least 12 characters)" -AsSecureString
        $second = Read-Host "Confirm administrator password" -AsSecureString
        $firstPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
        $secondPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
        try {
            $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPointer)
            $confirmation = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondPointer)
            if ($plainPassword.Length -ge 12 -and $plainPassword -ceq $confirmation) {
                $adminPassword = $first.Copy()
                break
            }
            Write-Warning "Passwords must match and contain at least 12 characters."
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPointer)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPointer)
            $first.Dispose()
            $second.Dispose()
        }
    }
    try {
        $payload = Get-EncodedPayload @{ fullName = $adminName; username = $adminUsername; passwordHash = (New-PasswordHash $adminPassword); role = "Admin" }
        Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) INSERT INTO staff_users(full_name,username,password_hash,role) SELECT btrim(data->>'fullName'),lower(data->>'username'),data->>'passwordHash','Admin' FROM p;"
        Write-Output "Administrator '$adminUsername' created. Use these credentials to sign in to the POS."
    } finally {
        $plainPassword = $null
        $confirmation = $null
        if ($adminPassword) { $adminPassword.Dispose() }
    }
}

function Initialize-SuperAdmin {
    $exists = [int](Invoke-Database "SELECT count(*) FROM staff_users WHERE lower(username)='admin';")
    if ($exists -gt 0) { return }

    $password = ConvertTo-SecureString "admin2026" -AsPlainText -Force
    try { $passwordHash = New-PasswordHash $password }
    finally { $password.Dispose() }
    $payload = Get-EncodedPayload @{ passwordHash = $passwordHash }
    Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) INSERT INTO staff_users(full_name,username,password_hash,role,active,must_change_password) SELECT 'Super Administrator','admin',data->>'passwordHash','Admin',true,true FROM p ON CONFLICT (username) DO NOTHING;"
    Write-Warning "Temporary super-admin login: username 'admin'. Change its password immediately after signing in."
}

function Invoke-Api($Context) {
    $request = $Context.Request
    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod
    $script:AuditUser = $null
    $script:ParsedRequestBody = $null
    $script:AuditRequest = @{ method = $method; path = $path }

    if ($method -eq "GET" -and $path -eq "/api/health") {
        $health = Invoke-Database "SELECT json_build_object('connected', true, 'database', current_database(), 'serverVersion', current_setting('server_version'))::text;"
        Send-Response $Context 200 "application/json; charset=utf-8" $health
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/auth/login") {
        $body = Read-RequestJson $request
        $username = ([string]$body.username).Trim().ToLowerInvariant()
        $payload = Get-EncodedPayload @{ username = $username }
        $row = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) SELECT row_to_json(u)::text FROM (SELECT id,full_name AS ""fullName"",username,password_hash AS ""passwordHash"",role,active,must_change_password AS ""mustChangePassword"" FROM staff_users WHERE lower(username)=(SELECT data->>'username' FROM p)) u;"
        if (-not $row) {
            Send-Response $Context 401 "application/json; charset=utf-8" '{"error":"Login name or password is incorrect."}'
            return
        }
        $account = $row | ConvertFrom-Json
        $password = ConvertTo-SecureString ([string]$body.password) -AsPlainText -Force
        try { $validPassword = Test-Password $password $account.passwordHash }
        finally { $password.Dispose() }
        if (-not $account.active -or -not $validPassword) {
            Send-Response $Context 401 "application/json; charset=utf-8" '{"error":"Login name or password is incorrect."}'
            return
        }
        $token = New-SessionToken
        $account | Add-Member -NotePropertyName expiresAt -NotePropertyValue ([DateTime]::UtcNow.AddHours(8)) -Force
        $account | Add-Member -NotePropertyName lastSeen -NotePropertyValue ([DateTime]::UtcNow) -Force
        $script:Sessions[$token] = $account
        $script:AuditUser = $account
        Send-Response $Context 200 "application/json; charset=utf-8" (ConvertTo-JsonResponse @{ token = $token; user = (Get-PublicUser $account) })
        return
    }

    $user = Get-SessionUser $request
    if (-not $user) {
        Send-Response $Context 401 "application/json; charset=utf-8" '{"error":"Please sign in to use the POS."}'
        return
    }

    if ($user.mustChangePassword -and $path -notin @("/api/auth/me", "/api/auth/password", "/api/auth/logout")) {
        Send-Response $Context 403 "application/json; charset=utf-8" '{"error":"Change your temporary password before using the POS."}'
        return
    }

    if (-not (Test-ApiAccess $user $method $path $request)) {
        Send-Response $Context 403 "application/json; charset=utf-8" '{"error":"Your access role does not allow this action."}'
        return
    }
    $script:AuditUser = $user
    if ($path -eq "/api/module") {
        $module = if ($method -eq "POST") { [string]$script:ParsedRequestBody.module } else { [string]$request.QueryString["module"] }
        $submodule = if ($method -eq "POST") { [string]$script:ParsedRequestBody.submodule } else { [string]$request.QueryString["submodule"] }
        $workflowType = if ($method -eq "POST" -and $script:ParsedRequestBody.record.workflow.type) { [string]$script:ParsedRequestBody.record.workflow.type } else { "" }
        $script:AuditRequest.module = $module
        $script:AuditRequest.submodule = $submodule
        $script:AuditRequest.workflowType = $workflowType
    }

    if ($method -eq "GET" -and $path -eq "/api/settings/changelog") {
        $json = Invoke-Database "SELECT COALESCE(json_agg(json_build_object('id',id,'version',version,'title',title,'description',description,'releasedAt',released_at) ORDER BY released_at DESC),'[]'::json)::text FROM app_changelog;"
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/settings/audit-logs") {
        $json = Invoke-Database "SELECT COALESCE(json_agg(json_build_object('id',id,'actorName',actor_name,'actorUsername',actor_username,'action',action,'entity',entity,'details',details,'createdAt',created_at) ORDER BY created_at DESC),'[]'::json)::text FROM (SELECT * FROM audit_logs ORDER BY created_at DESC LIMIT 500) recent;"
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/settings/backups") {
        Send-Response $Context 200 "application/json; charset=utf-8" (Get-BackupStatus)
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/settings/backups") {
        $backup = New-PosDatabaseBackup "manual" $user.fullName $user
        Send-Response $Context 201 "application/json; charset=utf-8" (ConvertTo-JsonResponse $backup)
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/auth/me") {
        Send-Response $Context 200 "application/json; charset=utf-8" (ConvertTo-JsonResponse (Get-PublicUser $user))
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/auth/logout") {
        $authorization = $request.Headers["Authorization"]
        $token = $authorization.Substring("Bearer ".Length)
        $script:Sessions.Remove($token)
        Send-Response $Context 200 "application/json; charset=utf-8" '{"signedOut":true}'
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/auth/password") {
        $body = Read-RequestJson $request
        $newPassword = [string]$body.newPassword
        if ($newPassword.Length -lt 12) { throw "New passwords must contain at least 12 characters." }
        $currentPassword = ConvertTo-SecureString ([string]$body.currentPassword) -AsPlainText -Force
        try { $validPassword = Test-Password $currentPassword $user.passwordHash }
        finally { $currentPassword.Dispose() }
        if (-not $validPassword) { throw "Current password is incorrect." }
        $secureNewPassword = ConvertTo-SecureString $newPassword -AsPlainText -Force
        try { $passwordHash = New-PasswordHash $secureNewPassword }
        finally { $secureNewPassword.Dispose() }
        $payload = Get-EncodedPayload @{ passwordHash = $passwordHash; id = $user.id }
        Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) UPDATE staff_users SET password_hash=(SELECT data->>'passwordHash' FROM p),must_change_password=false,updated_at=now() WHERE id=(SELECT (data->>'id')::bigint FROM p);"
        $user.passwordHash = $passwordHash
        $user.mustChangePassword = $false
        $token = $request.Headers["Authorization"].Substring("Bearer ".Length)
        Remove-OtherUserSessions $user.id $token
        Send-Response $Context 200 "application/json; charset=utf-8" (ConvertTo-JsonResponse @{ changed = $true; user = (Get-PublicUser $user) })
        return
    }

    if ($path -eq "/api/staff" -and $method -eq "GET") {
        $json = Invoke-Database "SELECT COALESCE(json_agg(json_build_object('id',id,'name',full_name,'username',username,'role',role,'active',active,'createdAt',created_at) ORDER BY full_name),'[]'::json)::text FROM staff_users;"
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($path -eq "/api/staff" -and $method -eq "POST") {
        $body = Read-RequestJson $request
        $name = ([string]$body.name).Trim()
        $username = ([string]$body.username).Trim().ToLowerInvariant()
        $role = [string]$body.role
        $password = [string]$body.password
        if ([string]::IsNullOrWhiteSpace($name) -or $username -notmatch '^[a-z0-9._-]{3,40}$') { throw "Enter a staff name and a login name with 3-40 letters, digits, periods, underscores, or hyphens." }
        if ($role -notin $script:Roles) { throw "Select a valid staff access role." }
        if ($password.Length -lt 12) { throw "Temporary passwords must contain at least 12 characters." }
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        try { $passwordHash = New-PasswordHash $securePassword }
        finally { $securePassword.Dispose() }
        $payload = Get-EncodedPayload @{ name = $name; username = $username; role = $role; passwordHash = $passwordHash }
        $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data), saved AS (INSERT INTO staff_users(full_name,username,password_hash,role,must_change_password) SELECT btrim(data->>'name'),lower(data->>'username'),data->>'passwordHash',data->>'role',true FROM p RETURNING id,full_name,username,role,active,created_at) SELECT json_build_object('id',id,'name',full_name,'username',username,'role',role,'active',active,'createdAt',created_at)::text FROM saved;"
        Send-Response $Context 201 "application/json; charset=utf-8" $json
        return
    }

    if ($path -match '^/api/staff/([0-9]+)/(role|active|reset-password)$' -and $method -in @("PATCH", "POST")) {
        $staffId = [long]$Matches[1]
        $action = $Matches[2]
        $body = Read-RequestJson $request
        if ($action -eq "role") {
            if ($body.role -notin $script:Roles -or ($staffId -eq $user.id -and $body.role -ne "Admin")) { throw "Select a valid role; administrators cannot remove their own administrator access." }
            $targetRole = Invoke-Database "SELECT role FROM staff_users WHERE id=$staffId;"
            if ($targetRole -eq "Admin" -and $body.role -ne "Admin" -and [int](Invoke-Database "SELECT count(*) FROM staff_users WHERE active AND role='Admin';") -le 1) {
                throw "The last active administrator cannot be demoted."
            }
            $payload = Get-EncodedPayload @{ role = [string]$body.role; id = $staffId }
            $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) UPDATE staff_users SET role=(SELECT data->>'role' FROM p),updated_at=now() WHERE id=(SELECT (data->>'id')::bigint FROM p) RETURNING json_build_object('id',id,'role',role)::text;"
            Remove-UserSessions $staffId
            Send-Response $Context 200 "application/json; charset=utf-8" $json
            return
        }
        if ($action -eq "active") {
            if ($staffId -eq $user.id -and -not [bool]$body.active) { throw "You cannot deactivate your own administrator account." }
            $targetRole = Invoke-Database "SELECT role FROM staff_users WHERE id=$staffId;"
            if ($targetRole -eq "Admin" -and -not [bool]$body.active -and [int](Invoke-Database "SELECT count(*) FROM staff_users WHERE active AND role='Admin';") -le 1) {
                throw "The last active administrator cannot be disabled."
            }
            $payload = Get-EncodedPayload @{ active = [bool]$body.active; id = $staffId }
            $result = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) UPDATE staff_users SET active=(SELECT (data->>'active')::boolean FROM p),updated_at=now() WHERE id=(SELECT (data->>'id')::bigint FROM p) RETURNING active;"
            if ($result -eq "f") { Remove-UserSessions $staffId }
            Send-Response $Context 200 "application/json; charset=utf-8" '{"updated":true}'
            return
        }
        $newPassword = [string]$body.password
        if ($newPassword.Length -lt 12) { throw "Temporary passwords must contain at least 12 characters." }
        $securePassword = ConvertTo-SecureString $newPassword -AsPlainText -Force
        try { $passwordHash = New-PasswordHash $securePassword }
        finally { $securePassword.Dispose() }
        $payload = Get-EncodedPayload @{ passwordHash = $passwordHash; id = $staffId }
        $result = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) UPDATE staff_users SET password_hash=(SELECT data->>'passwordHash' FROM p),must_change_password=true,updated_at=now() WHERE id=(SELECT (data->>'id')::bigint FROM p) RETURNING id;"
        if (-not $result) { throw "Staff account not found." }
        Remove-UserSessions $staffId
        Send-Response $Context 200 "application/json; charset=utf-8" '{"reset":true}'
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/products") {
        $json = Invoke-Database "SELECT COALESCE(json_agg(json_build_object('id',id,'sku',sku,'name',name,'category',category,'price',price,'wholesalePrice',wholesale_price,'stock',stock,'unit',unit,'icon',icon,'tone',tone) ORDER BY name),'[]'::json)::text FROM products WHERE active;"
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/customers") {
        $json = Invoke-Database "SELECT COALESCE(json_agg(json_build_object('id',c.id,'name',c.name,'phone',c.phone,'accountType',c.account_type,'creditEnabled',c.credit_enabled,'active',c.active,'createdAt',c.created_at,'outstanding',COALESCE((SELECT sum(greatest(s.total-s.paid,0)) FROM sales s WHERE s.customer_id=c.id),0)+COALESCE((SELECT sum(CASE WHEN workflow->>'type'='customer-opening-balance' THEN COALESCE((workflow->>'balance')::numeric,0) WHEN workflow->>'type'='customer-account-note' AND workflow->>'noteType'='debit' THEN COALESCE((workflow->>'amount')::numeric,0) WHEN workflow->>'type'='customer-account-note' AND workflow->>'noteType'='credit' THEN -COALESCE((workflow->>'amount')::numeric,0) ELSE 0 END) FROM module_entries entry CROSS JOIN LATERAL (SELECT entry.record->'workflow' AS workflow) note WHERE entry.module_name='Customers' AND workflow->>'customerId'=c.id::text),0)) ORDER BY c.name),'[]'::json)::text FROM customers c WHERE c.active;"
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/sales") {
        $json = Invoke-Database "SELECT json_build_object('nextReceipt',COALESCE((SELECT max(receipt_number)+1 FROM sales),46449),'sales',(SELECT COALESCE(json_agg(record ORDER BY created_at DESC),'[]'::json) FROM (SELECT s.created_at,json_build_object('id',s.id,'receiptNumber',s.receipt_number,'customerId',s.customer_id,'customer',s.customer_name,'total',s.total,'paid',s.paid,'balance',greatest(s.total-s.paid,0),'status',s.status,'createdAt',s.created_at,'salesperson',s.salesperson,'storeLocation',s.store_location,'payment',COALESCE((SELECT string_agg(DISTINCT p.method,' + ' ORDER BY p.method) FROM sale_payments p WHERE p.sale_id=s.id),'Credit'),'payments',COALESCE((SELECT json_agg(json_build_object('method',p.method,'amount',p.amount) ORDER BY p.id) FROM sale_payments p WHERE p.sale_id=s.id),'[]'::json),'items',COALESCE((SELECT json_agg(json_build_object('productId',i.product_id,'name',i.product_name,'sku',i.sku,'quantity',i.quantity,'unit',i.unit,'price',i.unit_price,'total',i.line_total)) FROM sale_items i WHERE i.sale_id=s.id),'[]'::json)) AS record FROM sales s) sale_rows))::text;"
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/sales") {
        $saleBody = Read-RequestJson $request
        if (-not $saleBody.salesperson) { $saleBody | Add-Member -NotePropertyName salesperson -NotePropertyValue $user.fullName -Force }
        $payload = Get-EncodedPayload $saleBody
        $json = Invoke-Database "SELECT create_pos_sale(convert_from(decode('$payload','base64'),'UTF8')::jsonb)::text;"
        Send-Response $Context 201 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/customers") {
        $customerBody = Read-RequestJson $request
        if ([string]::IsNullOrWhiteSpace([string]$customerBody.name)) { throw "Customer name is required." }
        $encodedName = Get-EncodedPayload @{ name = [string]$customerBody.name }
        if ([int](Invoke-Database "WITH p AS (SELECT convert_from(decode('$encodedName','base64'),'UTF8')::jsonb AS data) SELECT count(*) FROM customers CROSS JOIN p WHERE lower(customers.name)=lower(btrim(p.data->>'name'));") -gt 0) {
            throw "A customer with that name already exists."
        }
        $accountType = [string]$customerBody.accountType
        if (-not $accountType) { $accountType = "Retail" }
        if ($accountType -notin @("Retail", "Credit account")) { throw "Select a valid customer account type." }
        $creditEnabled = $accountType -eq "Credit account"
        if ($creditEnabled -and $user.role -notin @("Admin", "Manager")) { throw "Only an administrator or manager may open a customer credit account." }
        $customerBody | Add-Member -NotePropertyName accountType -NotePropertyValue $accountType -Force
        $customerBody | Add-Member -NotePropertyName creditEnabled -NotePropertyValue $creditEnabled -Force
        $payload = Get-EncodedPayload $customerBody
        $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data), saved AS (INSERT INTO customers(name,phone,account_type,credit_enabled) SELECT btrim(data->>'name'),COALESCE(btrim(data->>'phone'),''),data->>'accountType',(data->>'creditEnabled')::boolean FROM p RETURNING id,name,phone,account_type,credit_enabled,active,created_at) SELECT json_build_object('id',id,'name',name,'phone',phone,'accountType',account_type,'creditEnabled',credit_enabled,'active',active,'createdAt',created_at,'outstanding',0)::text FROM saved;"
        if (-not $json) { throw "Customer name is required." }
        Send-Response $Context 201 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/customer-returns") {
        $returnBody = Read-RequestJson $request
        $returnBody | Add-Member -NotePropertyName recordedBy -NotePropertyValue $user.fullName -Force
        $payload = Get-EncodedPayload $returnBody
        $json = Invoke-Database "SELECT create_customer_return(convert_from(decode('$payload','base64'),'UTF8')::jsonb)::text;"
        Send-Response $Context 201 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/products") {
        $payload = Get-EncodedPayload (Read-RequestJson $request)
        $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data), saved AS (INSERT INTO products(sku,name,category,price,wholesale_price,stock,unit) SELECT btrim(data->>'sku'),btrim(data->>'name'),COALESCE(NULLIF(btrim(data->>'category'),''),'General'),(data->>'price')::numeric,COALESCE(NULLIF(data->>'wholesalePrice','')::numeric,0),(data->>'stock')::numeric,COALESCE(NULLIF(btrim(data->>'unit'),''),'Pcs') FROM p WHERE NULLIF(btrim(data->>'sku'),'') IS NOT NULL AND NULLIF(btrim(data->>'name'),'') IS NOT NULL RETURNING id,sku,name,category,price,wholesale_price,stock,unit,icon,tone) SELECT json_build_object('id',id,'sku',sku,'name',name,'category',category,'price',price,'wholesalePrice',wholesale_price,'stock',stock,'unit',unit,'icon',icon,'tone',tone)::text FROM saved;"
        if (-not $json) { throw "Product name, SKU, price and stock are required." }
        Send-Response $Context 201 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "PATCH" -and $path -match '^/api/products/[0-9]+$') {
        $productId = [long]($path.Substring("/api/products/".Length))
        $body = Read-RequestJson $request
        $updates = @{}
        foreach ($field in @("price", "wholesalePrice")) {
            if ($body.PSObject.Properties.Name -contains $field) {
                $amount = [decimal]0
                $valid = [decimal]::TryParse([string]$body.$field, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$amount)
                if (-not $valid -or $amount -lt 0) { throw "$field must be a valid non-negative amount." }
                $updates[$field] = $amount
            }
        }
        if ($updates.Count -eq 0) { throw "Provide a retail price or wholesale price to update." }
        $payload = Get-EncodedPayload $updates
        $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data), saved AS (UPDATE products SET price=COALESCE((SELECT (data->>'price')::numeric FROM p WHERE data ? 'price'),price),wholesale_price=COALESCE((SELECT (data->>'wholesalePrice')::numeric FROM p WHERE data ? 'wholesalePrice'),wholesale_price) WHERE id=$productId AND active RETURNING id,sku,name,category,price,wholesale_price,stock,unit,icon,tone) SELECT json_build_object('id',id,'sku',sku,'name',name,'category',category,'price',price,'wholesalePrice',wholesale_price,'stock',stock,'unit',unit,'icon',icon,'tone',tone)::text FROM saved;"
        if (-not $json) { throw "Product was not found or is no longer active." }
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/stock/movements") {
        $body = Read-RequestJson $request
        $submodule = [string]$body.submodule
        $movement = [string]$body.movement
        if ($submodule -notin @("GRN to Suppliers", "Initial Stock", "Stock Take", "Stock Adjustments", "Internal Transfers", "Consumed")) {
            throw "A valid stock workflow is required."
        }
        if ($movement -notin @("receive", "adjust", "consume", "dispatch", "transfer-receipt")) {
            throw "A valid stock movement type is required."
        }
        $productId = [long]0
        if (-not [long]::TryParse([string]$body.productId, [ref]$productId) -or $productId -le 0) {
            throw "Select a valid product."
        }
        $quantity = [decimal]0
        $quantityValid = [decimal]::TryParse([string]$body.quantity, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$quantity)
        if (-not $quantityValid -or $quantity -le 0 -or $quantity -gt 1000000000 -or [decimal]::Truncate($quantity * 1000) -ne ($quantity * 1000)) {
            throw "Quantity must be greater than zero and use no more than three decimal places."
        }
        $delta = switch ($movement) {
            { $_ -in @("receive", "transfer-receipt") } { $quantity; break }
            { $_ -in @("consume", "dispatch") } { -$quantity; break }
            "adjust" {
                if ($body.direction -notin @("add", "remove")) { throw "Choose whether the stock adjustment adds or removes stock." }
                if ($body.direction -eq "add") { $quantity } else { -$quantity }
                break
            }
        }
        if (($movement -eq "receive" -and $submodule -notin @("GRN to Suppliers", "Initial Stock")) -or
            ($movement -eq "adjust" -and $submodule -notin @("Stock Take", "Stock Adjustments")) -or
            ($movement -eq "consume" -and $submodule -ne "Consumed") -or
            ($movement -in @("dispatch", "transfer-receipt") -and $submodule -ne "Internal Transfers") -or
            ($movement -eq "transfer-receipt" -and $body.direction -ne "receive") -or
            ($movement -eq "dispatch" -and $body.direction -ne "dispatch")) {
            throw "This stock movement is not valid for the selected workflow."
        }
        if ([string]::IsNullOrWhiteSpace([string]$body.record.workflow.type)) {
            throw "Stock movement details are required for the audit trail."
        }
        $linkedSubmodule = $null
        if ($body.PSObject.Properties.Name -contains "linkedRecord") {
            $linkedSubmodule = [string]$body.linkedRecord.submodule
            if ($submodule -ne "GRN to Suppliers" -or $linkedSubmodule -ne "Supplier Orders" -or
                $body.linkedRecord.record.workflow.type -ne "order-received") {
                throw "The linked stock record is invalid."
            }
        }
        $expectedStockSql = ""
        if ($submodule -eq "Stock Take") {
            $expectedStock = [decimal]0
            $expectedValid = [decimal]::TryParse([string]$body.expectedStock, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$expectedStock)
            if (-not $expectedValid -or $expectedStock -lt 0) { throw "A valid book quantity is required to reconcile a stock count." }
            $countedStock = [decimal]0
            $countedValid = [decimal]::TryParse([string]$body.record.workflow.counted, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$countedStock)
            if (-not $countedValid -or $countedStock -lt 0 -or [Math]::Abs($countedStock - $expectedStock) -ne $quantity) {
                throw "The counted quantity and stock variance do not agree."
            }
            $expectedText = $expectedStock.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture)
            $expectedStockSql = " AND product.stock=$expectedText::numeric"
        }
        $transferReceiptGuard = ""
        if ($movement -eq "transfer-receipt") {
            $transferReceiptGuard = " AND (SELECT COALESCE(SUM(CASE WHEN e.record->'workflow'->>'action'='dispatch' THEN (e.record->'workflow'->>'quantity')::numeric WHEN e.record->'workflow'->>'action'='receive' THEN -((e.record->'workflow'->>'quantity')::numeric) ELSE 0 END),0) FROM module_entries e WHERE e.module_name='Stock' AND e.submodule_name='Internal Transfers' AND e.record->'workflow'->>'type'='stock-transfer' AND (e.record->'workflow'->>'reference')=(p.data->'record'->'workflow'->>'reference') AND (e.record->'workflow'->>'productId')=(p.data->'record'->'workflow'->>'productId') AND (e.record->'workflow'->>'fromLocation')=(p.data->'record'->'workflow'->>'fromLocation') AND (e.record->'workflow'->>'toLocation')=(p.data->'record'->'workflow'->>'toLocation')) >= $quantity::numeric"
        }
        $deltaText = $delta.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture)
        $payload = Get-EncodedPayload $body
        $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data), changed AS (UPDATE products product SET stock=product.stock+$deltaText::numeric FROM p WHERE product.id=$productId AND product.active AND product.stock+$deltaText::numeric>=0$expectedStockSql$transferReceiptGuard RETURNING product.id,product.sku,product.name,product.category,product.price,product.wholesale_price,product.stock,product.unit,product.icon,product.tone), logged AS (INSERT INTO module_entries(module_name,submodule_name,record) SELECT 'Stock',data->>'submodule',(data->'record')||jsonb_build_object('stockMovement',jsonb_build_object('movement',data->>'movement','delta',$deltaText::numeric,'productId',changed.id,'sku',changed.sku,'productName',changed.name,'stockAfter',changed.stock,'recordedBy',data->>'recordedBy')) FROM p CROSS JOIN changed RETURNING id), linked AS (INSERT INTO module_entries(module_name,submodule_name,record) SELECT 'Stock',data->'linkedRecord'->>'submodule',data->'linkedRecord'->'record' FROM p CROSS JOIN logged WHERE data ? 'linkedRecord' RETURNING id) SELECT json_build_object('id',changed.id,'sku',changed.sku,'name',changed.name,'category',changed.category,'price',changed.price,'wholesalePrice',changed.wholesale_price,'stock',changed.stock,'unit',changed.unit,'icon',changed.icon,'tone',changed.tone,'entryId',logged.id)::text FROM changed CROSS JOIN logged;"
        if (-not $json -and $movement -eq "transfer-receipt") { throw "No dispatched quantity remains for this transfer reference, product, and route." }
        if (-not $json) { throw "Stock was not changed. Check that the product is active, the quantity is available, and no other stock update changed the counted book balance." }
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/module") {
        $module = [Uri]::UnescapeDataString($request.QueryString["module"])
        $submodule = [Uri]::UnescapeDataString($request.QueryString["submodule"])
        if ($module -notin $script:AllowedModules -or [string]::IsNullOrWhiteSpace($submodule)) {
            throw "A valid module and submodule are required."
        }
        $payload = Get-EncodedPayload @{ module = $module; submodule = $submodule }
        $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data) SELECT COALESCE(json_agg(json_build_object('id',e.id,'record',e.record,'createdAt',e.created_at) ORDER BY e.created_at DESC),'[]'::json)::text FROM module_entries e CROSS JOIN p WHERE e.module_name=p.data->>'module' AND e.submodule_name=p.data->>'submodule';"
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/module") {
        $body = $script:ParsedRequestBody
        $script:ParsedRequestBody = $null
        if ($body.module -notin $script:AllowedModules -or [string]::IsNullOrWhiteSpace($body.submodule)) {
            throw "A valid module and submodule are required."
        }
        if ($body.module -eq "Expenses" -and $body.submodule -eq "Add / Pay For Expenses" -and $body.record.workflow.type -eq "counter-expense") {
            $expenseAmount = [decimal]0
            $amountValid = [decimal]::TryParse([string]$body.record.workflow.amount, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$expenseAmount)
            if (-not $amountValid -or $expenseAmount -le 0 -or [string]::IsNullOrWhiteSpace([string]$body.record.workflow.payee)) {
                throw "A counter expense requires a payee and an amount greater than zero."
            }
        }
        if ($body.module -eq "Customers") {
            $workflow = $body.record.workflow
            $customerId = [long]0
            if (-not [long]::TryParse([string]$workflow.customerId, [ref]$customerId) -or $customerId -le 0) {
                throw "Select a valid customer."
            }
            if ($body.submodule -eq "Set Initial Customer Balances" -and $workflow.type -eq "customer-opening-balance") {
                $openingAmount = [decimal]0
                $openingBalance = [decimal]0
                $amountValid = [decimal]::TryParse([string]$workflow.amount, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$openingAmount)
                $balanceValid = [decimal]::TryParse([string]$workflow.balance, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$openingBalance)
                $expectedBalance = if ($workflow.direction -eq "credit") { -$openingAmount } else { $openingAmount }
                if ($workflow.direction -notin @("due", "credit") -or
                    -not $amountValid -or -not $balanceValid -or $openingAmount -le 0 -or
                    $openingAmount -gt 1000000000 -or [decimal]::Truncate($openingAmount * 100) -ne $openingAmount * 100 -or
                    $openingBalance -ne $expectedBalance) {
                    throw "Opening balance must be a non-zero amount within the supported range."
                }
                if ([string]::IsNullOrWhiteSpace([string]$workflow.reference) -or [string]::IsNullOrWhiteSpace([string]$workflow.reason)) {
                    throw "An opening balance reference and reason are required."
                }
            } elseif ($body.submodule -eq "Customer Credit / Debit Notes" -and $workflow.type -eq "customer-account-note") {
                $noteAmount = [decimal]0
                if ($workflow.noteType -notin @("credit", "debit") -or
                    -not [decimal]::TryParse([string]$workflow.amount, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$noteAmount) -or
                    $noteAmount -le 0 -or $noteAmount -gt 1000000000 -or [decimal]::Truncate($noteAmount * 100) -ne $noteAmount * 100) {
                    throw "Choose a valid credit or debit note amount greater than zero."
                }
                if ([string]::IsNullOrWhiteSpace([string]$workflow.reference) -or [string]::IsNullOrWhiteSpace([string]$workflow.reason)) {
                    throw "A note reference and reason are required."
                }
            } elseif ($body.submodule -eq "Correct Wrong Receipt" -and $workflow.type -eq "customer-correction-request") {
                if ([string]::IsNullOrWhiteSpace([string]$workflow.reason)) { throw "A correction reason is required." }
                $receiptNumber = [long]0
                if (-not [long]::TryParse([string]$workflow.receiptNumber, [ref]$receiptNumber) -or
                    [int](Invoke-Database "SELECT count(*) FROM sales WHERE receipt_number=$receiptNumber AND customer_id=$customerId AND status='Complete';") -ne 1) {
                    throw "Select a completed receipt for this customer."
                }
            } elseif ($body.submodule -eq "Correct Wrong Receipt" -and $workflow.type -eq "customer-correction-decision") {
                if ($user.role -notin @("Admin", "Manager")) { throw "Only an administrator or manager may decide receipt correction requests." }
                $requestId = [long]0
                if ($workflow.decision -notin @("approved", "rejected") -or
                    -not [long]::TryParse([string]$workflow.requestId, [ref]$requestId) -or
                    [int](Invoke-Database "SELECT count(*) FROM module_entries WHERE id=$requestId AND module_name='Customers' AND submodule_name='Correct Wrong Receipt' AND record->'workflow'->>'type'='customer-correction-request' AND record->'workflow'->>'customerId'='$customerId';") -ne 1) {
                    throw "Select a valid pending receipt correction request."
                }
                if ([int](Invoke-Database "SELECT count(*) FROM module_entries WHERE module_name='Customers' AND submodule_name='Correct Wrong Receipt' AND record->'workflow'->>'type'='customer-correction-decision' AND record->'workflow'->>'requestId'='$requestId';") -gt 0) {
                    throw "This receipt correction request has already been reviewed."
                }
            } else {
                throw "This customer workflow is not supported."
            }
            if ([int](Invoke-Database "SELECT count(*) FROM customers WHERE id=$customerId AND active;") -ne 1) {
                throw "The selected customer is not active."
            }
            switch ($workflow.type) {
                "customer-opening-balance" { $workflow | Add-Member -NotePropertyName recordedBy -NotePropertyValue $user.fullName -Force }
                "customer-account-note" { $workflow | Add-Member -NotePropertyName recordedBy -NotePropertyValue $user.fullName -Force }
                "customer-correction-request" { $workflow | Add-Member -NotePropertyName requestedBy -NotePropertyValue $user.fullName -Force }
                "customer-correction-decision" { $workflow | Add-Member -NotePropertyName decidedBy -NotePropertyValue $user.fullName -Force }
            }
        }
        $payload = Get-EncodedPayload $body
        $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data), saved AS (INSERT INTO module_entries(module_name,submodule_name,record) SELECT data->>'module',data->>'submodule',data->'record' FROM p RETURNING id,module_name,submodule_name,record,created_at) SELECT row_to_json(saved)::text FROM saved;"
        Send-Response $Context 201 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/held-sales") {
        $json = Invoke-Database "SELECT COALESCE(json_agg(json_build_object('id',id,'receiptNumber',receipt_number,'customer',customer_name,'items',items,'payments',payments,'createdAt',created_at) ORDER BY created_at DESC),'[]'::json)::text FROM held_sales;"
        Send-Response $Context 200 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/held-sales") {
        $payload = Get-EncodedPayload (Read-RequestJson $request)
        $json = Invoke-Database "WITH p AS (SELECT convert_from(decode('$payload','base64'),'UTF8')::jsonb AS data), saved AS (INSERT INTO held_sales(receipt_number,customer_name,items,payments) SELECT (data->>'receiptNumber')::bigint,data->>'customer',data->'items',data->'payments' FROM p RETURNING id,receipt_number,customer_name,items,payments,created_at) SELECT json_build_object('id',id,'receiptNumber',receipt_number,'customer',customer_name,'items',items,'payments',payments,'createdAt',created_at)::text FROM saved;"
        Send-Response $Context 201 "application/json; charset=utf-8" $json
        return
    }

    if ($method -eq "DELETE" -and $path -match '^/api/held-sales/[0-9]+$') {
        $id = [long]($path.Substring("/api/held-sales/".Length))
        $result = Invoke-Database "DELETE FROM held_sales WHERE id=$id RETURNING id;"
        if (-not $result) { throw "Held sale was not found; refresh the register and try again." }
        Send-Response $Context 200 "application/json; charset=utf-8" '{"deleted":true}'
        return
    }

    Send-Response $Context 404 "application/json; charset=utf-8" '{"error":"API endpoint not found."}'
}

try {
    $schema = Get-Content -LiteralPath (Join-Path $Root "database\schema.sql") -Raw
    Invoke-Database $schema
    Initialize-SuperAdmin
    Initialize-InitialAdmin
    $health = Invoke-Database "SELECT json_build_object('connected', true, 'database', current_database())::text;"
    if (-not $health) { throw "Database connection returned an empty health response." }
    $script:LastAutomaticBackupDate = Invoke-Database "SELECT COALESCE((SELECT value FROM pos_maintenance_state WHERE key='last_automatic_backup_date'),'');"

    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$WebPort/")
    $listener.Start()
    Write-Output "STANAM POS is ready at http://127.0.0.1:$WebPort/"
    Write-Output "Connected to PostgreSQL database '$Database'. Daily backups run at 17:00 local time while this server is running. Press Ctrl+C to stop."

    $pendingContext = $listener.BeginGetContext($null, $null)
    while ($listener.IsListening) {
        if (-not $pendingContext.AsyncWaitHandle.WaitOne(15000)) {
            try { Invoke-ScheduledBackup }
            catch { Write-Warning "The scheduled backup check failed: $($_.Exception.Message)" }
            continue
        }
        $context = $listener.EndGetContext($pendingContext)
        $pendingContext = $listener.BeginGetContext($null, $null)
        try {
            $path = $context.Request.Url.AbsolutePath
            if ($path.StartsWith("/api/")) {
                Invoke-Api $context
                continue
            }

            $relative = [Uri]::UnescapeDataString($path.TrimStart("/").Replace("/", "\"))
            if ([string]::IsNullOrWhiteSpace($relative)) { $relative = "BIZCARE - POS SYSTEM.html" }
            $filePath = [IO.Path]::GetFullPath((Join-Path $Root $relative))
            if (-not ($filePath.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase) -or $filePath -eq (Join-Path $Root "BIZCARE - POS SYSTEM.html")) -or -not (Test-Path $filePath -PathType Leaf)) {
                Send-Response $context 404 "text/plain; charset=utf-8" "Not found."
                continue
            }
            $extension = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
            $contentType = switch ($extension) {
                ".html" { "text/html; charset=utf-8" }
                ".css" { "text/css; charset=utf-8" }
                ".js" { "application/javascript; charset=utf-8" }
                ".jpg" { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                ".png" { "image/png" }
                default { "application/octet-stream" }
            }
            $bytes = [IO.File]::ReadAllBytes($filePath)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = $contentType
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.Close()
        } catch {
            $errorText = $_.Exception.Message
            if ($context.Request.Url.AbsolutePath.StartsWith("/api/")) {
                Write-Warning $errorText
                try {
                    Send-Response $context 400 "application/json; charset=utf-8" (ConvertTo-JsonResponse @{ error = $errorText })
                } catch {
                    Write-Warning "Could not return the API error response: $($_.Exception.Message)"
                }
            } else {
                try {
                    Send-Response $context 500 "text/plain; charset=utf-8" "Local POS server error."
                } catch {
                    Write-Warning "Could not return the local server error response: $($_.Exception.Message)"
                }
            }
        } finally {
            try { Invoke-ScheduledBackup }
            catch { Write-Warning "The scheduled backup check failed: $($_.Exception.Message)" }
        }
    }
} finally {
    if ($listener) { $listener.Stop(); $listener.Close() }
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    $securePassword.Dispose()
}
