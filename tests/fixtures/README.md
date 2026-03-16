# Test Fixtures — ACR ↔ AMR Migration Templates

Sample Azure Cache for Redis (ACR) and Azure Managed Redis (AMR) templates used as
**source ("before")** and **migrated ("after")** states for the AMR migration skill tests.

## Directory Structure

```
fixtures/
├── arm/                        # ARM JSON templates & parameters
│   ├── acr-cache.json          # ACR source template
│   ├── acr-cache.parameters.json
│   ├── acr-cache.bicepparam    # ACR source bicepparam
│   ├── params/                 # ACR parameter variants (Basic/Standard/Premium)
│   └── migrated/               # AMR migrated output templates & parameters
├── bicep/                      # Bicep templates & parameters
│   ├── acr-cache.bicep         # ACR source Bicep template
│   ├── acr-cache.bicepparam    # ACR source bicepparam
│   ├── acr-cache.json          # Compiled ARM JSON from Bicep
│   └── params/                 # ACR bicepparam variants
└── validation/                 # Validate-Migration.ps1 test fixtures
```

## Usage

```powershell
# Validate ARM
az deployment group validate --resource-group myRG --template-file arm/acr-cache.json --parameters arm/acr-cache.parameters.json

# Validate Bicep
az bicep build --file bicep/acr-cache.bicep
```
