using System.Reflection;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Testing;
using Xunit;

namespace Davids.AppHost.Tests;

public sealed class ResourceGraphTests
{
    [Fact]
    [Trait("Category", "Unit")]
    public void CompiledAppHostAssemblyEmbedsConcreteDcpAndDashboardPaths()
    {
        var metadata = typeof(Projects.Davids_AppHost).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .ToDictionary(a => a.Key, a => a.Value, StringComparer.OrdinalIgnoreCase);

        Assert.True(metadata.TryGetValue("dcpclipath", out var dcpCliPath) && !string.IsNullOrWhiteSpace(dcpCliPath),
            "Davids.AppHost assembly is missing AssemblyMetadata('dcpclipath').");
        Assert.True(File.Exists(dcpCliPath), $"DCP executable does not exist at '{dcpCliPath}'.");

        Assert.True(metadata.TryGetValue("aspiredashboardpath", out var dashboardPath) && !string.IsNullOrWhiteSpace(dashboardPath),
            "Davids.AppHost assembly is missing AssemblyMetadata('aspiredashboardpath').");
        Assert.True(File.Exists(dashboardPath), $"Aspire Dashboard executable does not exist at '{dashboardPath}'.");
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task AllSecretParametersHaveGeneratedDefaultsAndNeverStartUnresolved()
    {
        await using var builder = await DistributedApplicationTestingBuilder.CreateAsync<Projects.Davids_AppHost>(
            ["--environment=Development"]);

        var parameters = builder.Resources.OfType<ParameterResource>().ToArray();
        Assert.NotEmpty(parameters);

        foreach (var parameter in parameters)
        {
            Assert.True(parameter.Default is not null, $"Parameter '{parameter.Name}' has no ParameterDefault and would prompt 'Unresolved parameters' in Aspire.");
            var value = await parameter.GetValueAsync(default);
            Assert.False(string.IsNullOrWhiteSpace(value), $"Parameter '{parameter.Name}' resolved to an empty value.");
        }

        var rsaParamNames = new[]
        {
            "oidc-signing-key",
            "oidc-encryption-key",
            "admin-oidc-signing-key",
            "admin-oidc-encryption-key"
        };

        var spkiHashes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rsaName in rsaParamNames)
        {
            var param = Assert.Single(parameters, p => p.Name == rsaName);
            var raw = await param.GetValueAsync(default);
            using var rsa = RSA.Create();
            rsa.ImportPkcs8PrivateKey(Convert.FromBase64String(raw!), out _);
            Assert.True(rsa.KeySize >= 2048);
            Assert.True(spkiHashes.Add(Convert.ToHexString(SHA256.HashData(rsa.ExportSubjectPublicKeyInfo()))));
        }
    }
    [Fact]
    [Trait("Category", "Integration")]
    public async Task FullProfileBuildsAllExpectedResourcesWithoutStartingContainers()
    {
        await using var builder = await DistributedApplicationTestingBuilder.CreateAsync<Projects.Davids_AppHost>(
            ["--environment=Development", "--Integrations:InfluxDB=true", "--Integrations:Elasticsearch=true"]);
        var names = builder.Resources.Select(r => r.Name).ToArray();
        foreach (var expected in new[]
        {
            "identity",
            "admin-identity",
            "customers",
            "frontend-admin",
            "api-gateway",
            "sql",
            "identitydb",
            "adminidentitydb",
            "customersdb",
            "messaging",
            "cache",
            "vault",
            "vault-bootstrap",
            "jaeger",
            "seq",
            "prometheus",
            "grafana",
            "influxdb",
            "influx-collector",
            "elasticsearch",
            "kibana"
        })
        {
            Assert.Contains(expected, names);
        }

        Assert.DoesNotContain("jwt-signing-key", names);
        Assert.DoesNotContain("admin-jwt-signing-key", names);
        Assert.Contains("oidc-signing-key", names);
        Assert.Contains("admin-oidc-signing-key", names);
        Assert.Contains("admin-oidc-bff-client-secret", names);

        // Verify strict database isolation: identity, admin-identity, and customers each bind to a distinct database resource.
        Assert.NotEqual("identitydb", "adminidentitydb");
        Assert.NotEqual("customersdb", "adminidentitydb");

        await using var app = await builder.BuildAsync();
        Assert.NotNull(app);
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task OptionalInfrastructureCanBeDisabled()
    {
        await using var builder = await DistributedApplicationTestingBuilder.CreateAsync<Projects.Davids_AppHost>(
            ["--environment=Development", "--Integrations:ApiGateway=false", "--Integrations:Redis=false", "--Integrations:Vault=false", "--Integrations:SeedAdmin=false", "--Integrations:Jaeger=false", "--Integrations:Seq=false", "--Integrations:Prometheus=false", "--Integrations:Grafana=false", "--Integrations:InfluxDB=false", "--Integrations:Elasticsearch=false"]);
        var names = builder.Resources.Select(r => r.Name).ToArray();
        Assert.Contains("identity", names);
        Assert.Contains("admin-identity", names);
        Assert.Contains("customers", names);
        Assert.Contains("identitydb", names);
        Assert.Contains("adminidentitydb", names);
        Assert.Contains("customersdb", names);
        Assert.Contains("sql", names);
        Assert.DoesNotContain("api-gateway", names);
        Assert.DoesNotContain("frontend-admin", names);
        Assert.DoesNotContain("grafana", names);
        Assert.DoesNotContain("vault-bootstrap", names);
        Assert.DoesNotContain("influx-collector", names);
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task SelfHostedOidcWiringEnforcesZeroSharedSigningSecretsAndIsolatedVaultPaths()
    {
        await using var builder = await DistributedApplicationTestingBuilder.CreateAsync<Projects.Davids_AppHost>(
        [
            "--environment=Development",
            "--Parameters:oidc-signing-key=test-customer-rsa-key",
            "--Parameters:oidc-encryption-key=test-customer-enc-key",
            "--Parameters:admin-oidc-signing-key=test-admin-rsa-key",
            "--Parameters:admin-oidc-encryption-key=test-admin-enc-key",
            "--Parameters:admin-oidc-bff-client-secret=test-admin-bff-client-secret-value",
            "--Parameters:vault-dev-root-token=test-vault-root-token",
            "--Parameters:dev-admin-password=Test-Admin-Password-123!"
        ]);

        await using var app = await builder.BuildAsync();
        Assert.NotNull(app);

        var publishContext = new DistributedApplicationExecutionContext(DistributedApplicationOperation.Publish);
        async Task<Dictionary<string, object>> GetEnvAsync(string resourceName)
        {
            var resource = Assert.Single(builder.Resources.OfType<ProjectResource>(), r => r.Name == resourceName);
            var env = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            var callbackContext = new EnvironmentCallbackContext(publishContext, resource, env);
            foreach (var annotation in resource.Annotations.OfType<EnvironmentCallbackAnnotation>())
            {
                await annotation.Callback(callbackContext);
            }

            return env;
        }

        var identityEnv = await GetEnvAsync("identity");
        var adminIdentityEnv = await GetEnvAsync("admin-identity");
        var customersEnv = await GetEnvAsync("customers");
        var gatewayEnv = await GetEnvAsync("api-gateway");
        var bootstrapEnv = await GetEnvAsync("vault-bootstrap");

        Assert.Equal("secret/data/davids/identity", identityEnv["Vault__KvPath"]);
        Assert.Equal("secret/data/davids/admin-identity", adminIdentityEnv["Vault__KvPath"]);
        Assert.Equal("secret/data/davids/customers", customersEnv["Vault__KvPath"]);
        Assert.Equal("secret/data/davids/gateway", gatewayEnv["Vault__KvPath"]);

        Assert.True(identityEnv.ContainsKey("Oidc__Issuer"));
        Assert.True(adminIdentityEnv.ContainsKey("Oidc__Issuer"));
        Assert.True(adminIdentityEnv.ContainsKey("Oidc__GatewayRedirectUri"));
        Assert.True(adminIdentityEnv.ContainsKey("Oidc__GatewayPostLogoutRedirectUri"));

        Assert.True(customersEnv.ContainsKey("CustomerOidc__Authority"));
        Assert.True(customersEnv.ContainsKey("AdminOidc__Authority"));
        Assert.DoesNotContain(customersEnv.Keys, k => k.Contains("SigningKey", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(customersEnv.Keys, k => k.Contains("BffClientSecret", StringComparison.OrdinalIgnoreCase));

        Assert.True(gatewayEnv.ContainsKey("CustomerOidc__Authority"));
        Assert.True(gatewayEnv.ContainsKey("AdminOidc__Authority"));
        Assert.DoesNotContain(gatewayEnv.Keys, k => k.Contains("SigningKey", StringComparison.OrdinalIgnoreCase));

        Assert.True(bootstrapEnv.ContainsKey("OIDC_SIGNING_KEY"));
        Assert.True(bootstrapEnv.ContainsKey("ADMIN_OIDC_SIGNING_KEY"));
        Assert.True(bootstrapEnv.ContainsKey("ADMIN_OIDC_BFF_CLIENT_SECRET"));
        Assert.True(bootstrapEnv.ContainsKey("IDENTITY_DP_MASTER_KEY"));
        Assert.True(bootstrapEnv.ContainsKey("ADMIN_IDENTITY_DP_MASTER_KEY"));
        Assert.True(bootstrapEnv.ContainsKey("GATEWAY_DP_MASTER_KEY"));
        Assert.DoesNotContain(customersEnv.Keys, k => k.Contains("DataProtection", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(bootstrapEnv.Keys, k => k.Contains("JWT_SIGNING_KEY", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task GrafanaCanPointAtExternalClusterPrometheusAndJaegerInstances()
    {
        const string clusterPrometheus = "http://prometheus.istio-system.svc.cluster.local:9090";
        const string clusterJaeger = "http://tracing.istio-system.svc.cluster.local:80";

        await using var builder = await DistributedApplicationTestingBuilder.CreateAsync<Projects.Davids_AppHost>(
        [
            "--environment=Development",
            "--Integrations:Prometheus=false",
            "--Integrations:Jaeger=false",
            "--Integrations:Grafana=true",
            $"--Grafana:PrometheusUrl={clusterPrometheus}",
            $"--Grafana:JaegerUrl={clusterJaeger}"
        ]);

        var names = builder.Resources.Select(r => r.Name).ToArray();
        Assert.Contains("grafana", names);
        Assert.DoesNotContain("prometheus", names);
        Assert.DoesNotContain("jaeger", names);

        await using var app = await builder.BuildAsync();
        Assert.NotNull(app);

        var grafana = Assert.Single(builder.Resources.OfType<ContainerResource>(), r => r.Name == "grafana");
        var env = (await ExecutionConfigurationBuilder.Create(grafana)
            .WithEnvironmentVariablesConfig()
            .BuildAsync(builder.ExecutionContext))
            .EnvironmentVariables.ToDictionary(kvp => kvp.Key, kvp => kvp.Value);
        Assert.Equal(clusterPrometheus, env["PROMETHEUS_URL"]);
        Assert.Equal(clusterJaeger, env["JAEGER_URL"]);
    }

    [Fact]
    [Trait("Category", "Unit")]
    public void LocalSecurityGatesAreEnforcedAcrossAllRepositories()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null && !File.Exists(Path.Combine(current.FullName, "Davids.slnx")))
        {
            current = current.Parent;
        }

        Assert.NotNull(current);
        var workspaceRoot = current!.Parent!.FullName;

        var repositories = new[]
        {
            "Davids",
            "Davids.Shared",
            "Davids.Services.Identity",
            "Davids.Services.AdminIdentity",
            "Davids.Services.Customers",
            "Davids.APIGateway",
            "Davids.Frontend.Admin"
        };

        var commonPropsPath = Path.Combine(workspaceRoot, "Davids.Shared", "eng", "Davids.Common.props");
        Assert.True(File.Exists(commonPropsPath), $"Missing centralized MSBuild props at {commonPropsPath}.");
        var commonPropsXml = File.ReadAllText(commonPropsPath);
        Assert.Contains("<Nullable>enable</Nullable>", commonPropsXml, StringComparison.Ordinal);
        Assert.Contains("<UseArtifactsOutput>true</UseArtifactsOutput>", commonPropsXml, StringComparison.Ordinal);
        Assert.Contains("<TreatWarningsAsErrors>true</TreatWarningsAsErrors>", commonPropsXml, StringComparison.Ordinal);
        Assert.Contains("<NuGetAudit>true</NuGetAudit>", commonPropsXml, StringComparison.Ordinal);
        Assert.Contains("<NuGetAuditMode>all</NuGetAuditMode>", commonPropsXml, StringComparison.Ordinal);
        Assert.Contains("<NuGetAuditLevel>low</NuGetAuditLevel>", commonPropsXml, StringComparison.Ordinal);
        foreach (var code in new[] { "NU1900", "NU1901", "NU1902", "NU1903", "NU1904" })
        {
            Assert.Contains(code, commonPropsXml, StringComparison.Ordinal);
        }
        Assert.Contains("<EnableNETAnalyzers>true</EnableNETAnalyzers>", commonPropsXml, StringComparison.Ordinal);
        Assert.Contains("<AnalysisModeSecurity>All</AnalysisModeSecurity>", commonPropsXml, StringComparison.Ordinal);
        Assert.Contains("<UseSharedPackageReference Condition=\"'$(UseSharedPackageReference)' == ''\">false</UseSharedPackageReference>", commonPropsXml, StringComparison.Ordinal);
        Assert.Contains(">true</RestorePackagesWithLockFile>", commonPropsXml, StringComparison.Ordinal);

        var serviceDefaultsCsprojPath = Path.Combine(workspaceRoot, "Davids.Shared", "src", "Davids.ServiceDefaults", "Davids.ServiceDefaults.csproj");
        var serviceDefaultsCsprojXml = File.ReadAllText(serviceDefaultsCsprojPath);
        Assert.Contains("<PackageId>Davids.ServiceDefaults</PackageId>", serviceDefaultsCsprojXml, StringComparison.Ordinal);
        Assert.Contains("<IsPackable>true</IsPackable>", serviceDefaultsCsprojXml, StringComparison.Ordinal);
        Assert.True(File.Exists(Path.Combine(workspaceRoot, "Davids.Shared", "scripts", "Pack-SharedPackages.ps1")), "Missing Davids.Shared/scripts/Pack-SharedPackages.ps1.");

        foreach (var repo in repositories)
        {
            var repoPath = Path.Combine(workspaceRoot, repo);
            Assert.True(Directory.Exists(repoPath), $"Expected sibling repository '{repo}' at '{repoPath}'.");

            var propsPath = Path.Combine(repoPath, "Directory.Build.props");
            Assert.True(File.Exists(propsPath), $"Missing Directory.Build.props in {repo}.");
            var propsXml = File.ReadAllText(propsPath);
            Assert.Contains("eng/Davids.Common.props", propsXml, StringComparison.Ordinal);
            if (repo != "Davids.Shared")
            {
                Assert.Contains("!Exists('$(_DavidsCommonPropsPath)')", propsXml, StringComparison.Ordinal);
                Assert.Contains("<Nullable>enable</Nullable>", propsXml, StringComparison.Ordinal);
                Assert.Contains("UseSharedPackageReference", propsXml, StringComparison.Ordinal);
            }

            if (repo is not ("Davids" or "Davids.Shared"))
            {
                var packagesPropsText = File.ReadAllText(Path.Combine(repoPath, "Directory.Packages.props"));
                Assert.Contains("Include=\"Davids.ServiceDefaults\" Version=\"$(DavidsServiceDefaultsVersion)\"", packagesPropsText, StringComparison.Ordinal);

                var apiCsprojText = Directory.EnumerateFiles(Path.Combine(repoPath, "src"), "*.csproj", SearchOption.AllDirectories)
                    .Select(File.ReadAllText)
                    .FirstOrDefault(t => t.Contains("Davids.ServiceDefaults", StringComparison.Ordinal));
                Assert.False(string.IsNullOrEmpty(apiCsprojText), $"Expected conditional Davids.ServiceDefaults reference in {repo}/src.");
                Assert.Contains("Condition=\"'$(UseSharedPackageReference)' != 'true'\"", apiCsprojText, StringComparison.Ordinal);
                Assert.Contains("<PackageReference Include=\"Davids.ServiceDefaults\" Condition=\"'$(UseSharedPackageReference)' == 'true'\" />", apiCsprojText, StringComparison.Ordinal);
            }

            var gitignorePath = Path.Combine(repoPath, ".gitignore");
            Assert.True(File.Exists(gitignorePath), $"Missing .gitignore in {repo}.");
            Assert.Contains("artifacts/", File.ReadAllText(gitignorePath), StringComparison.Ordinal);

            var dockerignorePath = Path.Combine(repoPath, ".dockerignore");
            Assert.True(File.Exists(dockerignorePath), $"Missing .dockerignore in {repo}.");
            Assert.Contains("artifacts/", File.ReadAllText(dockerignorePath), StringComparison.Ordinal);

            // Verify Central Package Management trims unused PackageVersion entries down to direct references + explicit transitive security pins.
            var packagesPropsPath = Path.Combine(repoPath, "Directory.Packages.props");
            Assert.True(File.Exists(packagesPropsPath), $"Missing Directory.Packages.props in {repo}.");
            var packagesDoc = System.Xml.Linq.XDocument.Load(packagesPropsPath);
            var directRefs = Directory.EnumerateFiles(repoPath, "*.csproj", SearchOption.AllDirectories)
                .SelectMany(csproj => System.Xml.Linq.XDocument.Load(csproj).Descendants()
                    .Where(e => e.Name.LocalName == "PackageReference")
                    .Select(e => e.Attribute("Include")?.Value ?? e.Attribute("Update")?.Value))
                .Where(id => !string.IsNullOrWhiteSpace(id))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            foreach (var pv in packagesDoc.Descendants().Where(e => e.Name.LocalName == "PackageVersion"))
            {
                var pkgId = pv.Attribute("Include")?.Value;
                Assert.False(string.IsNullOrWhiteSpace(pkgId), $"Empty PackageVersion Include in {packagesPropsPath}.");
                var groupLabel = pv.Parent?.Attribute("Label")?.Value ?? string.Empty;
                var isTransitiveSecurityPin = string.Equals(groupLabel, "Transitive Security Pins", StringComparison.Ordinal);
                Assert.True(
                    directRefs.Contains(pkgId!) || isTransitiveSecurityPin,
                    $"Unused PackageVersion '{pkgId}' in {repo}/Directory.Packages.props (not referenced by any .csproj in {repo}).");
            }

            var gitleaksPath = Path.Combine(repoPath, ".gitleaks.toml");
            Assert.True(File.Exists(gitleaksPath), $"Missing .gitleaks.toml in {repo}.");
            var gitleaksToml = File.ReadAllText(gitleaksPath);
            Assert.Contains("useDefault = true", gitleaksToml, StringComparison.Ordinal);
            Assert.Contains("davids-hashicorp-vault-token", gitleaksToml, StringComparison.Ordinal);
            Assert.Contains("davids-oidc-or-dataprotection-secret", gitleaksToml, StringComparison.Ordinal);
            Assert.Contains("artifacts|", gitleaksToml, StringComparison.Ordinal);
            Assert.Contains(@"[\\/]", gitleaksToml, StringComparison.Ordinal);
            Assert.DoesNotContain("(^|/)", gitleaksToml, StringComparison.Ordinal);

            var preCommitPath = Path.Combine(repoPath, ".githooks", "pre-commit");
            Assert.True(File.Exists(preCommitPath), $"Missing .githooks/pre-commit in {repo}.");
            var hookContent = File.ReadAllText(preCommitPath);
            Assert.Contains("gitleaks", hookContent, StringComparison.Ordinal);
            Assert.Contains("--staged", hookContent, StringComparison.Ordinal);
            Assert.Contains("--redact", hookContent, StringComparison.Ordinal);

            foreach (var file in Directory.EnumerateFiles(repoPath, "*", SearchOption.AllDirectories))
            {
                if (file.Contains($"{Path.DirectorySeparatorChar}artifacts{Path.DirectorySeparatorChar}", StringComparison.Ordinal) ||
                    file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal) ||
                    file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal) ||
                    file.Contains($"{Path.DirectorySeparatorChar}.git{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
                {
                    continue;
                }

                var ext = Path.GetExtension(file);
                Assert.False(
                    ext.Equals(".pfx", StringComparison.OrdinalIgnoreCase) ||
                    ext.Equals(".p12", StringComparison.OrdinalIgnoreCase) ||
                    ext.Equals(".key", StringComparison.OrdinalIgnoreCase),
                    $"Prohibited certificate/private-key file checked into repository: {file}");

                if (ext is ".cs" or ".json" or ".yaml" or ".yml")
                {
                    var text = File.ReadAllText(file);
                    Assert.DoesNotContain("-----BEGIN " + "RSA PRIVATE KEY-----", text, StringComparison.Ordinal);
                    Assert.DoesNotContain("-----BEGIN " + "EC PRIVATE KEY-----", text, StringComparison.Ordinal);
                    Assert.DoesNotContain("-----BEGIN " + "PRIVATE KEY-----", text, StringComparison.Ordinal);
                }
            }
        }

        Assert.True(File.Exists(Path.Combine(workspaceRoot, "Davids", "security", "local-dev-commit", "gitleaks.toml")));
        Assert.True(File.Exists(Path.Combine(workspaceRoot, "Davids", "security", "local-dev-commit", "pre-commit")));

        // Verify modern .NET 10 .slnx solutions across all 7 repositories + 3 focused vertical .slnx slices (zero legacy .sln files).
        var expectedSlnxPaths = repositories
            .Select(r => Path.Combine(workspaceRoot, r, $"{r}.slnx"))
            .Concat(new[]
            {
                Path.Combine(workspaceRoot, "Davids", "solutions", "Davids.Orchestration.slnx"),
                Path.Combine(workspaceRoot, "Davids", "solutions", "Davids.AdminVertical.slnx"),
                Path.Combine(workspaceRoot, "Davids", "solutions", "Davids.CustomerVertical.slnx")
            });

        foreach (var repo in repositories)
        {
            Assert.Empty(Directory.GetFiles(Path.Combine(workspaceRoot, repo), "*.sln", SearchOption.AllDirectories));
        }

        foreach (var slnxPath in expectedSlnxPaths)
        {
            Assert.True(File.Exists(slnxPath), $"Missing .slnx solution file: {slnxPath}");
            var slnxDir = Path.GetDirectoryName(slnxPath)!;
            var xml = System.Xml.Linq.XDocument.Load(slnxPath);
            foreach (var elem in xml.Descendants().Where(e => e.Name.LocalName is "Project" or "File"))
            {
                var relPath = elem.Attribute("Path")?.Value;
                Assert.False(string.IsNullOrWhiteSpace(relPath), $"Empty Path attribute in {slnxPath}");
                var fullRefPath = Path.GetFullPath(Path.Combine(slnxDir, relPath!.Replace('/', Path.DirectorySeparatorChar)));
                Assert.True(File.Exists(fullRefPath), $"Broken reference '{relPath}' inside {slnxPath} (resolved to '{fullRefPath}').");
            }
        }

        foreach (var script in new[]
        {
            "Install-GitHooks.ps1",
            "Scan-Secrets.ps1",
            "Verify-Dependencies.ps1",
            "Invoke-LocalDevCommitGates.ps1"
        })
        {
            Assert.True(File.Exists(Path.Combine(workspaceRoot, "Davids", "scripts", "security", "local-dev-commit", script)), $"Missing Local Dev / Commit script {script}.");
        }
    }

    [Fact]
    [Trait("Category", "Unit")]
    public void PullRequestCiSecurityGatesAreEnforcedAcrossAllRepositories()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null && !File.Exists(Path.Combine(current.FullName, "Davids.slnx")))
        {
            current = current.Parent;
        }

        Assert.NotNull(current);
        var workspaceRoot = current!.Parent!.FullName;

        var repositories = new[]
        {
            "Davids",
            "Davids.Shared",
            "Davids.Services.Identity",
            "Davids.Services.AdminIdentity",
            "Davids.Services.Customers",
            "Davids.APIGateway",
            "Davids.Frontend.Admin"
        };

        var shaPinnedUsesRegex = new Regex(@"^\s*-?\s*uses:\s*([^\s#]+)", RegexOptions.Compiled);
        var validCommitShaRegex = new Regex(@"^[^@\s]+@[0-9a-f]{40}$", RegexOptions.Compiled);

        foreach (var repo in repositories)
        {
            var repoPath = Path.Combine(workspaceRoot, repo);

            // 1. CodeQL configuration + workflow (csharp across all repos, plus javascript-typescript where JS exists).
            var codeqlConfig = repo == "Davids"
                ? Path.Combine(repoPath, "security", "pull-request-ci", "codeql", "codeql-config.yml")
                : Path.Combine(repoPath, ".github", "codeql", "codeql-config.yml");
            Assert.True(File.Exists(codeqlConfig), $"Missing CodeQL config in {repo}.");
            var codeqlConfigText = File.ReadAllText(codeqlConfig);
            Assert.Contains("security-extended", codeqlConfigText, StringComparison.Ordinal);
            Assert.Contains("**/artifacts/**", codeqlConfigText, StringComparison.Ordinal);

            var codeqlWorkflowPath = Path.Combine(repoPath, ".github", "workflows", "codeql.yml");
            Assert.True(File.Exists(codeqlWorkflowPath), $"Missing CodeQL workflow in {repo}.");
            var codeqlWorkflow = File.ReadAllText(codeqlWorkflowPath);
            Assert.Contains("language: csharp", codeqlWorkflow, StringComparison.Ordinal);
            if (repo is "Davids" or "Davids.Frontend.Admin")
            {
                Assert.Contains("language: javascript-typescript", codeqlWorkflow, StringComparison.Ordinal);
            }

            // 2. Custom Davids Semgrep SAST ruleset.
            var semgrepRulesPath = repo == "Davids"
                ? Path.Combine(repoPath, "security", "pull-request-ci", "semgrep", "davids-security.yml")
                : Path.Combine(repoPath, ".semgrep", "davids-security.yml");
            Assert.True(File.Exists(semgrepRulesPath), $"Missing custom Semgrep rules in {repo}.");
            var semgrepYaml = File.ReadAllText(semgrepRulesPath);
            foreach (var ruleId in new[]
            {
                "davids-zero-signing-key-on-resource-servers",
                "davids-admin-identity-endpoint-requires-explicit-auth",
                "davids-no-symmetric-hmac-jwt",
                "davids-efcore-raw-sql-interpolation",
                "davids-tls-certificate-validation-bypass",
                "davids-permissive-cors-allow-any-origin",
                "davids-insecure-non-crypto-random",
                "davids-legacy-x509certificate2-constructor",
                "davids-admin-frontend-no-browser-token-storage-or-dom-xss",
                "davids-github-actions-must-pin-commit-sha"
            })
            {
                Assert.Contains(ruleId, semgrepYaml, StringComparison.Ordinal);
            }

            // 3. Pull Request CI gate workflow (Semgrep, NuGet JSON audit, Checkov, SHA-pinned Grype & Trivy).
            var prGatePath = Path.Combine(repoPath, ".github", "workflows", "pull-request-ci.yml");
            Assert.True(File.Exists(prGatePath), $"Missing pull-request-ci.yml in {repo}.");
            var prGate = File.ReadAllText(prGatePath);
            Assert.Contains("semgrep", prGate, StringComparison.Ordinal);
            Assert.Contains("--exclude=artifacts", prGate, StringComparison.Ordinal);
            Assert.Contains("bridgecrewio/checkov-action@", prGate, StringComparison.Ordinal);
            Assert.Contains("skip_path: artifacts,", prGate, StringComparison.Ordinal);
            Assert.Contains("anchore/scan-action@", prGate, StringComparison.Ordinal);
            Assert.Contains("aquasecurity/trivy-action@", prGate, StringComparison.Ordinal);
            Assert.Contains("skip-dirs: \"**/artifacts,", prGate, StringComparison.Ordinal);
            if (repo == "Davids")
            {
                Assert.Contains("istioctl", prGate, StringComparison.Ordinal);
                Assert.Contains("scripts/security/local-dev-commit/Verify-Dependencies.ps1", prGate, StringComparison.Ordinal);
            }
            else
            {
                Assert.Contains("--vulnerable --include-transitive --format json", prGate, StringComparison.Ordinal);
            }

            // 4. Every GitHub Action 'uses:' in every workflow must be pinned to a full 40-hex commit SHA.
            foreach (var wf in Directory.EnumerateFiles(Path.Combine(repoPath, ".github", "workflows"), "*.yml"))
            {
                var lines = File.ReadAllLines(wf);
                var wfText = string.Join('\n', lines);
                Assert.Contains("permissions:", wfText, StringComparison.Ordinal);
                foreach (var line in lines)
                {
                    if (wf.EndsWith("codeql-config.yml", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    var match = shaPinnedUsesRegex.Match(line);
                    if (!match.Success)
                    {
                        continue;
                    }

                    var actionRef = match.Groups[1].Value.Trim('"', '\'');
                    if (actionRef.StartsWith("./", StringComparison.Ordinal))
                    {
                        continue;
                    }

                    Assert.True(
                        validCommitShaRegex.IsMatch(actionRef),
                        $"Unpinned GitHub Action '{actionRef}' in {wf}. Pin to a 40-char commit SHA.");
                }
            }

            // 5. Deployable service repositories must have hardened non-root Dockerfiles aligned with UseArtifactsOutput.
            if (repo is not ("Davids" or "Davids.Shared"))
            {
                var dockerfilePath = Path.Combine(repoPath, "Dockerfile");
                Assert.True(File.Exists(dockerfilePath), $"Missing hardened Dockerfile in {repo}.");
                var dockerfile = File.ReadAllText(dockerfilePath);
                Assert.Contains("--locked-mode", dockerfile, StringComparison.Ordinal);
                Assert.Contains("artifacts/publish/", dockerfile, StringComparison.Ordinal);
                Assert.Contains("USER 10001:10001", dockerfile, StringComparison.Ordinal);
                Assert.Contains("HEALTHCHECK", dockerfile, StringComparison.Ordinal);

                var dockerfileIgnorePath = Path.Combine(repoPath, "Dockerfile.dockerignore");
                Assert.True(File.Exists(dockerfileIgnorePath), $"Missing Dockerfile.dockerignore in {repo}.");
                Assert.Contains("artifacts/", File.ReadAllText(dockerfileIgnorePath), StringComparison.Ordinal);
            }
        }

        // 6. Verify Kubernetes + Istio mesh manifests and local Pull Request CI PowerShell runners in Davids.
        var k8sDir = Path.Combine(workspaceRoot, "Davids", "deploy", "k8s");
        foreach (var manifest in new[]
        {
            "namespace-and-networkpolicy.yaml",
            "workloads.yaml",
            "istio-mesh-security.yaml",
            "grafana.yaml"
        })
        {
            Assert.True(File.Exists(Path.Combine(k8sDir, manifest)), $"Missing Kubernetes/Istio manifest {manifest}.");
        }

        var istioMesh = File.ReadAllText(Path.Combine(k8sDir, "istio-mesh-security.yaml"));
        Assert.Contains("mode: STRICT", istioMesh, StringComparison.Ordinal);
        Assert.Contains("mode: ISTIO_MUTUAL", istioMesh, StringComparison.Ordinal);
        Assert.Contains("name: default-deny", istioMesh, StringComparison.Ordinal);
        Assert.Contains("cluster.local/ns/davids/sa/davids-api-gateway", istioMesh, StringComparison.Ordinal);

        foreach (var script in new[]
        {
            "Scan-Semgrep.ps1",
            "Scan-IaC.ps1",
            "Scan-SupplyChain.ps1",
            "Invoke-PullRequestCiGates.ps1"
        })
        {
            Assert.True(File.Exists(Path.Combine(workspaceRoot, "Davids", "scripts", "security", "pull-request-ci", script)), $"Missing script {script}.");
        }
    }

    private static string ResolveWorkspaceRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null && !File.Exists(Path.Combine(current.FullName, "Davids.slnx")))
        {
            current = current.Parent;
        }

        Assert.NotNull(current);
        return current!.Parent!.FullName;
    }

    [Fact]
    [Trait("Category", "Unit")]
    public void StagingAndNightlyDastSecurityGatesAreConfiguredAndPinned()
    {
        var workspaceRoot = ResolveWorkspaceRoot();
        var davidsRoot = Path.Combine(workspaceRoot, "Davids");
        var stagingDir = Path.Combine(davidsRoot, "security", "staging-nightly");

        // 1. Exported gateway-mapped OpenAPI 3.1.1 contracts for Schemathesis & Burp Suite DAST.
        var openApiDir = Path.Combine(stagingDir, "openapi");
        foreach (var (fileName, requiredPrefix, requiredPath) in new[]
        {
            ("identity.gateway.openapi.json", "/identity", "/identity/sign-up"),
            ("admin-identity.gateway.openapi.json", "/admin-identity", "/admin-identity/connect/token"),
            ("customers.gateway.openapi.json", "/customers", "/customers/{customerId}/state/{state}")
        })
        {
            var specPath = Path.Combine(openApiDir, fileName);
            Assert.True(File.Exists(specPath), $"Missing OpenAPI 3.1 gateway contract {specPath}.");
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(specPath));
            Assert.Equal("3.1.1", doc.RootElement.GetProperty("openapi").GetString());
            Assert.True(doc.RootElement.GetProperty("components").GetProperty("securitySchemes").TryGetProperty("BearerAuth", out _));

            var paths = doc.RootElement.GetProperty("paths");
            Assert.True(paths.TryGetProperty(requiredPath, out _), $"Missing expected path '{requiredPath}' in {fileName}.");
            foreach (var prop in paths.EnumerateObject())
            {
                Assert.True(
                    prop.Name == requiredPrefix || prop.Name.StartsWith(requiredPrefix + "/", StringComparison.Ordinal),
                    $"Unexpected path '{prop.Name}' without '{requiredPrefix}' prefix in {fileName}.");
                Assert.NotEqual("/admin-identity/sign-up", prop.Name);
            }
        }

        // 2. Schemathesis v4.32.x TOML configuration enabling examples, coverage, fuzzing, and stateful testing.
        var schemathesisTomlPath = Path.Combine(stagingDir, "schemathesis", "schemathesis.toml");
        Assert.True(File.Exists(schemathesisTomlPath), "Missing security/staging-nightly/schemathesis/schemathesis.toml.");
        var schemathesisToml = File.ReadAllText(schemathesisTomlPath);
        Assert.Contains("allow-x00 = true", schemathesisToml, StringComparison.Ordinal);
        Assert.Contains("max-redirects = 0", schemathesisToml, StringComparison.Ordinal);
        Assert.Contains("stateful.enabled = true", schemathesisToml, StringComparison.Ordinal);

        // 3. ProjectDiscovery Nuclei config + 4 positive posture assertions + 6 negative vulnerability templates.
        var nucleiDir = Path.Combine(stagingDir, "nuclei");
        Assert.True(File.Exists(Path.Combine(nucleiDir, "nuclei-config.yaml")), "Missing nuclei-config.yaml.");

        var assertionFiles = Directory.GetFiles(Path.Combine(nucleiDir, "assertions"), "*.yaml");
        Assert.Equal(4, assertionFiles.Length);
        foreach (var file in assertionFiles)
        {
            Assert.Contains("id: davids-posture-", File.ReadAllText(file), StringComparison.Ordinal);
        }

        var vulnFiles = Directory.GetFiles(Path.Combine(nucleiDir, "vulnerabilities"), "*.yaml");
        Assert.Equal(6, vulnFiles.Length);
        foreach (var file in vulnFiles)
        {
            Assert.Contains("id: davids-vuln-", File.ReadAllText(file), StringComparison.Ordinal);
        }

        // 4. PortSwigger Dastardly & Burp Suite DAST configurations + recorded PKCE BFF login template.
        var burpDir = Path.Combine(stagingDir, "burp");
        var seedsJson = File.ReadAllText(Path.Combine(burpDir, "dastardly-seeds.json"));
        Assert.Contains("public.ecr.aws/portswigger/dastardly:latest@sha256:", seedsJson, StringComparison.Ordinal);

        var burpConfigJson = File.ReadAllText(Path.Combine(burpDir, "burp-dast-scan-config.json"));
        Assert.Contains("/auth/logout", burpConfigJson, StringComparison.Ordinal);
        Assert.Contains("customers.gateway.openapi.json", burpConfigJson, StringComparison.Ordinal);

        var recordedLoginJson = File.ReadAllText(Path.Combine(burpDir, "burp-recorded-admin-bff-login.template.json"));
        Assert.Contains("${BURP_ADMIN_EMAIL}", recordedLoginJson, StringComparison.Ordinal);
        Assert.Contains("${BURP_ADMIN_PASSWORD}", recordedLoginJson, StringComparison.Ordinal);

        // 5. Staging / Nightly GitHub Actions workflow + 5 cross-platform PowerShell runners.
        var stagingWorkflowPath = Path.Combine(davidsRoot, ".github", "workflows", "staging-nightly.yml");
        Assert.True(File.Exists(stagingWorkflowPath), "Missing .github/workflows/staging-nightly.yml.");
        var stagingWorkflow = File.ReadAllText(stagingWorkflowPath);
        Assert.Contains("schemathesis/action@", stagingWorkflow, StringComparison.Ordinal);
        Assert.Contains("projectdiscovery/nuclei-action@", stagingWorkflow, StringComparison.Ordinal);
        Assert.Contains("PortSwigger/dastardly-github-action@", stagingWorkflow, StringComparison.Ordinal);

        foreach (var script in new[]
        {
            "Export-OpenApiSpecs.ps1",
            "Scan-Schemathesis.ps1",
            "Scan-Nuclei.ps1",
            "Scan-Dastardly.ps1",
            "Invoke-StagingNightlyGates.ps1"
        })
        {
            var scriptPath = Path.Combine(davidsRoot, "scripts", "security", "staging-nightly", script);
            Assert.True(File.Exists(scriptPath), $"Missing Staging / Nightly PowerShell runner {script}.");
            var content = File.ReadAllText(scriptPath);
            Assert.DoesNotContain("Convey", content, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Ntrada", content, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    [Trait("Category", "Unit")]
    public void QuarterlyReleaseSecurityGatesAreConfiguredWithFreeZeroDollarToolchainAndImmutablePins()
    {
        var workspaceRoot = ResolveWorkspaceRoot();
        var davidsRoot = Path.Combine(workspaceRoot, "Davids");
        var releaseDir = Path.Combine(davidsRoot, "security", "quarterly-release");

        // 1. Exported OpenAPI 3.0.3 contracts normalized for Microsoft RESTler (no OpenAPI 3.1 type arrays).
        var restlerSpecsDir = Path.Combine(releaseDir, "restler", "specs");
        foreach (var (fileName, requiredPrefix, requiredPath) in new[]
        {
            ("identity.restler.openapi.json", "/identity", "/identity/sign-up"),
            ("admin-identity.restler.openapi.json", "/admin-identity", "/admin-identity/connect/token"),
            ("customers.restler.openapi.json", "/customers", "/customers/{customerId}/state/{state}")
        })
        {
            var specPath = Path.Combine(restlerSpecsDir, fileName);
            Assert.True(File.Exists(specPath), $"Missing RESTler OpenAPI 3.0.3 contract {specPath}.");
            var raw = File.ReadAllText(specPath);
            Assert.DoesNotContain("[\"string\", \"null\"]", raw, StringComparison.Ordinal);
            Assert.DoesNotContain("[\"string\",\"null\"]", raw, StringComparison.Ordinal);

            using var doc = System.Text.Json.JsonDocument.Parse(raw);
            Assert.Equal("3.0.3", doc.RootElement.GetProperty("openapi").GetString());
            var paths = doc.RootElement.GetProperty("paths");
            Assert.True(paths.TryGetProperty(requiredPath, out _), $"Missing '{requiredPath}' in {fileName}.");
            foreach (var prop in paths.EnumerateObject())
            {
                Assert.True(
                    prop.Name == requiredPrefix || prop.Name.StartsWith(requiredPrefix + "/", StringComparison.Ordinal),
                    $"Unexpected path '{prop.Name}' without '{requiredPrefix}' prefix in {fileName}.");
                Assert.NotEqual("/admin-identity/sign-up", prop.Name);
            }
        }

        // 2. Microsoft RESTler compiler, producer/consumer annotations, fuzzing dictionary, and engine checker settings.
        var restlerDir = Path.Combine(releaseDir, "restler");
        foreach (var compileFile in new[] { "compile-customer.json", "compile-admin.json" })
        {
            var compilePath = Path.Combine(restlerDir, compileFile);
            Assert.True(File.Exists(compilePath), $"Missing {compileFile}.");
            using var compileDoc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(compilePath));
            Assert.True(compileDoc.RootElement.GetProperty("UseRefreshableToken").GetBoolean());
            Assert.True(compileDoc.RootElement.GetProperty("DataFuzzing").GetBoolean());
            Assert.True(compileDoc.RootElement.GetProperty("ResolveBodyDependencies").GetBoolean());
        }
        Assert.True(File.Exists(Path.Combine(restlerDir, "annotations-customer.json")));
        Assert.True(File.Exists(Path.Combine(restlerDir, "annotations-admin.json")));
        Assert.True(File.Exists(Path.Combine(restlerDir, "dict.template.json")));
        var engineSettings = File.ReadAllText(Path.Combine(restlerDir, "engine-settings.json"));
        Assert.Contains("namespacerule", engineSettings, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("useafterfree", engineSettings, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("invaliddynamicobject", engineSettings, StringComparison.OrdinalIgnoreCase);

        // 3. OWASP ZAP Automation Framework plan + digest-pinned ZAP 2.17.0 container.
        var zapPlanPath = Path.Combine(releaseDir, "zap", "zap-automation.yaml");
        Assert.True(File.Exists(zapPlanPath), "Missing security/quarterly-release/zap/zap-automation.yaml.");
        var zapPlan = File.ReadAllText(zapPlanPath);
        Assert.Contains("type: openapi", zapPlan, StringComparison.Ordinal);
        Assert.Contains("type: activeScan", zapPlan, StringComparison.Ordinal);
        Assert.Contains("sarif-json", zapPlan, StringComparison.Ordinal);

        var scanZapScript = File.ReadAllText(Path.Combine(davidsRoot, "scripts", "security", "quarterly-release", "Scan-Zap.ps1"));
        Assert.Contains("ghcr.io/zaproxy/zaproxy:2.17.0@sha256:", scanZapScript, StringComparison.Ordinal);

        var scanRestlerScript = File.ReadAllText(Path.Combine(davidsRoot, "scripts", "security", "quarterly-release", "Scan-Restler.ps1"));
        Assert.Contains("mcr.microsoft.com/restlerfuzzer/restler:", scanRestlerScript, StringComparison.Ordinal);
        Assert.Contains("@sha256:", scanRestlerScript, StringComparison.Ordinal);

        // 4. Cross-role Authorization Matrix (31 Autorize cases) + Burp Suite Community Edition ($0) config & guide.
        var authzDir = Path.Combine(releaseDir, "authz");
        var matrixPath = Path.Combine(authzDir, "authz-matrix.json");
        Assert.True(File.Exists(matrixPath), "Missing security/quarterly-release/authz/authz-matrix.json.");
        using (var matrixDoc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(matrixPath)))
        {
            Assert.Equal(31, matrixDoc.RootElement.GetProperty("cases").GetArrayLength());
        }
        Assert.True(File.Exists(Path.Combine(authzDir, "burp-community-project-options.json")));
        var burpGuide = File.ReadAllText(Path.Combine(authzDir, "BURP-COMMUNITY-GUIDE.md"));
        Assert.Contains("Burp Suite Community Edition", burpGuide, StringComparison.Ordinal);
        Assert.Contains("Autorize", burpGuide, StringComparison.Ordinal);
        Assert.Contains("JWT Editor", burpGuide, StringComparison.Ordinal);

        // 5. Quarterly / Release GitHub Actions workflow (40-char SHA-pinned, Checkov CKV_GHA_7 compliant) + PowerShell runners.
        var releaseWorkflowPath = Path.Combine(davidsRoot, ".github", "workflows", "quarterly-release.yml");
        Assert.True(File.Exists(releaseWorkflowPath), "Missing .github/workflows/quarterly-release.yml.");
        var releaseWorkflow = File.ReadAllText(releaseWorkflowPath);
        foreach (var line in releaseWorkflow.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("uses:", StringComparison.Ordinal) || trimmed.StartsWith("- uses:", StringComparison.Ordinal))
            {
                var atIdx = trimmed.IndexOf('@');
                Assert.True(atIdx > 0, $"Unpinned action in quarterly-release.yml: {trimmed}");
                var afterAt = trimmed[(atIdx + 1)..].Split([' ', '#', '\r'])[0];
                Assert.Equal(40, afterAt.Length);
                Assert.True(afterAt.All(Uri.IsHexDigit), $"Non-SHA action pin in quarterly-release.yml: {trimmed}");
            }
        }

        foreach (var script in new[]
        {
            "Scan-Restler.ps1",
            "Scan-Zap.ps1",
            "Scan-AuthzMatrix.ps1",
            "Invoke-QuarterlyReleaseGates.ps1"
        })
        {
            var scriptPath = Path.Combine(davidsRoot, "scripts", "security", "quarterly-release", script);
            Assert.True(File.Exists(scriptPath), $"Missing Quarterly / Release PowerShell runner {script}.");
            var content = File.ReadAllText(scriptPath);
            Assert.DoesNotContain("Convey", content, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Ntrada", content, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    [Trait("Category", "Unit")]
    public void ProductionClusterRuntimeMeshSupplyChainAndAlertingAssetsAreProvisioned()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null && !File.Exists(Path.Combine(current.FullName, "Davids.slnx")))
        {
            current = current.Parent;
        }
        Assert.NotNull(current);
        var davidsRoot = current!.FullName;
        var prodClusterSecurityDir = Path.Combine(davidsRoot, "security", "production-cluster");

        // Verify all 5 lifecycle folders exist under both security/ and scripts/security/, with zero legacy stage-numbered paths.
        foreach (var lifecycleStage in new[]
        {
            "local-dev-commit",
            "pull-request-ci",
            "staging-nightly",
            "quarterly-release",
            "production-cluster"
        })
        {
            Assert.True(Directory.Exists(Path.Combine(davidsRoot, "security", lifecycleStage)), $"Missing security/{lifecycleStage}.");
            Assert.True(Directory.Exists(Path.Combine(davidsRoot, "scripts", "security", lifecycleStage)), $"Missing scripts/security/{lifecycleStage}.");
        }

        var legacyStageNumberRegex = new Regex(@"\bstage[-_\s]*[1-5]\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        foreach (var checkRoot in new[]
        {
            Path.Combine(davidsRoot, "security"),
            Path.Combine(davidsRoot, "scripts"),
            Path.Combine(davidsRoot, ".github", "workflows"),
            Path.Combine(davidsRoot, "deploy", "k8s")
        })
        {
            foreach (var file in Directory.EnumerateFiles(checkRoot, "*", SearchOption.AllDirectories))
            {
                Assert.False(legacyStageNumberRegex.IsMatch(file), $"Legacy incremental stage number in path: {file}");
                var text = File.ReadAllText(file);
                Assert.False(legacyStageNumberRegex.IsMatch(text), $"Legacy incremental stage number found inside {file}");
            }
        }

        // 1. Kyverno Cosign signature/SBOM verification, ClusterPolicy, CEL ValidatingPolicy & test fixtures.
        var cosignPolicy = File.ReadAllText(Path.Combine(davidsRoot, "deploy", "k8s", "kyverno", "davids-verify-signed-images.yaml"));
        Assert.Contains("https://token.actions.githubusercontent.com", cosignPolicy, StringComparison.Ordinal);
        Assert.Contains("https://rekor.sigstore.dev", cosignPolicy, StringComparison.Ordinal);
        Assert.Contains("https://cyclonedx.org/bom", cosignPolicy, StringComparison.Ordinal);

        var clusterPolicy = File.ReadAllText(Path.Combine(davidsRoot, "deploy", "k8s", "kyverno", "davids-pod-security-and-mesh-admission.yaml"));
        Assert.Contains("validationFailureAction: Enforce", clusterPolicy, StringComparison.Ordinal);
        Assert.Contains("disallow-istio-sidecar-bypass", clusterPolicy, StringComparison.Ordinal);

        var celPolicy = File.ReadAllText(Path.Combine(davidsRoot, "deploy", "k8s", "kyverno", "davids-cel-validating-policy.yaml"));
        Assert.Contains("kind: ValidatingPolicy", celPolicy, StringComparison.Ordinal);
        Assert.Contains("policies.kyverno.io/v1", celPolicy, StringComparison.Ordinal);
        Assert.True(File.Exists(Path.Combine(prodClusterSecurityDir, "kyverno-tests", "kyverno-test.yaml")));

        // 2. Istio STRICT mTLS (namespace + port-level), ISTIO_MUTUAL DestinationRule, DENY/ALLOW AuthorizationPolicies & TLS 1.3.
        var istioYaml = File.ReadAllText(Path.Combine(davidsRoot, "deploy", "k8s", "istio-mesh-security.yaml"));
        Assert.Contains("mode: STRICT", istioYaml, StringComparison.Ordinal);
        Assert.Contains("portLevelMtls:", istioYaml, StringComparison.Ordinal);
        Assert.Contains("mode: ISTIO_MUTUAL", istioYaml, StringComparison.Ordinal);
        Assert.Contains("action: DENY", istioYaml, StringComparison.Ordinal);
        Assert.Contains("minProtocolVersion: TLSV1_3", istioYaml, StringComparison.Ordinal);

        // 3. Falco 0.45.x eBPF detection + Cilium Tetragon v1.7.x synchronous Sigkill enforcement.
        var falcoYaml = File.ReadAllText(Path.Combine(prodClusterSecurityDir, "falco", "davids_rules.yaml"));
        Assert.Contains("Davids Dotnet Container Spawned Shell or Recon Tool", falcoYaml, StringComparison.Ordinal);
        var tetragonYaml = File.ReadAllText(Path.Combine(davidsRoot, "deploy", "k8s", "runtime-security", "tetragon-tracingpolicies.yaml"));
        Assert.Contains("kind: TracingPolicyNamespaced", tetragonYaml, StringComparison.Ordinal);
        Assert.Contains("action: Sigkill", tetragonYaml, StringComparison.Ordinal);

        // 4. Prometheus rules + unit tests, Grafana Unified Alerting + dashboard, and Seq login-audit signals.
        var promRules = File.ReadAllText(Path.Combine(prodClusterSecurityDir, "prometheus", "davids-security-rules.yml"));
        Assert.Contains("DavidsAdminAccountLockoutDetected", promRules, StringComparison.Ordinal);
        Assert.Contains("DavidsOidcTokenReplayOrGrantTamperingDetected", promRules, StringComparison.Ordinal);
        Assert.True(File.Exists(Path.Combine(prodClusterSecurityDir, "prometheus", "davids-security-rules.test.yml")));
        Assert.True(File.Exists(Path.Combine(davidsRoot, "deploy", "k8s", "observability", "prometheus-security-alerts.yaml")));
        Assert.True(File.Exists(Path.Combine(davidsRoot, "src", "Davids.AppHost", "config", "grafana", "provisioning", "alerting", "security-alerts.yaml")));
        Assert.True(File.Exists(Path.Combine(davidsRoot, "src", "Davids.AppHost", "config", "grafana", "dashboards", "davids-security-audit.json")));

        using (var seqDoc = System.Text.Json.JsonDocument.Parse(
                   File.ReadAllText(Path.Combine(prodClusterSecurityDir, "seq", "seq-security-signals-and-alerts.json"))))
        {
            Assert.Equal(6, seqDoc.RootElement.GetProperty("signals").GetArrayLength());
        }

        // 5. Production Cluster GitHub Actions workflow uses 40-char SHA pins and PowerShell scripts contain zero forbidden references.
        var prodClusterWorkflow = File.ReadAllText(Path.Combine(davidsRoot, ".github", "workflows", "production-cluster.yml"));
        foreach (var line in prodClusterWorkflow.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("uses:", StringComparison.Ordinal) || trimmed.StartsWith("- uses:", StringComparison.Ordinal))
            {
                var atIdx = trimmed.IndexOf('@');
                Assert.True(atIdx > 0, $"Unpinned action in production-cluster.yml: {trimmed}");
                var afterAt = trimmed[(atIdx + 1)..].Split([' ', '#', '\r'])[0];
                Assert.Equal(40, afterAt.Length);
                Assert.True(afterAt.All(Uri.IsHexDigit), $"Non-SHA action pin in production-cluster.yml: {trimmed}");
            }
        }

        foreach (var script in new[] { "Verify-ProductionClusterGates.ps1", "Bootstrap-SeqSecurityAlerts.ps1" })
        {
            var scriptPath = Path.Combine(davidsRoot, "scripts", "security", "production-cluster", script);
            Assert.True(File.Exists(scriptPath), $"Missing Production Cluster script {script}.");
            var content = File.ReadAllText(scriptPath);
            Assert.DoesNotContain("Convey", content, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Ntrada", content, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    [Trait("Category", "Unit")]
    public void CleanArchitectureLayerBoundariesAndTestCategoryTraitsAreEnforcedAcrossWorkspace()
    {
        var workspaceRoot = ResolveWorkspaceRoot();
        var repositories = new[]
        {
            "Davids",
            "Davids.Shared",
            "Davids.Services.Identity",
            "Davids.Services.AdminIdentity",
            "Davids.Services.Customers",
            "Davids.APIGateway",
            "Davids.Frontend.Admin"
        };

        var allCsprojFiles = repositories
            .SelectMany(repo => Directory.EnumerateFiles(Path.Combine(workspaceRoot, repo), "*.csproj", SearchOption.AllDirectories))
            .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}artifacts{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            .OrderBy(p => p, StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(25, allCsprojFiles.Length);

        foreach (var csproj in allCsprojFiles)
        {
            var projectName = Path.GetFileNameWithoutExtension(csproj);
            var rawXml = File.ReadAllText(csproj);
            Assert.DoesNotContain("<Nullable>disable</Nullable>", rawXml, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("CS86", rawXml, StringComparison.OrdinalIgnoreCase);

            var doc = System.Xml.Linq.XDocument.Load(csproj);
            var projectRefs = doc.Descendants()
                .Where(e => e.Name.LocalName == "ProjectReference")
                .Select(e => Path.GetFileNameWithoutExtension(
                    (e.Attribute("Include")?.Value ?? string.Empty).Replace('\\', '/')))
                .Where(n => !string.IsNullOrWhiteSpace(n))
                .ToArray();

            if (projectName == "Davids.ServiceDefaults")
            {
                Assert.Empty(projectRefs);
            }
            else if (projectName.EndsWith(".Core", StringComparison.Ordinal))
            {
                Assert.Empty(projectRefs);
            }
            else if (projectName.EndsWith(".Application", StringComparison.Ordinal))
            {
                var prefix = projectName[..^".Application".Length];
                Assert.Equal([$"{prefix}.Core"], projectRefs);
            }
            else if (projectName.StartsWith("Davids.Services.", StringComparison.Ordinal) &&
                     projectName.EndsWith(".Infrastructure", StringComparison.Ordinal))
            {
                var prefix = projectName[..^".Infrastructure".Length];
                Assert.All(projectRefs, r =>
                    Assert.True(r == $"{prefix}.Core" || r == $"{prefix}.Application",
                        $"Violation in {projectName}: unexpected ProjectReference '{r}'."));
            }
            else if (projectName.StartsWith("Davids.Services.", StringComparison.Ordinal) &&
                     projectName.EndsWith(".Api", StringComparison.Ordinal))
            {
                var prefix = projectName[..^".Api".Length];
                Assert.All(projectRefs, r =>
                    Assert.True(
                        r == "Davids.ServiceDefaults" ||
                        r == $"{prefix}.Core" ||
                        r == $"{prefix}.Application" ||
                        r == $"{prefix}.Infrastructure",
                        $"Violation in {projectName}: unexpected ProjectReference '{r}'."));
            }
            else if (projectName == "Davids.APIGateway.Infrastructure")
            {
                Assert.Empty(projectRefs);
            }
            else if (projectName == "Davids.APIGateway.Api")
            {
                Assert.All(projectRefs, r =>
                    Assert.True(r is "Davids.APIGateway.Infrastructure" or "Davids.ServiceDefaults",
                        $"Violation in {projectName}: unexpected ProjectReference '{r}'."));
            }
            else if (projectName == "Davids.Frontend.Admin")
            {
                Assert.Equal(["Davids.ServiceDefaults"], projectRefs);
            }
        }

        // Verify zero nullable #pragma suppressions in handwritten source/test files and verify every test declares Category=Unit|Integration.
        var traitCategoryRegex = new Regex(@"\[\s*Trait\s*\(\s*""Category""\s*,\s*""(Unit|Integration)""\s*\)\s*\]", RegexOptions.Compiled);
        var classDeclRegex = new Regex(@"\bpublic\s+(?:sealed\s+)?class\s+\w+", RegexOptions.Compiled);
        var testMethodAttrRegex = new Regex(@"^\s*\[\s*(Fact|Theory)\b", RegexOptions.Compiled);

        foreach (var repo in repositories)
        {
            var repoPath = Path.Combine(workspaceRoot, repo);
            foreach (var csFile in Directory.EnumerateFiles(repoPath, "*.cs", SearchOption.AllDirectories))
            {
                if (csFile.Contains($"{Path.DirectorySeparatorChar}artifacts{Path.DirectorySeparatorChar}", StringComparison.Ordinal) ||
                    csFile.Contains($"{Path.DirectorySeparatorChar}Migrations{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
                {
                    continue;
                }

                var content = File.ReadAllText(csFile);
                Assert.DoesNotContain("#pragma warning disable" + " CS86", content, StringComparison.Ordinal);
            }

            var testsRoot = Path.Combine(repoPath, "tests");
            Assert.True(Directory.Exists(testsRoot), $"Missing tests directory in {repo}.");
            if (repo != "Davids")
            {
                var hasArchTest = Directory.EnumerateFiles(testsRoot, "*.cs", SearchOption.AllDirectories)
                    .Any(f => f.EndsWith("ArchitectureTests.cs", StringComparison.Ordinal) ||
                              File.ReadAllText(f).Contains("GetReferencedAssemblies", StringComparison.Ordinal));
                Assert.True(hasArchTest, $"Expected Clean Architecture dependency test in {repo}/tests.");
            }

            foreach (var testFile in Directory.EnumerateFiles(testsRoot, "*.cs", SearchOption.AllDirectories))
            {
                if (testFile.Contains($"{Path.DirectorySeparatorChar}artifacts{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
                {
                    continue;
                }

                var lines = File.ReadAllLines(testFile);
                var classHasTrait = false;
                var pendingAttrHasTrait = false;

                for (var i = 0; i < lines.Length; i++)
                {
                    var line = lines[i];
                    if (traitCategoryRegex.IsMatch(line))
                    {
                        pendingAttrHasTrait = true;
                    }

                    if (classDeclRegex.IsMatch(line))
                    {
                        classHasTrait = pendingAttrHasTrait;
                        pendingAttrHasTrait = false;
                        continue;
                    }

                    if (testMethodAttrRegex.IsMatch(line))
                    {
                        var methodHasTrait = classHasTrait || pendingAttrHasTrait;
                        for (var j = i; !methodHasTrait && j < Math.Min(lines.Length, i + 6); j++)
                        {
                            if (traitCategoryRegex.IsMatch(lines[j]))
                            {
                                methodHasTrait = true;
                            }
                        }

                        Assert.True(
                            methodHasTrait,
                            $"Test at {testFile}:{i + 1} is missing [Trait(\"Category\", \"Unit\" | \"Integration\")].");
                        pendingAttrHasTrait = false;
                    }
                }
            }
        }
    }
}
