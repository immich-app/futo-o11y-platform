---
name: promote
description: Promote one environment to the next in a Flux monorepo with a shared base and one overlay folder per environment - fold dated source overrides into base, set every target pin to the base value, validate, and open one pull request
---

You promote changes from a source environment to a target environment in a Flux repository that
keeps a shared base and one overlay folder per environment. The invocation names the source and
the target environment, the manifest root (the folder that holds base and the overlays), the
commands that validate and format the manifests, and any pins to skip. If something is not
named, find it in the tree before you change anything: the base folder is the one every overlay
refers to, and an overlay folder is named after its environment. Change files only under the
manifest root. Open at most one pull request. Do not merge anything.

How the layout works. Base holds the definition of every app, and every environment runs it.
An overlay changes an app only where that environment must differ: with a kustomize patch, with
a Flux Kustomization patch that carries inner documents as literal blocks, or with an override
document composed on top of base. Whatever the form, an override names the kind and the name of
the resource it changes and sets only the fields that differ. The base counterpart of an
override is the base app it refers to, by the resource reference or by the app name in its path.
The source environment normally runs base as it is; the target environment pins the versions
that base moves ahead of it.

Do these steps in order.

1. Fold source overrides into base. A source override is a candidate only if its header carries
   a comment of the form `# promote-after: YYYY-MM-DD` with a date on or before today. Overrides
   without that comment are permanent differences between the environments. Never touch them.
   For each candidate, take every document it sets and merge the fields into the base manifest
   of that resource, in the place where those fields belong, and carry over the rationale
   comments. Never edit the Flux Kustomization that deploys the app. Then delete the override
   and its entry in the overlay's kustomization. If a target override now sets a field to the
   same value as base, remove that field; remove the whole document when nothing is left in it,
   and the override and its kustomization entry when no document is left. Version pins stay in
   the target. Do this step first, so that a folded version change reaches the target in step 2.

2. Promote versions. A version pin in the target is a `# renovate:` comment followed by the
   pinned line or lines: `tag:` plus `digest:`, `tag: <version>@sha256:...`, `image:` or
   `imageName:` with `<repository>:<version>@sha256:...`, or `version:`. For each pin, find the
   same dependency in the base app: the chart source whose url ends in the depName, the line
   under the `# renovate:` comment with the same depName, or the `repository:` plus `tag:` pair
   of that image in the chart values. Set the target value to the base value, the tag and the
   digest together. If the base counterpart is missing or more than one line matches, do not
   guess: leave that pin alone and say so in the pull request body. Skip every pin the
   invocation tells you to skip, because it moves together with files outside the overlays.
   Change nothing else in the target, and never edit a `# renovate:` comment.

3. Verify. Run the formatter on the files you changed, then the validation commands. Then check
   `git status`: every changed file must be under the manifest root; every changed or deleted
   source override must carry the marker with a date on or before today in its version on the
   default branch (read it with `git show <default branch>:<path>`, so that a marker added
   during this run does not count); and an overlay kustomization may change only by losing the
   entries of those overrides; and no file under the target overlay may change except a version
   pin and a document a fold made redundant. If validation fails or the check fails, print what failed, change
   nothing further, and stop without opening a pull request.

4. If `git status` shows no change, stop. Otherwise create the branch `promote/<target>` from the
   checked-out default branch, commit everything as one signed-off commit (`git commit -s`) with
   the message `chore(<target>): promote <source> to <target>`, and push it with
   `git push --force-with-lease origin promote/<target>`. The branch name is fixed, so a run
   replaces the previous run's branch and the open pull request follows it. If the push is
   rejected, someone changed the branch since the last run: stop and report it, and do not force
   the push. Then run
   `gh pr list --head promote/<target> --base <default branch> --state open --json number,isCrossRepository`
   and keep only the entry whose `isCrossRepository` is false, so that a same-named branch in a
   fork is never picked. If there is one, update its title and body with `gh pr edit <number>`;
   otherwise open one with `gh pr create --base <default branch> --head promote/<target>`. There
   is at most one open promotion pull request; a closed and unmerged one is replaced by a new
   one. Title `chore(<target>): promote <source> to <target> (YYYY-MM-DD)` with today's date.
   Write the body in plain English: one short line per version change with the old and the new
   value, one short paragraph per folded override that names the app, what moved into base, and
   the commit that put it into the source overlay (`git log` on the deleted file), and one line
   per pin you left alone and why. Do not mention the tooling or the model in the commit message
   or the body.

Rules. Keep the style of the files you edit: no YAML anchors, comments only where they explain a
constraint, and no rewriting of lines you do not need to change. Do not create files outside the
manifest root. Do not run anything that reaches a cluster.
