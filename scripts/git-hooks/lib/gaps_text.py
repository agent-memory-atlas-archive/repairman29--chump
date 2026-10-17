"""Batched reader for the per-file docs/gaps/*.yaml layout (INFRA-8211).

The pre-commit gap guards need the whole gap tree as one monolithic YAML
string at two refs (the staged index and a base ref) so they can diff
title/description/status across the set. The historical implementation
listed every gap file and then ran one `git show <ref>:<path>` subprocess
PER FILE — 4,000+ process spawns per call, several calls per commit, which
made every commit take minutes on a 4-core node.

This module keeps the exact same output contract but reads every blob with a
SINGLE `git cat-file --batch` process (whole-tree invariant → one process).
The file listing (`git ls-files --stage` for the index, `git ls-tree -r` for
a ref) already carries each blob's object id, so we feed raw OIDs to
cat-file and skip per-path tree resolution entirely. Output is byte-identical
to the old per-file loop (proven in
scripts/ci/test-pre-commit-gap-guard-perf.sh).

Callers run from the repo top (git invokes hooks there), the same cwd
contract the old relative `docs/gaps/` git calls already relied on.
"""

import subprocess


def _list_gap_blobs(ref=None):
    """Return ``[(path, oid), ...]`` for docs/gaps/*.yaml, sorted by path.

    ``ref=None`` reads the staged index (`git ls-files --stage`); otherwise
    the tree at ``ref`` (`git ls-tree -r`). Both carry the blob OID so the
    reader never has to resolve ``<ref>:<path>`` again.
    """
    if ref is None:
        cmd = ["git", "ls-files", "--stage", "--", "docs/gaps/"]
    else:
        cmd = ["git", "ls-tree", "-r", ref, "--", "docs/gaps/"]
    out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    rows = []
    for line in out.splitlines():
        meta, _, path = line.partition("\t")
        if not path.endswith(".yaml"):
            continue
        fields = meta.split()
        # ls-files --stage: "<mode> <oid> <stage>"; ls-tree: "<mode> <type> <oid>"
        oid = fields[1] if ref is None else fields[2]
        rows.append((path, oid))
    rows.sort()
    return rows


def _batch_read(oids):
    """Read many blobs by OID in one `git cat-file --batch`, in order.

    Returns a list of decoded contents matching ``oids``. Raises KeyError if
    any OID is missing, so callers fall back to the monolithic path exactly
    like a single failed `git show` did in the old per-file loop.
    """
    proc = subprocess.Popen(
        ["git", "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    out, _ = proc.communicate("".join(o + "\n" for o in oids).encode())

    contents = []
    i = 0
    for oid in oids:
        nl = out.find(b"\n", i)
        if nl == -1:
            raise KeyError(oid)
        header = out[i:nl].decode("utf-8", "replace")
        i = nl + 1
        toks = header.split(" ")
        # Present: "<oid> <type> <size>"; missing: "<oid> missing".
        if len(toks) < 3 or toks[-2] not in ("blob", "tree", "commit", "tag"):
            raise KeyError(oid)
        size = int(toks[-1])
        contents.append(out[i:i + size].decode("utf-8", "replace"))
        i += size + 1  # skip the trailing newline cat-file appends
    return contents


def gaps_text(ref=None):
    """Whole gap set at ``ref`` as one monolithic YAML string.

    Per-file layout preferred (``gaps:\\n`` + each file rstripped, joined by
    newlines, trailing newline); falls back to the legacy monolithic
    docs/gaps.yaml, then to "" — identical to the pre-INFRA-8211 behaviour.
    """
    prefix = f"{ref}:" if ref else ":"
    try:
        rows = _list_gap_blobs(ref)
        if rows:
            parts = [c.rstrip() for c in _batch_read([oid for _, oid in rows])]
            return "gaps:\n" + "\n".join(parts) + "\n"
    except Exception:
        pass
    try:
        return subprocess.check_output(
            ["git", "show", f"{prefix}docs/gaps.yaml"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except Exception:
        return ""
