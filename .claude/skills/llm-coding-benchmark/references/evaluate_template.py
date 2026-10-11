#!/usr/bin/env python3
"""
評価スクリプトのテンプレート(Terraform向け)。
対象言語・ドメインに応じてチェック関数を入れ替えて使う。
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GENERATED_DIR = ROOT / "generated"
RESULTS_DIR = ROOT / "results"
REQS_PATH = ROOT / "scripts" / "task_requirements.json"
# ユーザー権限で導入したバイナリのパス。brewで入れた場合はwhichで解決してよい
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
    init_code, init_out, init_err = run(
        ["terraform", "init", "-backend=false", "-input=false", "-no-color"], dir_path
    )
    if init_code != 0:
        return {"init_passed": False, "init_error": init_err or init_out, "validate_passed": False, "validate_error": ""}

    code, out, err = run(["terraform", "validate", "-json", "-no-color"], dir_path)
    try:
        result = json.loads(out)
        valid = result.get("valid", False)
        diag_summary = "; ".join(d.get("summary", "") for d in result.get("diagnostics", []))
    except json.JSONDecodeError:
        valid = code == 0
        diag_summary = err or out

    return {"init_passed": True, "init_error": "", "validate_passed": valid, "validate_error": diag_summary}


def run_tflint(dir_path):
    run([TFLINT_BIN, "--init"], dir_path)
    code, out, err = run([TFLINT_BIN, "--format", "json"], dir_path)
    try:
        result = json.loads(out)
        issues = result.get("issues", [])
    except json.JSONDecodeError:
        issues = []
    return {"issue_count": len(issues), "issues": issues}


def run_checkov(dir_path):
    code, out, err = run(
        [CHECKOV_BIN, "-d", ".", "--framework", "terraform", "--compact", "--output", "json"], dir_path
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
        "failed_checks": [{"check_id": c.get("check_id"), "check_name": c.get("check_name")} for c in failed_checks],
    }


def check_requirements(dir_path, requirements):
    """タスクごとに定義した必須要素の正規表現マッチで判定する。"""
    all_text = "".join(f.read_text() + "\n" for f in dir_path.glob("*.tf"))
    results = []
    for req in requirements:
        matched = bool(re.search(req["pattern"], all_text, re.IGNORECASE))
        results.append({"name": req["name"], "matched": matched})
    met = sum(1 for r in results if r["matched"])
    return {"met": met, "total": len(results), "details": results}


# コーディング規約チェックの例。snake_case命名、variable/outputのtype・description有無、
# 同一タイプ複数ある場合に"this"を使わないこと等。必要に応じて項目を追加・削除する。
VAR_BLOCK_RE = re.compile(r'variable\s+"([^"]+)"\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}', re.DOTALL)
OUTPUT_BLOCK_RE = re.compile(r'output\s+"([^"]+)"\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}', re.DOTALL)
RESOURCE_RE = re.compile(r'resource\s+"(\w+)"\s+"([^"]+)"')
IDENTIFIER_RE = re.compile(r"^[a-z0-9_]+$")


def check_coding_convention(dir_path):
    all_text = "".join(f.read_text() + "\n" for f in dir_path.glob("*.tf"))
    checks = []

    for name, body in VAR_BLOCK_RE.findall(all_text):
        checks.append({"name": f'variable "{name}" に type がある', "passed": "type" in body})
        checks.append({"name": f'variable "{name}" に description がある', "passed": "description" in body})
        checks.append({"name": f'variable "{name}" はsnake_case', "passed": bool(IDENTIFIER_RE.match(name))})

    for name, body in OUTPUT_BLOCK_RE.findall(all_text):
        checks.append({"name": f'output "{name}" に description がある', "passed": "description" in body})

    by_type = {}
    for rtype, rname in RESOURCE_RE.findall(all_text):
        checks.append({"name": f'resource "{rtype}.{rname}" はsnake_case', "passed": bool(IDENTIFIER_RE.match(rname))})
        by_type.setdefault(rtype, []).append(rname)
    for rtype, names in by_type.items():
        if len(names) > 1:
            checks.append({"name": f'"{rtype}" が複数ある場合に "this" を使っていない', "passed": "this" not in names})

    passed = sum(1 for c in checks if c["passed"])
    violations = [c["name"] for c in checks if not c["passed"]]
    return {"passed": passed, "total": len(checks), "violations": violations}


def check_security_antipatterns(dir_path):
    """複合条件はブロック単位でスコープを絞り、誤検知を避ける(references/evaluation_axes.md参照)。"""
    all_text = "".join(f.read_text() + "\n" for f in dir_path.glob("*.tf"))
    findings = []

    for block in re.finditer(r"ingress\s*\{(?P<body>[^{}]*)\}", all_text, re.DOTALL):
        body = block.group("body")
        has_22 = re.search(r"from_port\s*=\s*22\b", body)
        has_open_cidr = re.search(r'cidr_blocks\s*=\s*\[\s*"0\.0\.0\.0/0"\s*\]', body)
        if has_22 and has_open_cidr:
            findings.append("SSHが0.0.0.0/0に開放されている可能性")
            break

    if re.search(r'(password|secret)\s*=\s*"[^"$]{4,}"', all_text, re.IGNORECASE):
        findings.append("パスワード/シークレットがハードコードされている可能性")
    return findings


def count_lines_and_files(dir_path):
    tf_files = list(dir_path.glob("*.tf"))
    return {"file_count": len(tf_files), "total_lines": sum(len(f.read_text().splitlines()) for f in tf_files)}


def main():
    requirements_map = json.loads(REQS_PATH.read_text()) if REQS_PATH.exists() else {}
    all_results = {}

    for model_dir in sorted(GENERATED_DIR.iterdir()):
        if not model_dir.is_dir():
            continue
        all_results[model_dir.name] = {}
        for task_dir in sorted(model_dir.iterdir()):
            if not task_dir.is_dir():
                continue
            task_name = task_dir.name
            print(f"[evaluate] model={model_dir.name} task={task_name}", file=sys.stderr)
            if not list(task_dir.glob("*.tf")):
                all_results[model_dir.name][task_name] = {"error": "no .tf files generated"}
                continue

            all_results[model_dir.name][task_name] = {
                "structure": count_lines_and_files(task_dir),
                "fmt": terraform_fmt_check(task_dir),
                "validate": terraform_init_validate(task_dir),
                "tflint": run_tflint(task_dir),
                "checkov": run_checkov(task_dir),
                "requirements": check_requirements(task_dir, requirements_map.get(task_name, [])),
                "security_antipatterns": check_security_antipatterns(task_dir),
                "coding_convention": check_coding_convention(task_dir),
            }

    RESULTS_DIR.mkdir(exist_ok=True)
    (RESULTS_DIR / "raw_results.json").write_text(json.dumps(all_results, ensure_ascii=False, indent=2))
    print(f"Wrote {RESULTS_DIR / 'raw_results.json'}", file=sys.stderr)


if __name__ == "__main__":
    main()
