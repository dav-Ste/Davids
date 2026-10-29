using System.Net.Http.Json;
using System.Security.Cryptography;

if (args.Contains("--generate-rsa-key", StringComparer.Ordinal))
{
    using var generated = RSA.Create(2048);
    Console.Out.WriteLine(Convert.ToBase64String(generated.ExportPkcs8PrivateKey()));
    return;
}

if (Environment.GetEnvironmentVariable("DOTNET_ENVIRONMENT") != "Development")
{
    throw new InvalidOperationException("Vault bootstrap is strictly development-only.");
}

static string Required(string name)
{
    var value = Environment.GetEnvironmentVariable(name);
    if (string.IsNullOrWhiteSpace(value))
    {
        throw new InvalidOperationException($"Missing required environment variable {name}.");
    }

    return value.Trim();
}

static string ValidateRsaPrivateKeyAndComputeFingerprint(string rawKey, string name)
{
    using var rsa = RSA.Create();
    try
    {
        if (rawKey.Contains("-----BEGIN", StringComparison.Ordinal))
        {
            rsa.ImportFromPem(rawKey);
        }
        else
        {
            rsa.ImportPkcs8PrivateKey(Convert.FromBase64String(rawKey), out _);
        }
    }
    catch (Exception ex) when (ex is CryptographicException or FormatException)
    {
        throw new InvalidOperationException($"{name} is not a valid PKCS#8 RSA private key.", ex);
    }

    if (rsa.KeySize < 2048)
    {
        throw new InvalidOperationException($"{name} must be at least 2048 bits.");
    }

    return Convert.ToHexString(SHA256.HashData(rsa.ExportSubjectPublicKeyInfo()));
}

var customerSigningKey = Required("OIDC_SIGNING_KEY");
var customerEncryptionKey = Required("OIDC_ENCRYPTION_KEY");
var adminSigningKey = Required("ADMIN_OIDC_SIGNING_KEY");
var adminEncryptionKey = Required("ADMIN_OIDC_ENCRYPTION_KEY");
var adminBffClientSecret = Required("ADMIN_OIDC_BFF_CLIENT_SECRET");
var identityDpMasterKey = Required("IDENTITY_DP_MASTER_KEY");
var adminIdentityDpMasterKey = Required("ADMIN_IDENTITY_DP_MASTER_KEY");
var gatewayDpMasterKey = Required("GATEWAY_DP_MASTER_KEY");

if (adminBffClientSecret.Length < 24)
{
    throw new InvalidOperationException("ADMIN_OIDC_BFF_CLIENT_SECRET must be at least 24 characters.");
}

foreach (var (dpName, dpValue) in new[]
{
    ("IDENTITY_DP_MASTER_KEY", identityDpMasterKey),
    ("ADMIN_IDENTITY_DP_MASTER_KEY", adminIdentityDpMasterKey),
    ("GATEWAY_DP_MASTER_KEY", gatewayDpMasterKey)
})
{
    if (dpValue.Length < 32)
    {
        throw new InvalidOperationException($"{dpName} must be at least 32 characters (256 bits).");
    }
}

if (new[] { identityDpMasterKey, adminIdentityDpMasterKey, gatewayDpMasterKey }.Distinct(StringComparer.Ordinal).Count() != 3)
{
    throw new InvalidOperationException(
        "IDENTITY_DP_MASTER_KEY, ADMIN_IDENTITY_DP_MASTER_KEY, and GATEWAY_DP_MASTER_KEY must be distinct across trust boundaries.");
}

var fingerprints = new[]
{
    ValidateRsaPrivateKeyAndComputeFingerprint(customerSigningKey, "OIDC_SIGNING_KEY"),
    ValidateRsaPrivateKeyAndComputeFingerprint(customerEncryptionKey, "OIDC_ENCRYPTION_KEY"),
    ValidateRsaPrivateKeyAndComputeFingerprint(adminSigningKey, "ADMIN_OIDC_SIGNING_KEY"),
    ValidateRsaPrivateKeyAndComputeFingerprint(adminEncryptionKey, "ADMIN_OIDC_ENCRYPTION_KEY")
};

if (fingerprints.Distinct(StringComparer.Ordinal).Count() != fingerprints.Length)
{
    throw new InvalidOperationException(
        "OIDC_SIGNING_KEY, OIDC_ENCRYPTION_KEY, ADMIN_OIDC_SIGNING_KEY, and ADMIN_OIDC_ENCRYPTION_KEY must be cryptographically distinct 2048-bit+ RSA keys.");
}

using var client = new HttpClient { BaseAddress = new Uri(Required("VAULT_ADDR")), Timeout = TimeSpan.FromSeconds(5) };
client.DefaultRequestHeaders.Add("X-Vault-Token", Required("VAULT_TOKEN"));
using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(2));
while (true)
{
    try
    {
        using var health = await client.GetAsync("/v1/sys/health", deadline.Token);
        health.EnsureSuccessStatusCode();
        break;
    }
    catch (Exception e) when ((e is HttpRequestException || e is TaskCanceledException) && !deadline.IsCancellationRequested)
    {
        await Task.Delay(1000, deadline.Token);
    }
}

using var identityResult = await client.PostAsJsonAsync(
    "/v1/secret/data/davids/identity",
    new
    {
        data = new Dictionary<string, string>
        {
            ["Oidc:SigningKeyPem"] = customerSigningKey,
            ["Oidc:EncryptionKeyPem"] = customerEncryptionKey,
            ["DataProtection:MasterKey"] = identityDpMasterKey
        }
    },
    deadline.Token);
identityResult.EnsureSuccessStatusCode();

using var adminIdentityResult = await client.PostAsJsonAsync(
    "/v1/secret/data/davids/admin-identity",
    new
    {
        data = new Dictionary<string, string>
        {
            ["Oidc:SigningKeyPem"] = adminSigningKey,
            ["Oidc:EncryptionKeyPem"] = adminEncryptionKey,
            ["Oidc:BffClientSecret"] = adminBffClientSecret,
            ["DataProtection:MasterKey"] = adminIdentityDpMasterKey
        }
    },
    deadline.Token);
adminIdentityResult.EnsureSuccessStatusCode();

// Resource servers validate RS256 OIDC tokens via public JWKS discovery and never store signing keys in Vault.
using var customersResult = await client.PostAsJsonAsync(
    "/v1/secret/data/davids/customers",
    new { data = new Dictionary<string, string>() },
    deadline.Token);
customersResult.EnsureSuccessStatusCode();

// Davids.APIGateway validates RS256 OIDC tokens via public JWKS discovery and holds only its confidential BFF client secret and isolated Data Protection master key.
using var gatewayResult = await client.PostAsJsonAsync(
    "/v1/secret/data/davids/gateway",
    new
    {
        data = new Dictionary<string, string>
        {
            ["AdminOidc:BffClientSecret"] = adminBffClientSecret,
            ["DataProtection:MasterKey"] = gatewayDpMasterKey
        }
    },
    deadline.Token);
gatewayResult.EnsureSuccessStatusCode();

Console.WriteLine("Development Vault OIDC RSA keys and BFF client secret seeded across isolated service paths. No secret values are logged.");
