---
name: promote
description: Promote one environment to the next in a Flux monorepo with a shared base and one overlay folder per environment - fold dated source overrides into base, set every target pin to the base value, validate, and open one pull request
argument-hint: source=<env> target=<env> root=<folder> validate="<command>; <command>" format=<command> skip=<depName>,<depName> body=<file>
arguments:
  - source
  - target
  - root
  - validate
  - format
  - skip
  - body
---

## Inputs

The invocation passes the inputs as `key=value` pairs. Quote a value that holds spaces.

- `source`: the environment to promote from, which normally runs base as it is.
- `target`: the environment to promote to, which pins the versions that base moves ahead of it.
- `root`: the manifest root, the folder that holds base and the overlays.
- `validate`: the commands that render or validate the Flux objects offline, separated by `;`.
  Optional. Without it, the CI of the pull request does the validation.
- `format`: the formatter to run on the files you changed.
- `skip`: dependency names whose pins you must not promote, because they move together with
  files outside the manifest root, separated by `,`. Optional.
- `body`: a file for the pull request body. Optional. With it, the caller publishes: you write the
  body there and leave the branch, the commit, the push and the pull request to the caller.

If `source`, `target` or `root` is missing, find it in the tree before you change anything: the
base folder is the one every overlay refers to, and an overlay folder is named after its
environment. If `format` is missing, use the formatter that the repository's own hooks or CI run.

## Procedure

Change files only under the manifest root, apart from the `body` file. Open at most one pull
request. Do not merge anything.

How the layout works. Base holds the definition of every app, and every environment runs it.
An overlay changes an app only where that environment must differ: with a kustomize patch, with
a Flux Kustomization patch that carries inner documents as literal blocks, or with an override
document composed on top of base. Whatever the form, an override names the kind and the name of
the resource it changes and sets only the fields that differ. The base counterpart of an
override is the base app it refers to, by the resource reference or by the app name in its path.

Do these steps in order.

1. Fold source overrides into base. A source override is a candidate only if its header carries
   a comment of the form `# promote-after: YYYY-MM-DD` with a date on or before today. Overrides
   without that comment are permanent differences between the environments. Never touch them.
   If a comment on an override says that the change belongs to one environment only, the
   override is permanent too, even with the marker. Leave it alone and name it in the pull
   request body. In the same way, an app that only one overlay lists stays out of the other
   overlays. For each candidate, take every document it sets and merge the fields into the base manifest
   of that resource, in the place where those fields belong, and carry over the rationale
   comments. Never edit the Flux Kustomization that deploys the app. Then delete the override
   and its entry in the overlay's kustomization. If a target override of a folded app now sets a
   field to the same value as base, remove that field. If no field is left in a document, remove
   the document. If no document is left, remove the override and its kustomization entry. Version
   pins stay in the target. A folded version change then reaches the target in step 2.

2. Promote versions. A version pin in the target is an override field that holds a version:
   `tag:` plus `digest:`, `tag: <version>@sha256:...`, `image:` or `imageName:` with
   `<repository>:<version>@sha256:...`, or `version:`. For each pin, find the same field of the
   same resource in the base app. Set the target value to the base value, the tag and the digest
   together. If the base counterpart is missing or more than one field matches, do not
   guess: leave that pin alone and say so in the pull request body. Skip every pin whose
   dependency is in `skip`. A `# renovate:` comment above a pin names its dependency.
   Change nothing else in the target, and never edit a `# renovate:` comment.

3. Verify. Run `format` on the files you changed. If `validate` is set, run each of its
   commands. Then check
   `git status`: every changed file must be under the manifest root; every changed or deleted
   source override must carry the marker with a date on or before today in its version on the
   default branch (read it with `git show <default branch>:<path>`, so that a marker added
   during this run does not count); an overlay kustomization may change only by losing the
   entries of those source overrides and of the target overrides that step 1 removed; and in the
   target overlay, only version pins change and only fields, documents and overrides that a fold
   made redundant go away. If validation fails or the check fails, print what failed, change nothing
   further, and stop without opening a pull request.

4. If `body` is set, write the pull request body that this step describes to that file, but only
   when `git status` shows a change. Then stop, and do not branch, commit, push or touch a pull
   request.

   Without `body`: if `git status` shows no change, find the open promotion pull request as
   described below. If there is one, close it with `gh pr close <number> --comment` and a comment
   that says the default branch has nothing left to promote. Then stop. Otherwise create the
   branch `promote/<target>` from the checked-out default branch, commit everything as one signed-off commit (`git commit -s`) with
   the message `chore(<target>): promote <source> to <target>`, and push it with
   `git push --force-with-lease origin promote/<target>`. The branch name is fixed, so a run
   replaces the previous run's branch and every commit on it, and the open pull request follows
   it. The lease only covers the time since your last fetch. If the push is rejected, the branch
   moved while you worked: stop and report it, and do not force the push. Then run
   `gh pr list --head promote/<target> --base <default branch> --state open --json number,isCrossRepository`
   and keep only the entry whose `isCrossRepository` is false, so that a same-named branch in a
   fork is never picked. If there is one, update its title and body with `gh pr edit <number>`;
   otherwise open one with `gh pr create --base <default branch> --head promote/<target>`. There
   is at most one open promotion pull request; a closed and unmerged one is replaced by a new
   one. Title `chore(<target>): promote <source> to <target> (YYYY-MM-DD)` with today's date.
   Write the body in plain English: one short line per version change with the old and the new
   value, one short paragraph per folded override that names the app, what moved into base, and
   the commit that put it into the source overlay (`git log` on the deleted file), and one line
   per pin or override you left alone and why. Do not mention the tooling or the model in the commit message
   or the body.

Rules. Keep the style of the files you edit: no YAML anchors, comments only where they explain a
constraint, and no rewriting of lines you do not need to change. Do not run anything that reaches
a cluster.
