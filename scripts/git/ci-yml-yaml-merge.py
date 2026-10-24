#!/usr/bin/env python3
"""ci-yml-yaml-merge.py — INFRA-1482 / CREDIBLE-1545 YAML-aware merge & step-retention guard.

Modes:
  1. 3-way merge fallback (called from merge-driver-ci-yml-add-row.sh):
       ci-yml-yaml-merge.py <ancestor> <ours> <theirs>
     Parses all three files as YAML, merges every shared job's `steps:` list
     keyed by step identifier (`name:` or `uses:` fallback), attaches leading
     comment blocks to the step they precede, merges non-step regions via
     `git merge-file` when `theirs` also edited nearby lines outside `steps:`,
     and verifies that EVERY step from both `ours` and `theirs` (unless deleted
     by the opposite side vs `ancestor`) is present in the merged output.
     Exits non-zero (refusing the merge) if ANY job cannot be merged or if any
     step from either side would be dropped.

  2. Post-merge step-retention verification (called by merge-driver-ci-yml-add-row.sh
     before any exit 0):
       ci-yml-yaml-merge.py --verify-merged <ancestor> <ours_orig> <theirs> <merged>
     Exits 0 iff <merged> is valid YAML, every job and step expected from
     both <ours_orig> and <theirs> is retained, and every step has a run:/uses:
     body.

  3. Structural step-retention check against origin/main (CREDIBLE-1545 AC2):
       ci-yml-yaml-merge.py --check-repo-step-retention <repo_root> [base_ref]
     Fails (exit 1) when `.github/workflows/ci.yml` on HEAD (or working tree)
     lacks any `(job, step_name)` present on `base_ref` (`origin/main`) that
     the branch did not intentionally delete in its own non-merge commits.
"""
import os
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit(1)


_BODY_RE = re.compile(r"(?m)^\s*(?:-\s+)?(run|uses):")
_COMMENT_OR_BLANK_RE = re.compile(r"^\s*(#.*)?$")


def has_body(raw_text):
    """INFRA-1199 guard: a step lacking 'run:'/'uses:' makes GitHub Actions
    reject the whole workflow file. Any step content this script introduces
    or changes must carry a body."""
    return bool(_BODY_RE.search(raw_text))


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    return text, text.splitlines(keepends=True)


def step_name(step_node):
    if not isinstance(step_node, yaml.MappingNode):
        return None
    for k, v in step_node.value:
        if (
            isinstance(k, yaml.ScalarNode)
            and k.value == "name"
            and isinstance(v, yaml.ScalarNode)
        ):
            return v.value
    # CREDIBLE-1545: nameless `- uses: actions/checkout@v7` steps are valid
    # GitHub Actions steps and appear as step 0 in fast-checks and other jobs.
    for k, v in step_node.value:
        if (
            isinstance(k, yaml.ScalarNode)
            and k.value == "uses"
            and isinstance(v, yaml.ScalarNode)
        ):
            return f"uses:{v.value}"
    return None


def extract_job_steps(text):
    """job_name -> {'steps': [(name, raw)...], 'start': int, 'end': int} (0-indexed line range)."""
    try:
        root = yaml.compose(text, Loader=yaml.SafeLoader)
    except yaml.YAMLError:
        return None
    if root is None or not isinstance(root, yaml.MappingNode):
        return {}
    lines = text.splitlines(keepends=True)
    jobs = {}
    for k, v in root.value:
        if not (isinstance(k, yaml.ScalarNode) and k.value == "jobs"):
            continue
        if not isinstance(v, yaml.MappingNode):
            continue
        for job_key, job_val in v.value:
            if not isinstance(job_val, yaml.MappingNode):
                continue
            steps_seq = None
            steps_key_line = None
            for jk, jv in job_val.value:
                if (
                    isinstance(jk, yaml.ScalarNode)
                    and jk.value == "steps"
                    and isinstance(jv, yaml.SequenceNode)
                ):
                    steps_seq = jv
                    steps_key_line = jk.start_mark.line
            if steps_seq is None or not steps_seq.value:
                continue
            items = steps_seq.value
            # CREDIBLE-1545: attach contiguous leading comment/blank lines
            # directly above each `- name:` / `- uses:` step to the step they
            # precede, rather than to the tail of the previous step.
            step_starts = []
            for i, item in enumerate(items):
                min_line = (
                    (steps_key_line + 1)
                    if i == 0
                    else (items[i - 1].start_mark.line + 1)
                )
                s_line = item.start_mark.line
                while s_line > min_line and _COMMENT_OR_BLANK_RE.match(
                    lines[s_line - 1]
                ):
                    s_line -= 1
                step_starts.append(s_line)

            steps = []
            for i, item in enumerate(items):
                start = step_starts[i]
                end = (
                    step_starts[i + 1]
                    if i + 1 < len(items)
                    else steps_seq.end_mark.line
                )
                raw = "".join(lines[start:end])
                steps.append((step_name(item), raw))
            jobs[job_key.value] = {
                "steps": steps,
                "start": step_starts[0],
                "end": steps_seq.end_mark.line,
            }
    return jobs


