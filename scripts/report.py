#!/usr/bin/env python3
"""raw_results.json から比較レポート(Markdown)を生成する。"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS_DIR = ROOT / "results"

MODEL_LABELS = {
    "haiku-4-5": "Claude Haiku 4.5",
    "sonnet-5-5": "Claude Sonnet 5.5",
    "haiku-5-5": "Claude Haiku 5.5",
}
TASK_LABELS = {
    "task1_simple": "タスク1: シンプル (S3)",
    "task2_medium": "タスク2: 中程度 (VPC+EC2)",
    "task3_complex": "タスク3: 複雑 (ALB+ASG+RDS+IAM)",
}
MODEL_ORDER = ["haiku-4-5", "sonnet-5-5", "haiku-5-5"]
TASK_ORDER = ["task1_simple", "task2_medium", "task3_complex"]


def score_row(r):
    """100点満点の簡易スコア。fmt/validate/tflint/checkov/要件カバレッジを重み付け。"""
    if "error" in r:
        return 0.0
    score = 0.0
    score += 10 if r["fmt"]["passed"] else 0
    score += 25 if r["validate"]["validate_passed"] else 0
    tflint_penalty = min(r["tflint"]["issue_count"] * 3, 15)
    score += max(0, 15 - tflint_penalty)
    total_checks = r["checkov"]["passed"] + r["checkov"]["failed"]
    checkov_ratio = (r["checkov"]["passed"] / total_checks) if total_checks else 1.0
    score += checkov_ratio * 25
    req_ratio = r["requirements"]["met"] / r["requirements"]["total"] if r["requirements"]["total"] else 1.0
    score += req_ratio * 20
    score -= len(r["security_antipatterns"]) * 5
    return round(max(score, 0), 1)


def main():
    data = json.loads((RESULTS_DIR / "raw_results.json").read_text())

    lines = ["# Terraformコード生成ベンチマーク結果\n"]
    lines.append(
        "3モデル(Claude Haiku 4.5 / Sonnet 5.5 / Haiku 5.5)に同一プロンプトでTerraformコードを生成させ、"
        "`terraform fmt`/`validate`、tflint、checkov、要件カバレッジ、セキュリティアンチパターンの5軸で客観的に評価した。\n"
    )

    lines.append("## 総合スコア (100点満点、算出方法は末尾参照)\n")
    header = "| タスク | " + " | ".join(MODEL_LABELS[m] for m in MODEL_ORDER) + " |"
    sep = "| --- | " + " | ".join("---" for _ in MODEL_ORDER) + " |"
    lines.append(header)
    lines.append(sep)

    totals = {m: 0.0 for m in MODEL_ORDER}
    count = 0
    for task in TASK_ORDER:
        row = [TASK_LABELS[task]]
        for model in MODEL_ORDER:
            r = data.get(model, {}).get(task, {"error": "missing"})
            s = score_row(r)
            totals[model] += s
            row.append(f"{s}")
        lines.append("| " + " | ".join(row) + " |")
        count += 1

    avg_row = ["**平均**"] + [f"**{round(totals[m] / count, 1)}**" for m in MODEL_ORDER]
    lines.append("| " + " | ".join(avg_row) + " |")
    lines.append("")

    lines.append("## 詳細結果\n")
    for task in TASK_ORDER:
        lines.append(f"### {TASK_LABELS[task]}\n")
        lines.append(
            "| モデル | fmt | validate | tflint issues | checkov pass/fail | 要件カバレッジ | セキュリティ懸念 | 行数 | ファイル数 |"
        )
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for model in MODEL_ORDER:
            r = data.get(model, {}).get(task)
            if not r or "error" in r:
                lines.append(f"| {MODEL_LABELS[model]} | - | - | - | - | - | - | - | - |")
                continue
            fmt_mark = "OK" if r["fmt"]["passed"] else "NG"
            val_mark = "OK" if r["validate"]["validate_passed"] else "NG"
            tflint_n = r["tflint"]["issue_count"]
            ck_pass, ck_fail = r["checkov"]["passed"], r["checkov"]["failed"]
            req = f"{r['requirements']['met']}/{r['requirements']['total']}"
            sec = len(r["security_antipatterns"]) or "-"
            lines.append(
                f"| {MODEL_LABELS[model]} | {fmt_mark} | {val_mark} | {tflint_n} | {ck_pass}/{ck_fail} | {req} | {sec} | "
                f"{r['structure']['total_lines']} | {r['structure']['file_count']} |"
            )
        lines.append("")

        for model in MODEL_ORDER:
            r = data.get(model, {}).get(task)
            if not r or "error" in r:
                continue
            if not r["validate"]["validate_passed"]:
                lines.append(f"- **{MODEL_LABELS[model]}**: validateエラー: `{r['validate']['validate_error']}`")
            if r["security_antipatterns"]:
                lines.append(f"- **{MODEL_LABELS[model]}**: セキュリティ懸念: {', '.join(r['security_antipatterns'])}")
        lines.append("")

    lines.append("## スコア算出方法\n")
    lines.append(
        "- `terraform fmt -check` 通過: 10点\n"
        "- `terraform validate` 通過: 25点\n"
        "- tflint指摘0件: 15点(1件につき-3点、最大-15点)\n"
        "- checkov通過率 × 25点\n"
        "- 要件カバレッジ(正規表現による必須リソース検出) × 20点\n"
        "- セキュリティアンチパターン(SSH全開放・ハードコードされたパスワード等) 1件につき-5点\n"
    )

    out_path = RESULTS_DIR / "report.md"
    out_path.write_text("\n".join(lines))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
