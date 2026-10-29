using System.Security.Cryptography;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Publishing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;

var builder = DistributedApplication.CreateBuilder(args);
if (!builder.Environment.IsDevelopment())
    throw new InvalidOperationException("This AppHost defines development infrastructure. Harden and deploy managed infrastructure separately for production.");
bool Enabled(string name, bool fallback = true) => builder.Configuration.GetValue($"Integrations:{name}", fallback);
var sql = builder.AddSqlServer("sql").WithDataVolume();
var database = sql.AddDatabase("identitydb");
var adminIdentityDatabase = sql.AddDatabase("adminidentitydb");
var customersDatabase = sql.AddDatabase("customersdb");
var rabbit = builder.AddRabbitMQ("messaging").WithDataVolume().WithManagementPlugin();
var oidcSigningKey = builder.AddParameter("oidc-signing-key", new RsaPrivateKeyParameterDefault(), secret: true, persist: true);
var oidcEncryptionKey = builder.AddParameter("oidc-encryption-key", new RsaPrivateKeyParameterDefault(), secret: true, persist: true);
var adminOidcSigningKey = builder.AddParameter("admin-oidc-signing-key", new RsaPrivateKeyParameterDefault(), secret: true, persist: true);
var adminOidcEncryptionKey = builder.AddParameter("admin-oidc-encryption-key", new RsaPrivateKeyParameterDefault(), secret: true, persist: true);
var adminOidcBffClientSecret = builder.AddParameter(
    "admin-oidc-bff-client-secret",
    new GenerateParameterDefault { MinLength = 48, Lower = true, Upper = true, Numeric = true, Special = false },
    secret: true,
    persist: true);
var identityDataProtectionKey = builder.AddParameter(
    "identity-dataprotection-key",
    new GenerateParameterDefault { MinLength = 48, Lower = true, Upper = true, Numeric = true, Special = false },
    secret: true,
    persist: true);
var adminIdentityDataProtectionKey = builder.AddParameter(
    "admin-identity-dataprotection-key",
    new GenerateParameterDefault { MinLength = 48, Lower = true, Upper = true, Numeric = true, Special = false },
    secret: true,
    persist: true);
var gatewayDataProtectionKey = builder.AddParameter(
    "gateway-dataprotection-key",
    new GenerateParameterDefault { MinLength = 48, Lower = true, Upper = true, Numeric = true, Special = false },
    secret: true,
    persist: true);

var identity = builder.AddProject<Projects.Davids_Services_Identity_Api>("identity")
    .WithReference(database).WaitFor(database)
    .WithReference(rabbit).WaitFor(rabbit)
    .WithEnvironment("Database__ApplyMigrations", "true")
    .WithHttpHealthCheck("/health");
identity.WithEnvironment("Oidc__Issuer", ReferenceExpression.Create($"{identity.GetEndpoint("http")}/"));

var adminIdentity = builder.AddProject<Projects.Davids_Services_AdminIdentity_Api>("admin-identity")
    .WithReference(adminIdentityDatabase).WaitFor(adminIdentityDatabase)
    .WithEnvironment("Database__ApplyMigrations", "true")
    .WithHttpHealthCheck("/health");
adminIdentity.WithEnvironment("Oidc__Issuer", ReferenceExpression.Create($"{adminIdentity.GetEndpoint("http")}/"));

if (Enabled("SeedAdmin"))
{
    var devAdminPassword = builder.AddParameter(
        "dev-admin-password",
        new GenerateParameterDefault
        {
            MinLength = 24,
            Lower = true,
            Upper = true,
            Numeric = true,
            Special = true,
            MinLower = 2,
            MinUpper = 2,
            MinNumeric = 2,
            MinSpecial = 2
        },
        secret: true,
        persist: true);
    adminIdentity.WithEnvironment("SeedAdmin__Enabled", "true")
        .WithEnvironment("SeedAdmin__Email", builder.Configuration["SeedAdmin:Email"] ?? "admin@davids.local")
        .WithEnvironment("SeedAdmin__Password", devAdminPassword);
}

