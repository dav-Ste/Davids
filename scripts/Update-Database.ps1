param([switch]$GenerateSql)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $contexts = @(
        @{ Name = 'identity'; Project = '../Davids.Services.Identity/src/Davids.Services.Identity.Infrastructure'; Startup = '../Davids.Services.Identity/src/Davids.Services.Identity.Api'; Context = 'IdentityDbContext'; Connection = 'ConnectionStrings__identitydb' },
        @{ Name = 'admin-identity'; Project = '../Davids.Services.AdminIdentity/src/Davids.Services.AdminIdentity.Infrastructure'; Startup = '../Davids.Services.AdminIdentity/src/Davids.Services.AdminIdentity.Api'; Context = 'AdminIdentityDbContext'; Connection = 'ConnectionStrings__adminidentitydb' },
        @{ Name = 'customers'; Project = '../Davids.Services.Customers/src/Davids.Services.Customers.Infrastructure'; Startup = '../Davids.Services.Customers/src/Davids.Services.Customers.Api'; Context = 'CustomersDbContext'; Connection = 'ConnectionStrings__customersdb' }
    )

    if ($GenerateSql) {
        New-Item database -ItemType Directory -Force | Out-Null
        foreach ($item in $contexts) {
            dotnet ef migrations script --idempotent --project $item.Project --startup-project $item.Startup --context $item.Context --output "database/$($item.Name).sql"
            if ($LASTEXITCODE) { throw "SQL script generation failed for $($item.Name)." }
        }
    } else {
        foreach ($item in $contexts) {
            if (-not [Environment]::GetEnvironmentVariable($item.Connection)) {
                throw "Set $($item.Connection) to the target SQL Server connection string."
            }
            dotnet ef database update --project $item.Project --startup-project $item.Startup --context $item.Context
            if ($LASTEXITCODE) { throw "Database migration failed for $($item.Name)." }
        }
    }
} finally { Pop-Location }
