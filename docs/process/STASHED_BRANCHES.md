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
| 2026-10-23T09:17:27Z | refs/stash/chump/product-378-fleet-1-20261015-223623 | chump/product-378-fleet-1-20261015-223623 | 6e61b5ee4b49aa4d61d0861ac30f46c24dd80f59 | 7 |
| 2026-10-23T09:17:33Z | refs/stash/chump/product-382-fleet-1-20261015-231048 | chump/product-382-fleet-1-20261015-231048 | 54f2bd049f142327cf234d62f753c72b5b486942 | 7 |
| 2026-10-23T09:17:42Z | refs/stash/chump/resilient-1142-fleet-1-20261013-135301 | chump/resilient-1142-fleet-1-20261013-135301 | 4f29e88ac9aaac4c83c97ae30b8f60468c4b3cc7 | 7 |
| 2026-10-23T09:18:08Z | refs/stash/chump/resilient-1374-fleet-1-20261014-180034 | chump/resilient-1374-fleet-1-20261014-180034 | 6be4b0a1d2481a4183491bd39f732872481d0768 | 7 |
| 2026-10-23T09:18:14Z | refs/stash/chump/resilient-1401-fleet-1-20261015-113438 | chump/resilient-1401-fleet-1-20261015-113438 | a2a8dfb5f21538441726784e6b7c8fa77e983c36 | 7 |
| 2026-10-23T09:18:23Z | refs/stash/chump/resilient-1429-fleet-1-20261015-135824 | chump/resilient-1429-fleet-1-20261015-135824 | a7057f331cf26e674bbbf51c06b421cb8bf43de0 | 7 |
| 2026-10-24T09:17:10Z | refs/stash/chump/credible-1495-fleet-1-20261016-015030 | chump/credible-1495-fleet-1-20261016-015030 | 003c46f9924a44fe231b747bc78d03d952e2c073 | 7 |
| 2026-10-24T09:17:16Z | refs/stash/chump/credible-1495-fleet-1-20261016-054951 | chump/credible-1495-fleet-1-20261016-054951 | cb43b0799c56038ff76fad7719e95ea326d599b0 | 7 |
| 2026-10-24T09:17:26Z | refs/stash/chump/credible-1498-fleet-1-20261016-131456 | chump/credible-1498-fleet-1-20261016-131456 | f1686d8d25fb4e8bec124e494d5146e2553bd440 | 7 |
| 2026-10-24T09:17:32Z | refs/stash/chump/credible-1498-fleet-1-20261016-153619 | chump/credible-1498-fleet-1-20261016-153619 | 1a6c7bf888b8c907a0c7cb9fa429c359cc8b254a | 7 |
| 2026-10-24T09:17:39Z | refs/stash/chump/credible-1499-fleet-1-20261016-155318 | chump/credible-1499-fleet-1-20261016-155318 | 7c03620f09fc6c21da7e79b592a23cb78bfac3f3 | 7 |
| 2026-10-24T09:17:45Z | refs/stash/chump/infra-8218-fleet-1-20261017-014652 | chump/infra-8218-fleet-1-20261017-014652 | dd3db9833d1cb766224cc59634fa5a7872d4d697 | 7 |
| 2026-10-24T09:18:07Z | refs/stash/chump/resilient-1427-fleet-1-20261015-133006 | chump/resilient-1427-fleet-1-20261015-133006 | 77f913179f648f6f29cf55931271f1ff65c541de | 7 |
| 2026-10-24T09:18:14Z | refs/stash/chump/resilient-1494-fleet-1-20261013-041926 | chump/resilient-1494-fleet-1-20261013-041926 | 482dbe456d929e277e389c51d5ef2a9b9844df50 | 7 |