def merge_job_steps(base_steps, ours_steps, theirs_steps):
    """Returns merged raw text for the job's steps block, or None on conflict."""
    base_by_name = {n: r for n, r in base_steps if n is not None}
    base_order = [n for n, _ in base_steps if n is not None]
    ours_by_name = {n: r for n, r in ours_steps if n is not None}
    theirs_by_name = {n: r for n, r in theirs_steps if n is not None}

    # Anything without a unique step identifier makes this job unsafe to merge.
    if len(base_by_name) != len(base_steps):
        return None
    if len(ours_by_name) != len(ours_steps) or len(theirs_by_name) != len(theirs_steps):
        return None

    def anchor_new(step_list, base_names):
        """name -> anchor (preceding base step name, or None for <start>), in encounter order."""
        anchors = {}
        order = []
        current_anchor = None
        for name, raw in step_list:
            if name in base_names:
                current_anchor = name
                continue
            if name not in anchors:
                anchors[name] = (current_anchor, raw)
                order.append(name)
        return anchors, order

    base_name_set = set(base_order)
    ours_anchors, ours_new_order = anchor_new(ours_steps, base_name_set)
    theirs_anchors, theirs_new_order = anchor_new(theirs_steps, base_name_set)

    # A step added by BOTH sides with the same name: fine if identical text,
    # otherwise a genuine conflict (can't tell which is intended).
    for name in set(ours_new_order) & set(theirs_new_order):
        if ours_anchors[name][1] != theirs_anchors[name][1]:
            return None

    # INFRA-1199: refuse to write any added step that lacks a run:/uses: body
    # (an orphan '- name:' step is invalid GitHub Actions YAML).
    for name in ours_new_order:
        if not has_body(ours_anchors[name][1]):
            return None
    for name in theirs_new_order:
        if not has_body(theirs_anchors[name][1]):
            return None

    def emit_new_for_anchor(anchor, seen):
        out = []
        for name in ours_new_order:
            if ours_anchors[name][0] == anchor and name not in seen:
                out.append(ours_anchors[name][1])
                seen.add(name)
        for name in theirs_new_order:
            if theirs_anchors[name][0] == anchor and name not in seen:
                out.append(theirs_anchors[name][1])
                seen.add(name)
        return out

    result = []
    seen = set()
    result.extend(emit_new_for_anchor(None, seen))

    for name in base_order:
        base_raw = base_by_name[name]
        ours_has = name in ours_by_name
        theirs_has = name in theirs_by_name
        if not ours_has and not theirs_has:
            # Both sides made this base step disappear -- could be a genuine
            # shared deletion, could be both sides independently renaming it
            # (INFRA-1482 AC: "both rename -> keep conflict"). Ambiguous
            # either way; refuse rather than guess.
            return None
        if ours_has != theirs_has:
            # One side deleted/renamed it while the other kept or modified
            # it: a real deletion conflict, refuse.
            return None
        ours_raw = ours_by_name[name]
        theirs_raw = theirs_by_name[name]
        if ours_raw != theirs_raw:
            if ours_raw != base_raw and theirs_raw != base_raw:
                # Both sides modified the same base step differently: keep conflict.
                return None
            chosen = ours_raw if ours_raw != base_raw else theirs_raw
        else:
            chosen = ours_raw
        if chosen != base_raw and not has_body(chosen):
            return None  # INFRA-1199: modified step lost its run:/uses: body
        result.append(chosen)
        result.extend(emit_new_for_anchor(name, seen))

    return "".join(result)


