# Focused Vertical `.slnx` Solutions (`Davids/solutions`)

While `../Davids.slnx` opens all **47** projects across the 12 repositories, these focused `.slnx` solutions keep `.NET Aspire` (`Davids.AppHost`) available for `F5` local debugging while loading only the vertical slice you are working on:

- **`Davids.Orchestration.slnx`** (`3` projects): `Davids.AppHost`, `Davids.Bootstrap`, and `Davids.AppHost.Tests` for Aspire resource-graph, Vault bootstrap, and security-gate work.
- **`Davids.AdminVertical.slnx`** (`28` projects): `AppHost`, `Bootstrap`, `ServiceDefaults`, `APIGateway` (OIDC BFF), `AdminIdentity` (`adminidentitydb`), `Products` (`productsdb`), `Orders` (`ordersdb`), `Payments` (`paymentsdb`), and `Frontend.Admin`.
- **`Davids.CustomerVertical.slnx`** (`38` projects): `AppHost`, `Bootstrap`, `ServiceDefaults`, `APIGateway` (Customer OIDC BFF), `Identity` (`identitydb`), `Customers` (`customersdb`), `Products` (`productsdb`), `Baskets` (`basketsdb`), `Orders` (`ordersdb`), `Payments` (`paymentsdb`), and `Frontend.Web`.

> **Note:** Run `./scripts/Setup.ps1` once from `Davids/` before opening a vertical `.slnx` so all NuGet lockfiles and Aspire DCP/Dashboard packages are restored.
