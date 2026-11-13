---
name: promote
description: Promote staging to production - fold dated staging overrides into base, set every production pin to the base value, verify with flate, and open one pull request
---

You promote staging to production in this repository. Read docs/03-cluster-architecture-guide.md
first, in particular the sections "Environment overrides" and "Promotion". Change files only
under kubernetes/apps. Open at most one pull request. Do not merge anything.

How the overlays work: kubernetes/apps/base/<app>/app holds the manifests of an app, and both
clusters run them. Staging runs base as it is. Production overrides an app in
kubernetes/apps/production/<ns>/patches/<app>.yaml: a Flux Kustomization patch whose
`spec.patches` entries each hold one inner document as a literal block, with the kind and name
of the resource it changes. The staging overlay has the same shape under kubernetes/apps/staging.
The base counterpart of an override is always the app directory with the same name as the
override file.

Do these steps in order.

1. Fold staging overrides into base. A staging override file is a candidate only if its header
   carries a comment of the form `# promote-after: YYYY-MM-DD` with a date on or before today.
   Files without that comment are permanent differences between the environments. Never touch
   them. For each candidate, take each inner document from its `spec.patches` and merge the
   fields it sets into the base manifest of that resource, the file under
   kubernetes/apps/base/<app>/app whose kind and name match the inner document, in the place
   where those fields belong. Never edit the base ks.yaml. Carry over the rationale comments
   from the staging file. Then delete the staging file and its entry in the staging
   kustomization.yaml. If an inner document in the production override of the same app now sets
   a field to the same value as base, remove that field; remove the whole entry when nothing is
   left in it, and the override file and its kustomization entry when no entry is left.
   Version pins stay in production. Do this step first, so that a folded version change
   reaches production in step 2.

2. Promote versions. A version pin in production is a `# renovate:` comment followed by the
   pinned line or lines: `tag:` plus `digest:`, `tag: <version>@sha256:...`, `image:` or
   `imageName:` with `<repository>:<version>@sha256:...`, or `version:`. For each pin, find the
   same dependency in the base directory of that app: the OCIRepository whose url ends in the
   depName, the line under the `# renovate:` comment with the same depName, or the
   `repository:` plus `tag:` pair of that image in the HelmRelease values. Set the production
   value to the base value, the tag and the digest together. If the base counterpart is missing
   or more than one line matches, do not guess: leave that pin alone and say so in the pull
   request body. Skip the pins of siderolabs/talos and ghcr.io/siderolabs/kubelet: they move
   together with talos/production/topf.yaml through Renovate, not here. Change nothing else
   in production, and never edit a `# renovate:` comment.

3. Verify. Run `oxfmt` on the files you changed, then `flate test helmrelease` and
   `flate test kustomization`. Then check `git status`: every changed file must be under
   kubernetes/apps; every changed or deleted staging override must carry the marker with a date
   on or before today in its version on main (read it with `git show main:<path>`, so that a
   marker added during this run does not count); and a staging kustomization.yaml may change
   only by losing the entries of those overrides. If a flate test fails or the check fails,
   print what failed, change nothing further, and stop without opening a pull request.

4. If `git status` shows no change, stop. Otherwise create the branch `promote/production` from
   the checked-out main, commit everything as one signed-off commit (`git commit -s`) with the
   message `chore(production): promote staging to production`, and push it with
   `git push --force-with-lease origin promote/production`. The branch name is fixed, so a run
   replaces the previous week's branch and the open pull request follows it. If the push is
   rejected, someone changed the branch since the last run: stop and report it, and do not
   force the push. Then run `gh pr list --head promote/production --base main --state open`.
   If it lists a pull request, update its title and body with `gh pr edit`; otherwise open one
   with `gh pr create --base main --head promote/production`. Never open a second pull request
   from that branch. Title `chore(production): promote staging to production (YYYY-MM-DD)` with
   today's date. Write the body in plain English: one short line per version
   change with the old and the new value, one short paragraph per folded override that names
   the app, what moved into base, and the commit that put it into staging (`git log` on the
   deleted staging file), and one line per pin you left alone and why. Do not mention the
   tooling or the model in the commit message or the body.

Rules. Keep the YAML style of the files you edit: no anchors, comments only where they explain
a constraint, and no rewriting of lines you do not need to change. Do not create files outside
kubernetes/apps. Do not run anything that reaches a cluster.