def verify_merged_steps(ancestor_text, ours_text, theirs_text, merged_text):
    """CREDIBLE-1545 AC1: Returns True iff merged_text is valid YAML and retains
    every step from both ours_text and theirs_text (and has no step deletions)."""
    anc_jobs = extract_job_steps(ancestor_text)
    ours_jobs = extract_job_steps(ours_text)
    theirs_jobs = extract_job_steps(theirs_text)
    merged_jobs = extract_job_steps(merged_text)
    if (
        anc_jobs is None
        or ours_jobs is None
        or theirs_jobs is None
        or merged_jobs is None
    ):
        return False
    if not merged_jobs:
        return False
    expected_jobs = set(ours_jobs.keys()) | set(theirs_jobs.keys())
    if set(merged_jobs.keys()) != expected_jobs:
        return False
    for job in expected_jobs:
        anc_names = [n for n, _ in anc_jobs.get(job, {}).get("steps", [])]
        ours_list = ours_jobs.get(job, {}).get("steps", [])
        theirs_list = theirs_jobs.get(job, {}).get("steps", [])
        merged_list = merged_jobs.get(job, {}).get("steps", [])
        if any(n is None for n, _ in ours_list + theirs_list + merged_list):
            return False
        if any(not has_body(raw) for _, raw in merged_list):
            return False
        ours_names = {n for n, _ in ours_list}
        theirs_names = {n for n, _ in theirs_list}
        merged_names = {n for n, _ in merged_list}
        # Merge driver is add-only: any base step deleted on either side must
        # not be auto-merged by this driver.
        for n in anc_names:
            if n not in ours_names or n not in theirs_names:
                return False
        # Every step present on ours and every step present on theirs must
        # appear in the merged result.
        if not ours_names.issubset(merged_names):
            return False
        if not theirs_names.issubset(merged_names):
            return False
    return True


def _apply_splices(lines, jobs_dict, merged_by_job):
    out = list(lines)
    splices = [
        (jobs_dict[job]["start"], jobs_dict[job]["end"], merged_txt)
        for job, merged_txt in merged_by_job.items()
    ]
    splices.sort(key=lambda s: s[0], reverse=True)
    for start, end, replacement in splices:
        out[start:end] = [replacement]
    return "".join(out)


def extract_all_step_pairs(text):
    jobs = extract_job_steps(text)
    if jobs is None:
        return None
    pairs = set()
    for job, info in jobs.items():
        for name, _ in info["steps"]:
            if name is not None:
                pairs.add((job, name))
    return pairs


