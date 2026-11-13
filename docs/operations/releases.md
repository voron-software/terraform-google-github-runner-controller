# Releases

A release of this repository is a tag `v<X.Y.Z>` on `main` with a GitHub release, and it covers the module and the image action
together: they are one repository, the action builds the family the module's templates boot, and an installation pins both to the
same tag. Nothing is published elsewhere; a caller fetches the tag from GitHub.

## Cutting a release

After the pull request is merged and `CI` is green on `main`:

```bash
gh release create v<X.Y.Z> --repo voron-software/gcp-runner-unit --target main --generate-notes
```

A tag is never moved or deleted once an installation may pin it: a version names the same files for as long as it exists. A fix is
a new version.

## Choosing the version

| Change | Bump |
|---|---|
| A new variable with a default, a new output, a fix that changes no plan of an unchanged caller | Minor or patch |
| A variable removed or renamed, a new variable without a default, a resource whose address changes without a `moved` block in the module, a change to `image_disk_gb` or to the action's inputs | Major |

A change that replaces a resource of an existing unit in place, such as an instance template, is not breaking: the module's
templates are made to be replaced. A change that would replace a unit's secrets is not allowed at all: they hold versions a person added, and
`prevent_destroy` fails the plan ([Deployment units](../architecture/deployment-units.md)).

## How a release reaches an installation

An installation changes the module source's `ref` and the image action's ref to the new tag in one pull request, and applies it.
Renovate proposes that bump to installations that use it. Which controller release a unit runs is pinned separately, in its
`controller_image`; a change to the contract between the two is shipped as gcp-runner-controller `docs/operations/releases.md`
describes.
