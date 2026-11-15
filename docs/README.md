# Documentation

| Folder | Doc | What it covers |
|---|---|---|
| `architecture/` | [Deployment units](architecture/deployment-units.md) | What a unit is, what it needs, its names, why one unit per project |
| | [Instance templates](architecture/instance-templates.md) | The per-tier VM template Batch creates runners from |
| | [Runner image](architecture/runner-image.md) | The image each unit builds, how, and who may do what |
| | [Security model](architecture/security-model.md) | The accounts, the firewall, the secrets and what a job can reach |
| `reference/` | [Deployer requirements](reference/deployer-requirements.md) | APIs, roles and grants a project and its deployer need |
| | [Tiers](reference/tiers.md) | Tier rules, disk sizes and quotas |
| `guides/` | [Installing a unit](guides/installing-a-unit.md) | A new unit for an organisation, from project to first job |
| `operations/` | [Releases](operations/releases.md) | Cutting a release of the module and the image action, and choosing its version |
