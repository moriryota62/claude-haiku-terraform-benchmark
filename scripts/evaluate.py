#!/usr/bin/env python3
"""生成されたTerraformコードを客観的指標で採点するスクリプト。"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GENERATED_DIR = ROOT / "generated"
RESULTS_DIR = ROOT / "results"
REQS_PATH = ROOT / "scripts" / "task_requirements.json"
TFLINT_BIN = str(Path.home() / ".local" / "bin" / "tflint")
CHECKOV_BIN = str(Path.home() / "Library" / "Python" / "3.9" / "bin" / "checkov")


def run(cmd, cwd):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=120)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"
    except FileNotFoundError as e:
        return -2, "", str(e)


def terraform_fmt_check(dir_path):
    code, out, err = run(["terraform", "fmt", "-check", "-diff", "-no-color"], dir_path)
    return {"passed": code == 0, "diff": out, "error": err if code not in (0, 3) else ""}


def terraform_init_validate(dir_path):
    init_code, init_out, init_err = run(["terraform", "init", "-backend=false", "-input=false", "-no-color"], dir_path)
    if init_code != 0:
        return {"init_passed": False, "init_error": init_err or init_out, "validate_passed": False, "validate_error": ""}

    code, out, err = run(["terraform", "validate", "-json", "-no-color"], dir_path)
    try:
        result = json.loads(out)
        valid = result.get("valid", False)
        diag_count = len(result.get("diagnostics", []))
        diag_summary = "; ".join(
            d.get("summary", "") for d in result.get("diagnostics", [])
        )
    except json.JSONDecodeError:
        valid = code == 0
        diag_count = 0 if valid else 1
        diag_summary = err or out

    return {
        "init_passed": True,
        "init_error": "",
        "validate_passed": valid,
        "validate_error": diag_summary,
        "diagnostics_count": diag_count,
    }


def run_tflint(dir_path):
    init_code, _, _ = run([TFLINT_BIN, "--init"], dir_path)
    code, out, err = run([TFLINT_BIN, "--format", "json"], dir_path)
    try:
        result = json.loads(out)
        issues = result.get("issues", [])
        errors = result.get("errors", [])
    except json.JSONDecodeError:
        issues, errors = [], [{"message": err or out}]
    by_severity = {}
    for issue in issues:
        sev = issue.get("rule", {}).get("severity", "unknown")
        by_severity[sev] = by_severity.get(sev, 0) + 1
    return {
        "issue_count": len(issues),
        "by_severity": by_severity,
        "tool_errors": len(errors),
        "issues": [
            {"rule": i.get("rule", {}).get("name"), "message": i.get("message")}
            for i in issues
        ],
    }


def run_checkov(dir_path):
    code, out, err = run(
        [CHECKOV_BIN, "-d", ".", "--framework", "terraform", "--compact", "--output", "json"],
        dir_path,
    )
    try:
        result = json.loads(out)
        if isinstance(result, list):
            result = result[0] if result else {}
        summary = result.get("summary", {})
        failed_checks = result.get("results", {}).get("failed_checks", [])
    except (json.JSONDecodeError, IndexError):
        return {"passed": 0, "failed": 0, "error": err or "checkov parse error"}
    return {
        "passed": summary.get("passed", 0),
        "failed": summary.get("failed", 0),
        "skipped": summary.get("skipped", 0),
        "failed_checks": [
            {"check_id": c.get("check_id"), "check_name": c.get("check_name"), "resource": c.get("resource")}
            for c in failed_checks
        ],
    }


def check_requirements(dir_path, task_name, requirements):
    all_text = ""
    for tf_file in dir_path.glob("*.tf"):
        all_text += tf_file.read_text() + "\n"

    results = []
    for req in requirements:
        matched = bool(re.search(req["pattern"], all_text, re.IGNORECASE))
        results.append({"name": req["name"], "matched": matched})
    met = sum(1 for r in results if r["matched"])
    return {"met": met, "total": len(results), "details": results}


INGRESS_BLOCK_RE = re.compile(r"ingress\s*\{(?P<body>[^{}]*)\}", re.DOTALL)
SG_RULE_22_RE = re.compile(
    r'resource\s+"aws_(vpc_)?security_group(_ingress_rule)?"[^{]*\{(?P<body>.*?)\n\}',
    re.DOTALL,
)


def check_security_antipatterns(dir_path):
    all_text = ""
    for tf_file in dir_path.glob("*.tf"):
        all_text += tf_file.read_text() + "\n"

    findings = []

    # ingressブロック単位でSSH(22番)が0.0.0.0/0に開放されていないか確認
    open_ssh = False
    for block in INGRESS_BLOCK_RE.finditer(all_text):
        body = block.group("body")
        has_22 = re.search(r"from_port\s*=\s*22\b", body)
        has_open_cidr = re.search(r'cidr_blocks\s*=\s*\[\s*"0\.0\.0\.0/0"\s*\]', body)
        if has_22 and has_open_cidr:
            open_ssh = True
    # aws_vpc_security_group_ingress_rule(個別リソース)形式にも対応
    for block in SG_RULE_22_RE.finditer(all_text):
        body = block.group("body")
        has_22 = re.search(r"from_port\s*=\s*22\b", body)
        has_open_cidr = re.search(r'cidr_ipv4\s*=\s*"0\.0\.0\.0/0"', body)
        if has_22 and has_open_cidr:
            open_ssh = True
    if open_ssh:
        findings.append("SSHが0.0.0.0/0に開放されている可能性")

    if re.search(r'(password|secret)\s*=\s*"[^"$]{4,}"', all_text, re.IGNORECASE):
        findings.append("パスワード/シークレットがハードコードされている可能性")
    return findings


VAR_BLOCK_RE = re.compile(r'variable\s+"([^"]+)"\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}', re.DOTALL)
OUTPUT_BLOCK_RE = re.compile(r'output\s+"([^"]+)"\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}', re.DOTALL)
RESOURCE_RE = re.compile(r'resource\s+"(\w+)"\s+"([^"]+)"')
RESOURCE_BLOCK_RE = re.compile(r'resource\s+"(\w+)"\s+"([^"]+)"\s*\{(?P<body>.*?)\n\}', re.DOTALL)
IDENTIFIER_RE = re.compile(r"^[a-z0-9_]+$")
COUNT_ASSIGN_RE = re.compile(r"^\s*count\s*=", re.MULTILINE)


def check_coding_convention(dir_path):
    """命名規則・variable/outputの記述方法など、機械的に判定可能なコーディング規約への準拠を見る。"""
    all_text = ""
    for tf_file in dir_path.glob("*.tf"):
        all_text += tf_file.read_text() + "\n"

    checks = []

    var_names = VAR_BLOCK_RE.findall(all_text)
    for name, body in var_names:
        checks.append({"name": f'variable "{name}" に type がある', "passed": "type" in body})
        checks.append({"name": f'variable "{name}" に description がある', "passed": "description" in body})
        checks.append({"name": f'variable "{name}" はsnake_case', "passed": bool(IDENTIFIER_RE.match(name))})

    for name, body in OUTPUT_BLOCK_RE.findall(all_text):
        checks.append({"name": f'output "{name}" に description がある', "passed": "description" in body})

    by_type = {}
    for rtype, rname in RESOURCE_RE.findall(all_text):
        checks.append({"name": f'resource "{rtype}.{rname}" はsnake_case', "passed": bool(IDENTIFIER_RE.match(rname))})
        type_suffix = rtype.split("_", 1)[1] if "_" in rtype else rtype
        checks.append({
            "name": f'resource "{rtype}.{rname}" はリソースタイプ名を繰り返していない',
            "passed": rname != type_suffix,
        })
        by_type.setdefault(rtype, []).append(rname)
    for rtype, names in by_type.items():
        if len(names) > 1:
            checks.append({
                "name": f'"{rtype}" が複数ある場合に "this" を使っていない',
                "passed": "this" not in names,
            })

    for rtype, rname, body in RESOURCE_BLOCK_RE.findall(all_text):
        if COUNT_ASSIGN_RE.search(body):
            checks.append({
                "name": f'resource "{rtype}.{rname}" はcountではなくfor_eachを使っている',
                "passed": False,
            })

    passed = sum(1 for c in checks if c["passed"])
    total = len(checks)
    violations = [c["name"] for c in checks if not c["passed"]]
    return {"passed": passed, "total": total, "violations": violations}


def count_lines_and_files(dir_path):
    tf_files = list(dir_path.glob("*.tf"))
    total_lines = sum(len(f.read_text().splitlines()) for f in tf_files)
    return {"file_count": len(tf_files), "total_lines": total_lines, "files": [f.name for f in tf_files]}


def main():
    requirements_map = json.loads(REQS_PATH.read_text())
    all_results = {}

    for model_dir in sorted(GENERATED_DIR.iterdir()):
        if not model_dir.is_dir():
            continue
        model_name = model_dir.name
        all_results[model_name] = {}

        for task_dir in sorted(model_dir.iterdir()):
            if not task_dir.is_dir():
                continue
            task_name = task_dir.name
            print(f"[evaluate] model={model_name} task={task_name}", file=sys.stderr)

            if not list(task_dir.glob("*.tf")):
                all_results[model_name][task_name] = {"error": "no .tf files generated"}
                continue

            result = {
                "structure": count_lines_and_files(task_dir),
                "fmt": terraform_fmt_check(task_dir),
                "validate": terraform_init_validate(task_dir),
                "tflint": run_tflint(task_dir),
                "checkov": run_checkov(task_dir),
                "requirements": check_requirements(task_dir, task_name, requirements_map.get(task_name, [])),
                "security_antipatterns": check_security_antipatterns(task_dir),
                "coding_convention": check_coding_convention(task_dir),
            }
            all_results[model_name][task_name] = result

    RESULTS_DIR.mkdir(exist_ok=True)
    out_path = RESULTS_DIR / "raw_results.json"
    out_path.write_text(json.dumps(all_results, ensure_ascii=False, indent=2))
    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
