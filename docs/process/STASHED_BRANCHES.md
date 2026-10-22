# Stashed branches manifest

Machine-appended by `scripts/coord/orphan-branch-sweeper.sh` (ZERO-WASTE-136).
Each row is an unmerged branch whose tip was pushed to a durable
`refs/stash/<branch>` ref on origin before the branch was deleted.
Resume one: `git fetch origin 'refs/stash/*:refs/stash/*'` then
`git checkout -b resume/<name> refs/stash/<branch>`. See
docs/process/STASHED_WORK.md.

| stashed_at | stash_ref | branch | sha | last_commit_days |
|---|---|---|---|---|
| 2026-10-22T09:17:43Z | refs/stash/chump/resilient-490-fleet-1-20261014-132820 | chump/resilient-490-fleet-1-20261014-132820 | dd816aae147b40b7f9e7c145f4818d1317980b7b | 7 |
| 2026-10-22T09:18:03Z | refs/stash/chump/resilient-1354-fleet-1-20261015-013931 | chump/resilient-1354-fleet-1-20261015-013931 | 2662906a2110b4e0aae0748855f786f390017dde | 7 |
| 2026-10-22T09:18:09Z | refs/stash/chump/resilient-1357-fleet-1-20261015-053511 | chump/resilient-1357-fleet-1-20261015-053511 | a5cc5241ecff07f8648753fa6891d3c3d2c149c9 | 7 |
| 2026-10-22T09:18:15Z | refs/stash/chump/resilient-1359-fleet-1-20261015-060621 | chump/resilient-1359-fleet-1-20261015-060621 | 2f63725f697350149f68988bd64a8e7d57768f7a | 7 |
| 2026-10-22T09:18:20Z | refs/stash/chump/resilient-1359-fleet-1-20261015-071151 | chump/resilient-1359-fleet-1-20261015-071151 | 12e62252da9c9965f7fa69f015efb353cfc371d5 | 7 |
| 2026-10-22T09:18:28Z | refs/stash/chump/resilient-1383-fleet-1-20261014-202207 | chump/resilient-1383-fleet-1-20261014-202207 | e7c6a3fdafb0ff33e8fb13934da33cb0756279d6 | 7 |
