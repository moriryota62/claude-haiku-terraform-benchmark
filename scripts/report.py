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

# Amazon Bedrock, US Geo cross-region inference profile (us.anthropic.*) の価格 ($/1M tokens)
MODEL_PRICE_PER_1M = {
    "haiku-4-5": {"input": 1.10, "output": 5.50},
    "sonnet-5-5": {"input": 2.20, "output": 11.00},
    "haiku-5-5": {"input": 0.11, "output": 0.55},
}
TASK_LABELS = {
    "task1_simple": "タスク1: シンプル (S3)",
    "task2_medium": "タスク2: 中程度 (VPC+EC2)",
    "task3_complex": "タスク3: 複雑 (ALB+ASG+RDS+IAM)",
}
MODEL_ORDER = ["haiku-4-5", "sonnet-5-5", "haiku-5-5"]
TASK_ORDER = ["task1_simple", "task2_medium", "task3_complex"]


def calc_cost_usd(model, meta):
    price = MODEL_PRICE_PER_1M.get(model)
    if not price or meta.get("input_tokens") is None:
        return None
    return (
        meta["input_tokens"] / 1_000_000 * price["input"]
        + meta["output_tokens"] / 1_000_000 * price["output"]
    )


SCORE_COMPONENTS = ["fmt", "validate", "tflint", "checkov", "requirements", "convention", "security"]
SCORE_COMPONENT_LABELS = {
    "fmt": "fmt (10点)",
    "validate": "validate (20点)",
    "tflint": "tflint (10点)",
    "checkov": "checkov (20点)",
    "requirements": "要件カバレッジ (15点)",
    "convention": "規約準拠 (15点)",
    "security": "セキュリティ減点",
}


def score_breakdown(r):
    """指標ごとの点数内訳(fmt/validate/tflint/checkov/要件カバレッジ/コーディング規約/セキュリティ減点)を返す。"""
    if "error" in r:
        return {k: 0.0 for k in SCORE_COMPONENTS} | {"total": 0.0}

    breakdown = {}
    breakdown["fmt"] = 10.0 if r["fmt"]["passed"] else 0.0
    breakdown["validate"] = 20.0 if r["validate"]["validate_passed"] else 0.0
    tflint_penalty = min(r["tflint"]["issue_count"] * 2, 10)
    breakdown["tflint"] = max(0.0, 10.0 - tflint_penalty)
    total_checks = r["checkov"]["passed"] + r["checkov"]["failed"]
    checkov_ratio = (r["checkov"]["passed"] / total_checks) if total_checks else 1.0
    breakdown["checkov"] = round(checkov_ratio * 20, 1)
    req_ratio = r["requirements"]["met"] / r["requirements"]["total"] if r["requirements"]["total"] else 1.0
    breakdown["requirements"] = round(req_ratio * 15, 1)
    conv = r.get("coding_convention")
    conv_ratio = (conv["passed"] / conv["total"]) if conv and conv["total"] else 1.0
    breakdown["convention"] = round(conv_ratio * 15, 1)
    breakdown["security"] = round(-len(r["security_antipatterns"]) * 5, 1)

    total = round(max(sum(breakdown.values()), 0), 1)
    breakdown["total"] = total
    return breakdown


def score_row(r):
    return score_breakdown(r)["total"]


