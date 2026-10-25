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
| 2026-10-25T09:17:09Z | refs/stash/chump/credible-1496-fleet-1-20261016-122858 | chump/credible-1496-fleet-1-20261016-122858 | 2c3517910a8ac6f8059e85f0e511dd3006eaa72c | 7 |
| 2026-10-25T09:17:15Z | refs/stash/chump/product-382-fleet-1-20261015-233258 | chump/product-382-fleet-1-20261015-233258 | 9cef456be3b3dc2b6d8bd5cfd283a5e35f064fd5 | 7 |
| 2026-10-25T09:17:20Z | refs/stash/chump/resilient-1611-fleet-1-20261017-103345 | chump/resilient-1611-fleet-1-20261017-103345 | 8fd1ea0336fcdce69c3c67fb07dcec0317059ede | 7 |
| 2026-10-25T09:17:25Z | refs/stash/chump/resilient-1611-fleet-1-20261017-111646 | chump/resilient-1611-fleet-1-20261017-111646 | f27ffc9313d1e6237da649d623e73aaaa95a600d | 7 |
| 2026-10-25T09:17:30Z | refs/stash/chump/resilient-1614-fleet-1-20261017-123656 | chump/resilient-1614-fleet-1-20261017-123656 | e779d786e695fb8814769e5791d6b575f0875f94 | 7 |
| 2026-10-25T09:17:36Z | refs/stash/chump/resilient-1614-fleet-1-20261017-140520 | chump/resilient-1614-fleet-1-20261017-140520 | 885107190d380882ff8828bb9969609f6b4a74d2 | 7 |
| 2026-10-25T09:18:04Z | refs/stash/chump/zero-waste-135-fleet-1-20261017-160531 | chump/zero-waste-135-fleet-1-20261017-160531 | 36e0627e2edb5d636266451ed647a061186f2b81 | 7 |
| 2026-10-25T09:18:09Z | refs/stash/chump/zero-waste-135-fleet-1-20261017-172127 | chump/zero-waste-135-fleet-1-20261017-172127 | 1519417631c1c0b502316df8e208d1f5ee490f8f | 7 |
| 2026-10-25T09:18:14Z | refs/stash/claude/credible-1493 | claude/credible-1493 | fa435df07c27a4b09ffae5d7a87b73c0ae1dbba1 | 7 |
| 2026-10-25T09:18:19Z | refs/stash/claude/credible-1509-mac | claude/credible-1509-mac | 6a3279421d28ae9f069d16031dce957805730125 | 7 |
| 2026-10-25T09:18:24Z | refs/stash/claude/credible-1510 | claude/credible-1510 | ee6425fcd075c6ac43cd6c2c2c2e0d37851be3c6 | 7 |
| 2026-10-25T09:18:30Z | refs/stash/claude/credible-1511-fix | claude/credible-1511-fix | 5d28ac84843ce90f0b07975e5673ca889a760333 | 7 |
| 2026-10-25T09:18:35Z | refs/stash/claude/credible-1513 | claude/credible-1513 | 322c9ecec30bca81ffbd2b37babd49b58d8f2e6c | 7 |
| 2026-10-25T09:18:40Z | refs/stash/claude/credible-1514 | claude/credible-1514 | 64a8a63619da89b236be746ae39e7d45ff4a294b | 7 |
| 2026-10-25T09:19:07Z | refs/stash/claude/infra-8176 | claude/infra-8176 | 56a484e0f1154a5e72a23f3d9424be3053c6603c | 7 |
| 2026-10-25T09:19:13Z | refs/stash/claude/infra-8193 | claude/infra-8193 | 0cd7074efef2c1050ef0bce6cdae84081255367d | 7 |
| 2026-10-25T09:19:18Z | refs/stash/claude/infra-8194 | claude/infra-8194 | 155f3156a0cbd3b04ebf4d2dc03729f4ce9fba8e | 7 |
| 2026-10-25T09:19:24Z | refs/stash/claude/infra-8199 | claude/infra-8199 | 4bf69f4b3d990e526e6d0d376722e692d87b4ffb | 7 |
| 2026-10-25T09:19:29Z | refs/stash/claude/infra-8211 | claude/infra-8211 | cadde69855f56662d85ce247e88e0f297b27414a | 7 |
| 2026-10-25T09:19:35Z | refs/stash/claude/infra-8223 | claude/infra-8223 | f8f6b193933005c1fd3a0e7fb68c5e40880fcdc7 | 7 |
| 2026-10-25T09:19:40Z | refs/stash/claude/resilient-1606 | claude/resilient-1606 | b4f0affa8409c85f0e0ebc185a0cdd17fd514aad | 7 |
| 2026-10-25T09:20:05Z | refs/stash/claude/resilient-1609 | claude/resilient-1609 | 12b44432da6dd00b793afba44ed2327c3ca89b93 | 7 |
| 2026-10-25T09:20:11Z | refs/stash/claude/zero-waste-134 | claude/zero-waste-134 | 7e760978bb01f5faf31f5ba2a44a02faaa085470 | 7 |
| 2026-10-25T09:20:16Z | refs/stash/claude/zero-waste-135 | claude/zero-waste-135 | d67842626bd3b3c099f89897a53fadb8eecb8cb4 | 7 |