var customers = builder.AddProject<Projects.Davids_Services_Customers_Api>("customers")
    .WithReference(customersDatabase).WaitFor(customersDatabase)
    .WithReference(rabbit).WaitFor(rabbit)
    .WithEnvironment("Database__ApplyMigrations", "true")
    .WithEnvironment("Messaging__Enabled", "true")
    .WithEnvironment("CustomerOidc__Authority", ReferenceExpression.Create($"{identity.GetEndpoint("http")}"))
    .WithEnvironment("CustomerOidc__Issuer", ReferenceExpression.Create($"{identity.GetEndpoint("http")}/"))
    .WithEnvironment("AdminOidc__Authority", ReferenceExpression.Create($"{adminIdentity.GetEndpoint("http")}"))
    .WithEnvironment("AdminOidc__Issuer", ReferenceExpression.Create($"{adminIdentity.GetEndpoint("http")}/"))
    .WaitFor(identity)
    .WaitFor(adminIdentity)
    .WithHttpHealthCheck("/health");

IResourceBuilder<ProjectResource>? frontendAdmin = null;
IResourceBuilder<ProjectResource>? apiGateway = null;

if (Enabled("ApiGateway"))
{
    // Allow plain HTTP and loopback X-Forwarded-For from the local YARP API Gateway in Development.
    identity.WithEnvironment("Http__AllowInsecureDevelopment", "true")
        .WithEnvironment("ForwardedHeaders__TrustLoopback", "true");
    adminIdentity.WithEnvironment("Http__AllowInsecureDevelopment", "true")
        .WithEnvironment("ForwardedHeaders__TrustLoopback", "true");
    customers.WithEnvironment("Http__AllowInsecureDevelopment", "true")
        .WithEnvironment("ForwardedHeaders__TrustLoopback", "true");

    frontendAdmin = builder.AddProject<Projects.Davids_Frontend_Admin>("frontend-admin")
        .WithHttpHealthCheck("/health");
    apiGateway = builder.AddProject<Projects.Davids_APIGateway_Api>("api-gateway")
        .WithEnvironment("CustomerOidc__Authority", ReferenceExpression.Create($"{identity.GetEndpoint("http")}"))
        .WithEnvironment("CustomerOidc__Issuer", ReferenceExpression.Create($"{identity.GetEndpoint("http")}/"))
        .WithEnvironment("AdminOidc__Authority", ReferenceExpression.Create($"{adminIdentity.GetEndpoint("http")}"))
        .WithEnvironment("AdminOidc__Issuer", ReferenceExpression.Create($"{adminIdentity.GetEndpoint("http")}/"))
        .WithEnvironment("ReverseProxy__Clusters__identity__Destinations__primary__Address",
            ReferenceExpression.Create($"{identity.GetEndpoint("http")}/"))
        .WithEnvironment("ReverseProxy__Clusters__admin-identity__Destinations__primary__Address",
            ReferenceExpression.Create($"{adminIdentity.GetEndpoint("http")}/"))
        .WithEnvironment("ReverseProxy__Clusters__customers__Destinations__primary__Address",
            ReferenceExpression.Create($"{customers.GetEndpoint("http")}/"))
        .WithEnvironment("ReverseProxy__Clusters__frontend-admin__Destinations__primary__Address",
            ReferenceExpression.Create($"{frontendAdmin.GetEndpoint("http")}/"))
        .WaitFor(frontendAdmin)
        .WaitFor(identity)
        .WaitFor(adminIdentity)
        .WaitFor(customers)
        .WithHttpHealthCheck("/health");

    adminIdentity
        .WithEnvironment("Oidc__GatewayRedirectUri", ReferenceExpression.Create($"{apiGateway.GetEndpoint("http")}/signin-oidc"))
        .WithEnvironment("Oidc__GatewayPostLogoutRedirectUri", ReferenceExpression.Create($"{apiGateway.GetEndpoint("http")}/login"));
}

