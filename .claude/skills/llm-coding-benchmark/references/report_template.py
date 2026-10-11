#!/usr/bin/env python3
"""
raw_results.json から比較レポート(Markdown)を生成するテンプレート。
モデル・タスクのラベル、配点はベンチマークの内容に合わせて調整する。
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS_DIR = ROOT / "results"

MODEL_LABELS = {
    "model-a": "Model A",
    "model-b": "Model B",
}
TASK_LABELS = {
    "task1_simple": "タスク1: シンプル",
    "task2_medium": "タスク2: 中程度",
    "task3_complex": "タスク3: 複雑",
}
MODEL_ORDER = list(MODEL_LABELS.keys())
TASK_ORDER = list(TASK_LABELS.keys())


def score_row(r):
    """配点は合計100点になるよう調整する。各現場のベンチマークで重視したい軸に重みを寄せる。"""
    if "error" in r:
        return 0.0
    score = 0.0
    score += 10 if r["fmt"]["passed"] else 0
    score += 20 if r["validate"]["validate_passed"] else 0
    score += max(0, 10 - min(r["tflint"]["issue_count"] * 2, 10))
    total_checks = r["checkov"]["passed"] + r["checkov"]["failed"]
    checkov_ratio = (r["checkov"]["passed"] / total_checks) if total_checks else 1.0
    score += checkov_ratio * 20
    req_ratio = r["requirements"]["met"] / r["requirements"]["total"] if r["requirements"]["total"] else 1.0
    score += req_ratio * 15
    conv = r.get("coding_convention")
    conv_ratio = (conv["passed"] / conv["total"]) if conv and conv["total"] else 1.0
    score += conv_ratio * 15
    score -= len(r["security_antipatterns"]) * 5
    return round(max(score, 0), 1)


def main():
    data = json.loads((RESULTS_DIR / "raw_results.json").read_text())

    lines = ["# ベンチマーク結果\n"]
    lines.append("## 総合スコア (100点満点、算出方法は末尾参照)\n")
    lines.append("| タスク | " + " | ".join(MODEL_LABELS[m] for m in MODEL_ORDER) + " |")
    lines.append("| --- | " + " | ".join("---" for _ in MODEL_ORDER) + " |")

    totals = {m: 0.0 for m in MODEL_ORDER}
    for task in TASK_ORDER:
        row = [TASK_LABELS[task]]
        for model in MODEL_ORDER:
            r = data.get(model, {}).get(task, {"error": "missing"})
            s = score_row(r)
            totals[model] += s
            row.append(str(s))
        lines.append("| " + " | ".join(row) + " |")

    avg_row = ["**平均**"] + [f"**{round(totals[m] / len(TASK_ORDER), 1)}**" for m in MODEL_ORDER]
    lines.append("| " + " | ".join(avg_row) + " |")
    lines.append("")

    # 違反の内訳など、記事執筆時に具体例として使える情報も残す
    lines.append("## 規約違反・セキュリティ懸念の内訳\n")
    for task in TASK_ORDER:
        for model in MODEL_ORDER:
            r = data.get(model, {}).get(task, {})
            if not r or "error" in r:
                continue
            if r["security_antipatterns"]:
                lines.append(f"- **{MODEL_LABELS[model]} / {TASK_LABELS[task]}**: {', '.join(r['security_antipatterns'])}")
            conv = r.get("coding_convention", {})
            if conv.get("violations"):
                lines.append(f"- **{MODEL_LABELS[model]} / {TASK_LABELS[task]}**: {', '.join(conv['violations'])}")

    out_path = RESULTS_DIR / "report.md"
    out_path.write_text("\n".join(lines))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
