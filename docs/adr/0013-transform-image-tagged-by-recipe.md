# 0013. The transform image is tagged by its recipe, tested by a pull request and pushed only by a merge

Date: 2026-09-27
Status: Accepted. Supersedes ADR 0008 in part: its tag format and its push
step. Deployment by digest stands.

## Context

ADR 0008 tagged the image `<app_version>-<commit>`, pushed it from the laptop,
and deployed it by digest. In CI that tag would change with every merge, even
one touching only documentation, so every merge would rebuild the image and,
since two builds are never byte-identical, deploy new bytes.

ECR keeps the 3 most recently pushed images (registry.tf) and counts pushes,
not deployments. If pull requests pushed images, a few that were never merged
could expire the image the function runs, and the function would fail.

A pull request's plan should still show when its image changes. Looking the
tag up in ECR (`aws_ecr_image`) fails the whole plan when the tag isn't there.

## Options considered

1. **Keep commit tags.** Rebuild and redeploy on every merge.
2. **Tag by recipe:** `<app_version>-<fingerprint>`, where the fingerprint is
   git's hash of `functions/transform` as committed (the Dockerfile, with the
   base image's digest, and the handler). The same recipe always gives the same
   tag, so an image is built only when its recipe changes.

And for pushing:

- **a.** A pull request pushes its image, so its plan can show the exact digest.
- **b.** A pull request builds and smoke-tests its image without pushing, and
  only a merge pushes it, then deploys it at once.

## Decision

We will tag by recipe (option 2) and push only on merge (b), both chosen by the
project owner. `build_transform_image.ps1` first looks for the recipe's tag in
ECR and builds only if it is missing. Terraform reads the repository's list of
images (`aws_ecr_images`): an image that is there is deployed by digest, as
before. One that isn't is named by tag, which only a pull request's plan is
allowed to do (`require_pushed_image = false`); everywhere else the plan
refuses it.

## Consequences

Easier: an image is rebuilt only when its recipe changes. Every pushed image is
deployed straight away, so ECR's keep-3 rule can no longer expire the image in
use through CI. A pull request that changes the recipe still gets a full plan,
and its image is smoke-tested before anyone merges.

Harder: that plan names the new image by tag; its exact bytes are only known
once the merge has built it. The fingerprint covers `functions/transform` and
the app version only, so it relies on two rules already kept: release tags in
the application repository are never moved, and anything else the image uses
is pinned inside that folder. As before (ADR 0008), a rebuild of the same
recipe might resolve newer patch releases; now there is usually no rebuild,
so the first image built for a recipe is the one that stays.

Revisit if the image starts depending on files outside `functions/transform`.