if (Enabled("Redis"))
{
    var redis = builder.AddRedis("cache").WithDataVolume();
    identity.WithReference(redis).WaitFor(redis).WithEnvironment("Redis__Enabled", "true");
    adminIdentity.WithReference(redis).WaitFor(redis).WithEnvironment("Redis__Enabled", "true");
    apiGateway?.WithReference(redis).WaitFor(redis).WithEnvironment("Redis__Enabled", "true");
}
if (Enabled("Vault"))
{
    var rootToken = builder.AddParameter(
        "vault-dev-root-token",
        new GenerateParameterDefault { MinLength = 48, Lower = true, Upper = true, Numeric = true, Special = false },
        secret: true,
        persist: true);
    var vault = builder.AddContainer("vault", "hashicorp/vault", "2.1.2")
        .WithArgs("server", "-dev", "-dev-listen-address=0.0.0.0:8200")
        .WithEnvironment("VAULT_DEV_ROOT_TOKEN_ID", rootToken)
        // Vault 2.1.2's official image requires IPC_LOCK for its default mlock behavior.
        .WithContainerRuntimeArgs("--cap-add=IPC_LOCK")
        .WithHttpEndpoint(targetPort: 8200, name: "http")
        .WithHttpHealthCheck("/v1/sys/health");
    var bootstrap = builder.AddProject<Projects.Davids_Bootstrap>("vault-bootstrap")
        .WithEnvironment("DOTNET_ENVIRONMENT", "Development")
        .WithEnvironment("VAULT_ADDR", vault.GetEndpoint("http"))
        .WithEnvironment("VAULT_TOKEN", rootToken)
        .WithEnvironment("OIDC_SIGNING_KEY", oidcSigningKey)
        .WithEnvironment("OIDC_ENCRYPTION_KEY", oidcEncryptionKey)
        .WithEnvironment("ADMIN_OIDC_SIGNING_KEY", adminOidcSigningKey)
        .WithEnvironment("ADMIN_OIDC_ENCRYPTION_KEY", adminOidcEncryptionKey)
        .WithEnvironment("ADMIN_OIDC_BFF_CLIENT_SECRET", adminOidcBffClientSecret)
        .WithEnvironment("IDENTITY_DP_MASTER_KEY", identityDataProtectionKey)
        .WithEnvironment("ADMIN_IDENTITY_DP_MASTER_KEY", adminIdentityDataProtectionKey)
        .WithEnvironment("GATEWAY_DP_MASTER_KEY", gatewayDataProtectionKey)
        .WaitFor(vault);
    identity.WithEnvironment("Vault__Enabled", "true")
        .WithEnvironment("Vault__Address", vault.GetEndpoint("http"))
        .WithEnvironment("Vault__Token", rootToken)
        .WithEnvironment("Vault__KvPath", "secret/data/davids/identity")
        .WaitForCompletion(bootstrap);
    adminIdentity.WithEnvironment("Vault__Enabled", "true")
        .WithEnvironment("Vault__Address", vault.GetEndpoint("http"))
        .WithEnvironment("Vault__Token", rootToken)
        .WithEnvironment("Vault__KvPath", "secret/data/davids/admin-identity")
        .WaitForCompletion(bootstrap);
    customers.WithEnvironment("Vault__Enabled", "true")
        .WithEnvironment("Vault__Address", vault.GetEndpoint("http"))
        .WithEnvironment("Vault__Token", rootToken)
        .WithEnvironment("Vault__KvPath", "secret/data/davids/customers")
        .WaitForCompletion(bootstrap);
    apiGateway?.WithEnvironment("Vault__Enabled", "true")
        .WithEnvironment("Vault__Address", vault.GetEndpoint("http"))
        .WithEnvironment("Vault__Token", rootToken)
        .WithEnvironment("Vault__KvPath", "secret/data/davids/gateway")
        .WaitForCompletion(bootstrap);
}
else
{
    identity.WithEnvironment("Oidc__SigningKeyPem", oidcSigningKey)
        .WithEnvironment("Oidc__EncryptionKeyPem", oidcEncryptionKey)
        .WithEnvironment("DataProtection__MasterKey", identityDataProtectionKey);
    adminIdentity.WithEnvironment("Oidc__SigningKeyPem", adminOidcSigningKey)
        .WithEnvironment("Oidc__EncryptionKeyPem", adminOidcEncryptionKey)
        .WithEnvironment("Oidc__BffClientSecret", adminOidcBffClientSecret)
        .WithEnvironment("DataProtection__MasterKey", adminIdentityDataProtectionKey);
    // Customers and Davids.APIGateway validate RS256 OIDC tokens via public JWKS discovery and never receive signing keys.
    apiGateway?.WithEnvironment("AdminOidc__BffClientSecret", adminOidcBffClientSecret)
        .WithEnvironment("DataProtection__MasterKey", gatewayDataProtectionKey);
}

