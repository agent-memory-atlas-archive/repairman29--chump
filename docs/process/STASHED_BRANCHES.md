# Stashed branches manifest

Machine-appended by `scripts/coord/orphan-branch-sweeper.sh` (ZERO-WASTE-136).
Each row is an unmerged branch whose tip was pushed to a durable
`refs/stash/<branch>` ref on origin before the branch was deleted.
Resume one: `git fetch origin 'refs/stash/*:refs/stash/*'` then
`git checkout -b resume/<name> refs/stash/<branch>`. See
docs/process/STASHED_WORK.md.

| stashed_at | stash_ref | branch | sha | last_commit_days |
|---|---|---|---|---|