def main():
    data = json.loads((RESULTS_DIR / "raw_results.json").read_text())

    lines = ["# Terraformコード生成ベンチマーク結果\n"]
    lines.append(
        "3モデル(Claude Haiku 4.5 / Sonnet 5.5 / Haiku 5.5)に同一プロンプトでTerraformコードを生成させ、"
        "`terraform fmt`/`validate`、tflint、checkov、要件カバレッジ、コーディング規約準拠、セキュリティアンチパターンの6軸で客観的に評価した。\n"
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

    lines.append("## 評価指標ごとの点数内訳\n")
    for task in TASK_ORDER:
        lines.append(f"### {TASK_LABELS[task]}\n")
        lines.append("| 指標 | " + " | ".join(MODEL_LABELS[m] for m in MODEL_ORDER) + " |")
        lines.append("| --- | " + " | ".join("---" for _ in MODEL_ORDER) + " |")
        breakdowns = {
            m: score_breakdown(data.get(m, {}).get(task, {"error": "missing"}))
            for m in MODEL_ORDER
        }
        for component in SCORE_COMPONENTS:
            row = [SCORE_COMPONENT_LABELS[component]]
            for m in MODEL_ORDER:
                row.append(f"{breakdowns[m][component]}")
            lines.append("| " + " | ".join(row) + " |")
        total_row = ["**合計**"] + [f"**{breakdowns[m]['total']}**" for m in MODEL_ORDER]
        lines.append("| " + " | ".join(total_row) + " |")
        lines.append("")

    price_desc = ", ".join(
        f"{MODEL_LABELS[m]}: 入力${MODEL_PRICE_PER_1M[m]['input']}/出力${MODEL_PRICE_PER_1M[m]['output']} (per 1M tokens)"
        for m in MODEL_ORDER
    )
    lines.append("## 生成時間・トークン数・コスト\n")
    lines.append(
        "各モデルがタスクのコードを生成するのにかかった時間と、入出力トークン数、"
        "それに基づくコストを示す。コストはAmazon Bedrock(US Geo cross-region inference、"
        f"`us.anthropic.*`)の価格({price_desc})"
        "から算出した。\n"
    )
    lines.append("| タスク | モデル | 生成時間(秒) | 入力トークン | 出力トークン | コスト(USD) |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    cost_totals = {m: 0.0 for m in MODEL_ORDER}
    time_totals = {m: 0.0 for m in MODEL_ORDER}
    for task in TASK_ORDER:
        for model in MODEL_ORDER:
            r = data.get(model, {}).get(task)
            meta = (r or {}).get("meta", {})
            elapsed = meta.get("elapsed_sec")
            cost = calc_cost_usd(model, meta)
            if elapsed is not None:
                time_totals[model] += elapsed
            if cost is not None:
                cost_totals[model] += cost
            elapsed_str = f"{elapsed:.1f}" if elapsed is not None else "-"
            cost_str = f"{cost:.4f}" if cost is not None else "-"
            in_tok = meta.get("input_tokens")
            out_tok = meta.get("output_tokens")
            lines.append(
                f"| {TASK_LABELS[task]} | {MODEL_LABELS[model]} | {elapsed_str} | "
                f"{in_tok if in_tok is not None else '-'} | {out_tok if out_tok is not None else '-'} | {cost_str} |"
            )
    lines.append("")
    lines.append("| モデル | 合計生成時間(秒) | 合計コスト(USD) |")
    lines.append("| --- | --- | --- |")
    for model in MODEL_ORDER:
        lines.append(f"| {MODEL_LABELS[model]} | {time_totals[model]:.1f} | {cost_totals[model]:.4f} |")
    lines.append("")

    lines.append("## 詳細結果\n")
    for task in TASK_ORDER:
        lines.append(f"### {TASK_LABELS[task]}\n")
        lines.append(
            "| モデル | fmt | validate | tflint issues | checkov pass/fail | 要件カバレッジ | 規約準拠 | セキュリティ懸念 | 行数 | ファイル数 |"
        )
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for model in MODEL_ORDER:
            r = data.get(model, {}).get(task)
            if not r or "error" in r:
                lines.append(f"| {MODEL_LABELS[model]} | - | - | - | - | - | - | - | - | - |")
                continue
            fmt_mark = "OK" if r["fmt"]["passed"] else "NG"
            val_mark = "OK" if r["validate"]["validate_passed"] else "NG"
            tflint_n = r["tflint"]["issue_count"]
            ck_pass, ck_fail = r["checkov"]["passed"], r["checkov"]["failed"]
            req = f"{r['requirements']['met']}/{r['requirements']['total']}"
            conv = r.get("coding_convention", {})
            conv_str = f"{conv.get('passed', 0)}/{conv.get('total', 0)}"
            sec = len(r["security_antipatterns"]) or "-"
            lines.append(
                f"| {MODEL_LABELS[model]} | {fmt_mark} | {val_mark} | {tflint_n} | {ck_pass}/{ck_fail} | {req} | {conv_str} | {sec} | "
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
            conv = r.get("coding_convention", {})
            if conv.get("violations"):
                lines.append(f"- **{MODEL_LABELS[model]}**: 規約違反: {', '.join(conv['violations'])}")
        lines.append("")

    lines.append("## スコア算出方法\n")
    lines.append(
        "- `terraform fmt -check` 通過: 10点\n"
        "- `terraform validate` 通過: 20点\n"
        "- tflint指摘0件: 10点(1件につき-2点、最大-10点)\n"
        "- checkov通過率 × 20点\n"
        "- 要件カバレッジ(正規表現による必須リソース検出) × 15点\n"
        "- コーディング規約準拠率(variable/outputのtype・description記載、snake_case命名、"
        "同一リソースタイプが複数ある場合に`this`を使わない) × 15点\n"
        "- セキュリティアンチパターン(SSH全開放・ハードコードされたパスワード等) 1件につき-5点\n"
    )

    out_path = RESULTS_DIR / "report.md"
    out_path.write_text("\n".join(lines))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