IResourceBuilder<ContainerResource>? jaeger = null;
IResourceBuilder<ContainerResource>? prometheus = null;

if (Enabled("Jaeger"))
{
    jaeger = builder.AddContainer("jaeger", "jaegertracing/jaeger", "2.22.0")
        .WithEnvironment("JAEGER_LISTEN_HOST", "0.0.0.0")
        .WithHttpEndpoint(targetPort: 16686, name: "ui")
        .WithHttpEndpoint(targetPort: 4318, name: "otlp");
    var jaegerEndpoint = ReferenceExpression.Create($"{jaeger.GetEndpoint("otlp")}/v1/traces");
    identity.WithEnvironment("Telemetry__Jaeger__Enabled", "true")
        .WithEnvironment("Telemetry__Jaeger__Endpoint", jaegerEndpoint);
    adminIdentity.WithEnvironment("Telemetry__Jaeger__Enabled", "true")
        .WithEnvironment("Telemetry__Jaeger__Endpoint", jaegerEndpoint);
    customers.WithEnvironment("Telemetry__Jaeger__Enabled", "true")
        .WithEnvironment("Telemetry__Jaeger__Endpoint", jaegerEndpoint);
    apiGateway?.WithEnvironment("Telemetry__Jaeger__Enabled", "true")
        .WithEnvironment("Telemetry__Jaeger__Endpoint", jaegerEndpoint);
    frontendAdmin?.WithEnvironment("Telemetry__Jaeger__Enabled", "true")
        .WithEnvironment("Telemetry__Jaeger__Endpoint", jaegerEndpoint);
}
if (Enabled("Seq"))
{
    var seq = builder.AddContainer("seq", "datalust/seq", "2026.1.17182")
        .WithEnvironment("ACCEPT_EULA", "Y")
        .WithEnvironment("SEQ_FIRSTRUN_NOAUTHENTICATION", "true")
        .WithVolume("davids-seq-data", "/data")
        .WithHttpEndpoint(targetPort: 80, name: "http");
    identity.WithEnvironment("LoggingSinks__Seq__Enabled", "true")
        .WithEnvironment("LoggingSinks__Seq__Url", seq.GetEndpoint("http"));
    adminIdentity.WithEnvironment("LoggingSinks__Seq__Enabled", "true")
        .WithEnvironment("LoggingSinks__Seq__Url", seq.GetEndpoint("http"));
    customers.WithEnvironment("LoggingSinks__Seq__Enabled", "true")
        .WithEnvironment("LoggingSinks__Seq__Url", seq.GetEndpoint("http"));
    apiGateway?.WithEnvironment("LoggingSinks__Seq__Enabled", "true")
        .WithEnvironment("LoggingSinks__Seq__Url", seq.GetEndpoint("http"));
    frontendAdmin?.WithEnvironment("LoggingSinks__Seq__Enabled", "true")
        .WithEnvironment("LoggingSinks__Seq__Url", seq.GetEndpoint("http"));
}
identity.WithEnvironment("LoggingSinks__File__Enabled", Enabled("FileLogging").ToString());
adminIdentity.WithEnvironment("LoggingSinks__File__Enabled", Enabled("FileLogging").ToString());
customers.WithEnvironment("LoggingSinks__File__Enabled", Enabled("FileLogging").ToString());
apiGateway?.WithEnvironment("LoggingSinks__File__Enabled", Enabled("FileLogging").ToString());
frontendAdmin?.WithEnvironment("LoggingSinks__File__Enabled", Enabled("FileLogging").ToString());
if (Enabled("Prometheus"))
{
    prometheus = builder.AddContainer("prometheus", "prom/prometheus", "v3.15.0")
        .WithArgs("--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus", "--web.enable-otlp-receiver")
        .WithVolume("davids-prometheus-data", "/prometheus")
        .WithHttpEndpoint(targetPort: 9090, name: "http");
    var prometheusEndpoint = ReferenceExpression.Create($"{prometheus.GetEndpoint("http")}/api/v1/otlp/v1/metrics");
    identity.WithEnvironment("Telemetry__Prometheus__Enabled", "true")
        .WithEnvironment("Telemetry__Prometheus__Endpoint", prometheusEndpoint);
    adminIdentity.WithEnvironment("Telemetry__Prometheus__Enabled", "true")
        .WithEnvironment("Telemetry__Prometheus__Endpoint", prometheusEndpoint);
    customers.WithEnvironment("Telemetry__Prometheus__Enabled", "true")
        .WithEnvironment("Telemetry__Prometheus__Endpoint", prometheusEndpoint);
    apiGateway?.WithEnvironment("Telemetry__Prometheus__Enabled", "true")
        .WithEnvironment("Telemetry__Prometheus__Endpoint", prometheusEndpoint);
    frontendAdmin?.WithEnvironment("Telemetry__Prometheus__Enabled", "true")
        .WithEnvironment("Telemetry__Prometheus__Endpoint", prometheusEndpoint);
}
if (Enabled("Grafana"))
{
    var configuredPrometheusUrl = builder.Configuration["Grafana:PrometheusUrl"];
    var configuredJaegerUrl = builder.Configuration["Grafana:JaegerUrl"];

    if (string.IsNullOrWhiteSpace(configuredPrometheusUrl) && prometheus is null)
        throw new InvalidOperationException("Grafana requires either Integrations:Prometheus=true or an explicit Grafana:PrometheusUrl (for example, your cluster's Prometheus URL).");
    if (string.IsNullOrWhiteSpace(configuredJaegerUrl) && jaeger is null)
        throw new InvalidOperationException("Grafana requires either Integrations:Jaeger=true or an explicit Grafana:JaegerUrl (for example, your cluster's Jaeger Query URL).");

    var grafana = builder.AddContainer("grafana", "grafana/grafana", "13.2.4")
        // Development-only convenience matching local Seq/Prometheus/Jaeger; see deploy/k8s/grafana.yaml for cluster Secret auth.
        .WithEnvironment("GF_AUTH_ANONYMOUS_ENABLED", "true")
        .WithEnvironment("GF_AUTH_ANONYMOUS_ORG_ROLE", "Admin")
        .WithEnvironment("GF_USERS_DEFAULT_THEME", "dark")
        .WithEnvironment("GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH", "/etc/grafana/dashboards/davids-overview.json")
        .WithBindMount(Path.Combine(builder.AppHostDirectory, "config", "grafana", "provisioning"), "/etc/grafana/provisioning", isReadOnly: true)
        .WithBindMount(Path.Combine(builder.AppHostDirectory, "config", "grafana", "dashboards"), "/etc/grafana/dashboards", isReadOnly: true)
        .WithVolume("davids-grafana-data", "/var/lib/grafana")
        .WithContainerRuntimeArgs("--add-host=host.docker.internal:host-gateway")
        .WithHttpEndpoint(targetPort: 3000, name: "http")
        .WithHttpHealthCheck("/api/health");

    if (!string.IsNullOrWhiteSpace(configuredPrometheusUrl))
        grafana.WithEnvironment("PROMETHEUS_URL", configuredPrometheusUrl.TrimEnd('/'));
    else
        grafana.WithEnvironment("PROMETHEUS_URL", prometheus!.GetEndpoint("http")).WaitFor(prometheus!);

    if (!string.IsNullOrWhiteSpace(configuredJaegerUrl))
        grafana.WithEnvironment("JAEGER_URL", configuredJaegerUrl.TrimEnd('/'));
    else
        grafana.WithEnvironment("JAEGER_URL", jaeger!.GetEndpoint("ui")).WaitFor(jaeger!);
}
// Opt-in metric sink; disabled by default due to local memory/startup cost.
if (Enabled("InfluxDB", false))
{
    var influx = builder.AddContainer("influxdb", "influxdb", "3.11.4-core")
        .WithArgs("influxdb3", "serve", "--node-id=davids", "--object-store=file", "--data-dir=/var/lib/influxdb3", "--without-auth")
        .WithVolume("davids-influx-data", "/var/lib/influxdb3")
        .WithHttpEndpoint(targetPort: 8181, name: "http");
    var collector = builder.AddContainer("influx-collector", "otel/opentelemetry-collector-contrib", "0.162.0")
        .WithArgs("--config=/etc/otelcol/config.yaml")
        .WithBindMount(Path.Combine(builder.AppHostDirectory, "config", "influx-collector.yaml"), "/etc/otelcol/config.yaml", isReadOnly: true)
        .WithEnvironment("INFLUXDB_ENDPOINT", influx.GetEndpoint("http"))
        .WithHttpEndpoint(targetPort: 4318, name: "otlp").WaitFor(influx);
    var influxEndpoint = ReferenceExpression.Create($"{collector.GetEndpoint("otlp")}/v1/metrics");
    identity.WithEnvironment("Telemetry__InfluxDB__Enabled", "true")
        .WithEnvironment("Telemetry__InfluxDB__Endpoint", influxEndpoint);
    adminIdentity.WithEnvironment("Telemetry__InfluxDB__Enabled", "true")
        .WithEnvironment("Telemetry__InfluxDB__Endpoint", influxEndpoint);
    customers.WithEnvironment("Telemetry__InfluxDB__Enabled", "true")
        .WithEnvironment("Telemetry__InfluxDB__Endpoint", influxEndpoint);
    apiGateway?.WithEnvironment("Telemetry__InfluxDB__Enabled", "true")
        .WithEnvironment("Telemetry__InfluxDB__Endpoint", influxEndpoint);
    frontendAdmin?.WithEnvironment("Telemetry__InfluxDB__Enabled", "true")
        .WithEnvironment("Telemetry__InfluxDB__Endpoint", influxEndpoint);
}
if (Enabled("Elasticsearch", false))
{
    var elastic = builder.AddContainer("elasticsearch", "docker.elastic.co/elasticsearch/elasticsearch", "9.5.5")
        .WithEnvironment("discovery.type", "single-node")
        .WithEnvironment("xpack.security.enabled", "false")
        .WithEnvironment("ES_JAVA_OPTS", "-Xms512m -Xmx512m")
        .WithVolume("davids-elastic-data", "/usr/share/elasticsearch/data")
        .WithHttpEndpoint(targetPort: 9200, name: "http")
        .WithHttpHealthCheck("/_cluster/health");
    identity.WithEnvironment("LoggingSinks__Elasticsearch__Enabled", "true")
        .WithEnvironment("LoggingSinks__Elasticsearch__Url", elastic.GetEndpoint("http")).WaitFor(elastic);
    adminIdentity.WithEnvironment("LoggingSinks__Elasticsearch__Enabled", "true")
        .WithEnvironment("LoggingSinks__Elasticsearch__Url", elastic.GetEndpoint("http")).WaitFor(elastic);
    customers.WithEnvironment("LoggingSinks__Elasticsearch__Enabled", "true")
        .WithEnvironment("LoggingSinks__Elasticsearch__Url", elastic.GetEndpoint("http")).WaitFor(elastic);
    apiGateway?.WithEnvironment("LoggingSinks__Elasticsearch__Enabled", "true")
        .WithEnvironment("LoggingSinks__Elasticsearch__Url", elastic.GetEndpoint("http")).WaitFor(elastic);
    frontendAdmin?.WithEnvironment("LoggingSinks__Elasticsearch__Enabled", "true")
        .WithEnvironment("LoggingSinks__Elasticsearch__Url", elastic.GetEndpoint("http")).WaitFor(elastic);
    builder.AddContainer("kibana", "docker.elastic.co/kibana/kibana", "9.5.5")
        .WithEnvironment("ELASTICSEARCH_HOSTS", ReferenceExpression.Create($"[\"{elastic.GetEndpoint("http")}\"]"))
        .WithHttpEndpoint(targetPort: 5601, name: "http").WaitFor(elastic);
}
builder.Build().Run();

internal sealed class RsaPrivateKeyParameterDefault : ParameterDefault
{
    private readonly Lazy<string> generatedKey = new(() =>
    {
        using var rsa = RSA.Create(2048);
        return Convert.ToBase64String(rsa.ExportPkcs8PrivateKey());
    });

    public override string GetDefaultValue() => generatedKey.Value;

    public override void WriteToManifest(ManifestPublishingContext context)
    {
        context.Writer.WriteStartObject("generated");
        context.Writer.WriteNumber("minLength", 2048);
        context.Writer.WriteEndObject();
    }
}
