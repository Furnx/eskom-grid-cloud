# 0008. The transform image is pushed by a script and deployed by digest

Date: 2026-09-25
Status: Accepted

Recorded 2026-09-26, the day after the decision, once the first deployments had
exercised it.

## Context

dbt, dbt-duckdb and DuckDB's extensions are far beyond the 250 MB limit on an
unzipped Lambda zip, so the transform ships as a container image (about 800 MB
unpacked, 265 MB compressed) from an ECR repository in the same region.

Terraform does not build images, yet it decides which image the function runs:
whatever `image_uri` names. An image **tag** names a recipe, not bytes: a
rebuild of the same tag can resolve newer patch releases (`dbt-core==1.11.*`),
and Lambda turns a tag into a digest once, at deploy time, so a new push under
an old tag never shows up in a plan. An image **digest** names the exact bytes.

Until Phase 4, images are built and pushed from the laptop (Docker Desktop,
arm64 under emulation), and a deploy should be as reviewable in `terraform plan`
as the extract function's is.

## Options considered

1. **Record the pushed tag; deploy its digest.** The build script pushes, then
   writes the tag to `build/transform_image_tag.txt`. Terraform looks the tag up
   in ECR (`data "aws_ecr_image"`) and deploys `repository@digest`. A
   precondition requires the tag to start with `app_version`. It mirrors
   extract's `build/app_version.txt`.
2. **Deploy whatever was pushed last** (`most_recent = true`). Simpler, but a
   push alone changes what the next apply deploys, with nothing in the code to
   show why.
3. **Pass the tag at apply time** (`-var`). Explicit, but a manual step that is
   easy to get wrong, and the plan depends on what was typed.
4. **Build inside Terraform** (a Docker provider or `local-exec`). One command,
   but it mixes building with infrastructure, slows every plan, and buries build
   failures in apply output.

## Decision

We will build and smoke-test the image with `scripts/build_transform_image.ps1`,
push it only with `-Push` and only from committed code, record the pushed tag in
`build/transform_image_tag.txt`, and have Terraform resolve that tag to a digest
and deploy by digest. ECR tags are immutable. (Option 1, chosen by the project
owner from the options above.)

## Consequences

Easier: the plan shows exactly which bytes change (a new digest); rolling back
means deploying the previous digest; the image that passed the smoke tests is
the image Lambda runs (on 2026-09-26 the digest built locally, `7254ea6b…`, was
the digest deployed).

Harder: two steps before every apply (push, then plan), and the first deploy to
an empty account needs `terraform apply "-target=aws_ecr_repository.transform"`
before the first push. A file in `build/` on the laptop becomes an input to the
plan. ECR's keep-the-last-3 rule counts pushes, not deployments: pushing more
than three images without deploying could delete the deployed one, which puts
the function into the `Failed` state.

Given up: bytes reproducible from the tag alone. Two builds of one tag can
differ; the digest, not the tag, is the record of what ran.

Revisit when Phase 4 moves the build and push into CI (the tag file becomes a
pipeline artefact or output), or if a second image appears.