def _git_output(repo_root, args):
    res = subprocess.run(
        ["git", "-C", repo_root] + args,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if res.returncode != 0:
        return None
    return res.stdout


def check_repo_step_retention(repo_root, base_ref=None):
    """CREDIBLE-1545 AC2: Fail when .github/workflows/ci.yml on HEAD/worktree
    lacks any (job, step_name) present on base_ref (origin/main) that the PR
    did not intentionally delete in its own non-merge commits."""
    if not base_ref:
        base_ref = (
            os.environ.get("CHUMP_CI_STEP_RETENTION_BASE_REF")
            or os.environ.get("GITHUB_BASE_SHA")
            or ""
        )
    if not base_ref:
        if _git_output(repo_root, ["rev-parse", "--verify", "origin/main"]) is not None:
            base_ref = "origin/main"
        elif _git_output(repo_root, ["rev-parse", "--verify", "main"]) is not None:
            base_ref = "main"
        else:
            return 0

    base_ci = _git_output(repo_root, ["show", f"{base_ref}:.github/workflows/ci.yml"])
    if base_ci is None:
        return 0
    base_pairs = extract_all_step_pairs(base_ci)
    if base_pairs is None:
        return 0

    head_ref = os.environ.get("CHUMP_CI_STEP_RETENTION_HEAD_REF", "")
    ci_disk_path = os.path.join(repo_root, ".github", "workflows", "ci.yml")
    if head_ref:
        curr_ci = _git_output(repo_root, ["show", f"{head_ref}:.github/workflows/ci.yml"])
    elif os.path.isfile(ci_disk_path):
        with open(ci_disk_path, "r", encoding="utf-8") as f:
            curr_ci = f.read()
    else:
        curr_ci = _git_output(repo_root, ["show", "HEAD:.github/workflows/ci.yml"])

    if curr_ci is None:
        sys.stderr.write("[ci-step-retention] BLOCKED (CREDIBLE-1545): .github/workflows/ci.yml missing or unreadable.\n")
        return 1

    curr_pairs = extract_all_step_pairs(curr_ci)
    if curr_pairs is None:
        sys.stderr.write("[ci-step-retention] BLOCKED (CREDIBLE-1545): .github/workflows/ci.yml is not valid YAML.\n")
        return 1

    commit_ref = head_ref if head_ref else "HEAD"
    committed_head_ci = _git_output(
        repo_root, ["show", f"{commit_ref}:.github/workflows/ci.yml"]
    )
    if committed_head_ci is not None and not head_ref:
        committed_pairs = extract_all_step_pairs(committed_head_ci)
        if committed_pairs is not None:
            wt_dropped = sorted(committed_pairs - curr_pairs)
            if wt_dropped:
                sys.stderr.write(
                    "[ci-step-retention] BLOCKED (CREDIBLE-1545): working-tree .github/workflows/ci.yml drops step(s) present on HEAD:\n"
                )
                for job, step in wt_dropped:
                    sys.stderr.write(f"  - {job} :: {step}\n")
                return 1

    missing = base_pairs - curr_pairs
    if not missing:
        return 0

    # Check if the branch has not touched ci.yml since its merge-base with base_ref
    # (e.g. a non-ci.yml branch while origin/main advanced).
    mb_out = _git_output(repo_root, ["merge-base", commit_ref, base_ref])
    mb_sha = mb_out.strip() if mb_out else ""
    base_sha_out = _git_output(repo_root, ["rev-parse", base_ref])
    base_sha = base_sha_out.strip() if base_sha_out else ""
    if mb_sha and mb_sha != base_sha and committed_head_ci is not None:
        mb_ci = _git_output(repo_root, ["show", f"{mb_sha}:.github/workflows/ci.yml"])
        if mb_ci is not None and mb_ci == curr_ci:
            # Neither HEAD nor working tree changed ci.yml relative to merge-base.
            return 0

    # Compute steps intentionally deleted by the branch's own non-merge commits.
    intentionally_deleted = set()
    non_merge_out = _git_output(
        repo_root, ["rev-list", "--no-merges", f"{base_ref}..{commit_ref}"]
    )
    if non_merge_out:
        for sha in non_merge_out.splitlines():
            sha = sha.strip()
            if not sha:
                continue
            parent_ci = _git_output(
                repo_root, ["show", f"{sha}^:.github/workflows/ci.yml"]
            )
            child_ci = _git_output(
                repo_root, ["show", f"{sha}:.github/workflows/ci.yml"]
            )
            if parent_ci is None or child_ci is None:
                continue
            if parent_ci == child_ci:
                continue
            p_pairs = extract_all_step_pairs(parent_ci)
            c_pairs = extract_all_step_pairs(child_ci)
            if p_pairs is not None and c_pairs is not None:
                intentionally_deleted |= (p_pairs - c_pairs)

    unexplained = sorted(missing - intentionally_deleted)
    if unexplained:
        sys.stderr.write(
            f"[ci-step-retention] BLOCKED (CREDIBLE-1545): .github/workflows/ci.yml lacks {len(unexplained)} step(s) present on {base_ref} that were not deleted in the branch's own diff:\n"
        )
        for job, step in unexplained:
            sys.stderr.write(f"  - {job} :: {step}\n")
        return 1
    return 0


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--verify-merged":
        if len(sys.argv) != 6:
            sys.exit(1)
        anc_text, _ = read(sys.argv[2])
        ours_text, _ = read(sys.argv[3])
        theirs_text, _ = read(sys.argv[4])
        merged_text, _ = read(sys.argv[5])
        sys.exit(
            0 if verify_merged_steps(anc_text, ours_text, theirs_text, merged_text) else 1
        )

    if len(sys.argv) >= 2 and sys.argv[1] == "--check-repo-step-retention":
        repo_root = sys.argv[2] if len(sys.argv) >= 3 else os.getcwd()
        base_ref = sys.argv[3] if len(sys.argv) >= 4 else None
        sys.exit(check_repo_step_retention(repo_root, base_ref))

    if len(sys.argv) != 4:
        sys.exit(1)
    ancestor_path, ours_path, theirs_path = sys.argv[1:4]

    ancestor_text, ancestor_lines = read(ancestor_path)
    ours_text, ours_lines = read(ours_path)
    theirs_text, theirs_lines = read(theirs_path)

    ancestor_jobs = extract_job_steps(ancestor_text)
    ours_jobs = extract_job_steps(ours_text)
    theirs_jobs = extract_job_steps(theirs_text)
    if ancestor_jobs is None or ours_jobs is None or theirs_jobs is None:
        sys.exit(1)

    if not ancestor_jobs:
        sys.exit(1)
    # Refuse if jobs were added, deleted, or renamed on either side.
    if set(ancestor_jobs.keys()) != set(ours_jobs.keys()) or set(
        ancestor_jobs.keys()
    ) != set(theirs_jobs.keys()):
        sys.exit(1)

    merged_by_job = {}
    for job in ancestor_jobs:
        base_steps = ancestor_jobs[job]["steps"]
        ours_steps = ours_jobs[job]["steps"]
        theirs_steps = theirs_jobs[job]["steps"]
        if ours_steps == theirs_steps:
            continue
        merged = merge_job_steps(base_steps, ours_steps, theirs_steps)
        if merged is None:
            # CREDIBLE-1545 AC1: NEVER continue past an unmergeable job!
            # Continuing leaves `ours` in place for this job and silently drops
            # `theirs`'s new steps whenever another job in the file happened to
            # merge cleanly.
            sys.exit(1)
        merged_by_job[job] = merged

    ours_unified = _apply_splices(ours_lines, ours_jobs, merged_by_job)
    anc_unified = _apply_splices(ancestor_lines, ancestor_jobs, merged_by_job)
    theirs_unified = _apply_splices(theirs_lines, theirs_jobs, merged_by_job)

    if theirs_unified != anc_unified:
        # `theirs` also has edits outside `steps:` (e.g. a nearby comment).
        # Refuse if non-comment YAML lines outside `steps:` were modified by
        # theirs (INFRA-1205: path-filter / outputs: edits must not be spliced).
        def _non_comment_lines(lines_list):
            return [
                ln for ln in lines_list
                if ln.strip() and not ln.lstrip().startswith("#")
            ]
        anc_u_lines = anc_unified.splitlines(keepends=True)
        ours_u_lines = ours_unified.splitlines(keepends=True)
        theirs_u_lines = theirs_unified.splitlines(keepends=True)
        if _non_comment_lines(theirs_u_lines) != _non_comment_lines(anc_u_lines):
            sys.exit(1)
        line_merged = None
        if len(anc_u_lines) == len(ours_u_lines) == len(theirs_u_lines):
            merged_u = []
            conflict = False
            for a_ln, o_ln, t_ln in zip(anc_u_lines, ours_u_lines, theirs_u_lines):
                if o_ln == t_ln:
                    merged_u.append(o_ln)
                elif o_ln == a_ln:
                    merged_u.append(t_ln)
                elif t_ln == a_ln:
                    merged_u.append(o_ln)
                else:
                    conflict = True
                    break
            if not conflict:
                line_merged = "".join(merged_u)

        if line_merged is not None:
            final_text = line_merged
        else:
            with tempfile.TemporaryDirectory() as tmpdir:
                p_anc = os.path.join(tmpdir, "anc.yml")
                p_ours = os.path.join(tmpdir, "ours.yml")
                p_theirs = os.path.join(tmpdir, "theirs.yml")
                with open(p_anc, "w", encoding="utf-8") as f:
                    f.write(anc_unified)
                with open(p_ours, "w", encoding="utf-8") as f:
                    f.write(ours_unified)
                with open(p_theirs, "w", encoding="utf-8") as f:
                    f.write(theirs_unified)
                res = subprocess.run(
                    ["git", "merge-file", "-q", p_ours, p_anc, p_theirs],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                if res.returncode != 0:
                    sys.exit(1)
                with open(p_ours, "r", encoding="utf-8") as f:
                    final_text = f.read()
    else:
        # INFRA-1199 / validate_step_bodies: when theirs is identical to ancestor
        # outside steps: (no-op or step-only merge), ours_unified is the complete result.
        final_text = ours_unified

    if not verify_merged_steps(ancestor_text, ours_text, theirs_text, final_text):
        sys.exit(1)

    with open(ours_path, "w", encoding="utf-8") as f:
        f.write(final_text)
    sys.exit(0)


if __name__ == "__main__":
    main()
