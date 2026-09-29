#!/usr/bin/env python3
"""Run the `run:` steps of one job from a disabled GitHub Actions workflow, locally.

GitHub Actions is off for this org (owner directive 2026-09-29). The old
workflow YAML under ci/github-workflows-disabled/ stays the recipe; this
helper replays a job's shell steps on this host so the recipe cannot drift
from what ci/run-local.sh grades.

  python3 ci/wf-step.py <workflow.yml> <job> [--skip SUBSTR ...] [--list]

- `uses:` steps (checkout, setup-*) are skipped: the local checkout and the
  local toolchain stand in for them.
- Step `if:` — none/success()/always() run; failure()/cancelled() are skipped;
  any other condition (event/ref/matrix guards) is skipped and printed.
- A step whose `run:` text still holds a `${{ ... }}` expression is REFUSED
  (it needs event context or secrets; it belongs to the manual list).
- env values holding `${{ }}` take the same-named variable from the caller's
  environment, else empty. Secrets are never read or printed here.
- GITHUB_ENV / GITHUB_OUTPUT / GITHUB_STEP_SUMMARY / GITHUB_PATH are temp files;
  GITHUB_ENV and GITHUB_PATH writes carry into later steps like on a runner.
"""
import argparse, os, re, subprocess, sys, tempfile

try:
    import yaml
except ImportError:
    sys.exit("wf-step: python3 -m pip install pyyaml (PyYAML) is required")

EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workflow")
    ap.add_argument("job")
    ap.add_argument("--skip", action="append", default=[],
                    help="skip steps whose name contains this substring")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    wf = yaml.safe_load(open(a.workflow))
    job = (wf.get("jobs") or {}).get(a.job)
    if job is None:
        sys.exit(f"wf-step: no job {a.job!r} in {a.workflow}")

    def envmap(d):
        out = {}
        for k, v in (d or {}).items():
            v = "" if v is None else str(v)
            out[k] = os.environ.get(k, "") if EXPR.search(v) else v
        return out

    wd_default = (((job.get("defaults") or {}).get("run") or {}).get("working-directory")
                  or (((wf.get("defaults") or {}).get("run") or {}).get("working-directory")))
    base_env = dict(os.environ)
    base_env.update(envmap(wf.get("env")))
    base_env.update(envmap(job.get("env")))
    tmp = tempfile.mkdtemp(prefix="wfstep.")
    files = {n: os.path.join(tmp, n) for n in ("GITHUB_ENV", "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "GITHUB_PATH")}
    for p in files.values():
        open(p, "w").close()
    base_env.update(files)
    base_env.update({"GITHUB_WORKSPACE": root, "RUNNER_TEMP": tmp, "CI": "true", "LOCAL_CI": "1"})

    n_run = 0
    for i, st in enumerate(job.get("steps") or []):
        name = st.get("name") or (st.get("uses") or (st.get("run") or "").strip().splitlines()[0][:60])
        if "run" not in st:
            print(f"  [wf-step] skip uses: {st.get('uses')}")
            continue
        cond = str(st.get("if", "")).strip()
        if cond and not re.fullmatch(r"(\$\{\{\s*)?(success|always)\(\)(\s*\}\})?", cond):
            print(f"  [wf-step] skip (if: {cond}) {name}")
            continue
        if any(s in name for s in a.skip):
            print(f"  [wf-step] skip (--skip) {name}")
            continue
        if a.list:
            print(f"  step: {name}")
            continue
        run = st["run"]
        if EXPR.search(run):
            print(f"  [wf-step] REFUSED {name}: run text needs ${{{{ }}}} context (manual step)")
            return 3
        env = dict(base_env)
        env.update(envmap(st.get("env")))
        # GITHUB_ENV / GITHUB_PATH carry-over
        for line in open(files["GITHUB_ENV"]).read().splitlines():
            if "=" in line and "<<" not in line:
                k, v = line.split("=", 1)
                env[k] = v
        extra = [p for p in open(files["GITHUB_PATH"]).read().splitlines() if p]
        if extra:
            env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
        wd = os.path.join(root, st.get("working-directory") or wd_default or ".")
        shell = st.get("shell") or (job.get("defaults") or {}).get("run", {}).get("shell")
        argv = ["bash", "--noprofile", "--norc", "-eo", "pipefail"] if shell == "bash" else ["bash", "-e"]
        if shell and shell not in ("bash",) and not shell.startswith("bash"):
            if shell.startswith("python"):
                argv = ["python3"]
            elif shell == "sh":
                argv = ["sh", "-e"]
        sf = os.path.join(tmp, f"step{i}.sh")
        open(sf, "w").write(run)
        print(f"  [wf-step] >> {name}", flush=True)
        rc = subprocess.call(argv + [sf], cwd=wd, env=env)
        n_run += 1
        if rc != 0:
            print(f"  [wf-step] step FAILED rc={rc}: {name}", flush=True)
            return rc
    if not a.list and n_run == 0:
        print("  [wf-step] no runnable step in this job")
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
