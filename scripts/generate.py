#!/usr/bin/env python3
"""Bedrock経由で複数モデルにTerraformコードを生成させるスクリプト。"""
import argparse
import json
import re
import sys
import time
from pathlib import Path

import boto3

ROOT = Path(__file__).resolve().parent.parent
TASKS_DIR = ROOT / "tasks"
GENERATED_DIR = ROOT / "generated"

MODELS = {
    "haiku-4-5": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "sonnet-5-5": "us.anthropic.claude-sonnet-5-5",
    "haiku-5-5": "us.anthropic.claude-haiku-5-5",
}

REGION = "us-east-1"

CODE_BLOCK_RE = re.compile(r"```(?:hcl|terraform)?\n(?P<code>.*?)```", re.DOTALL)
FILE_MARKER_RE = re.compile(r"#\s*ファイル名[:：]\s*(?P<filename>[\w.\-/]+\.tf)\s*\n")


def call_model(client, model_id: str, prompt: str) -> dict:
    start = time.monotonic()
    response = client.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 16000},
    )
    elapsed_sec = time.monotonic() - start
    parts = response["output"]["message"]["content"]
    text = "".join(p.get("text", "") for p in parts)
    usage = response.get("usage", {})
    return {
        "text": text,
        "elapsed_sec": elapsed_sec,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
    }


def extract_files(text: str) -> dict[str, str]:
    code_blocks = [m.group("code") for m in CODE_BLOCK_RE.finditer(text)]
    combined = "\n".join(code_blocks) if code_blocks else text

    markers = list(FILE_MARKER_RE.finditer(combined))
    if markers:
        files = {}
        for i, m in enumerate(markers):
            start = m.end()
            end = markers[i + 1].start() if i + 1 < len(markers) else len(combined)
            files[m.group("filename")] = combined[start:end]
        return files

    return {"main.tf": combined}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", nargs="*", default=list(MODELS.keys()))
    parser.add_argument("--tasks", nargs="*", default=None)
    args = parser.parse_args()

    task_files = sorted(TASKS_DIR.glob("*.md"))
    if args.tasks:
        task_files = [t for t in task_files if t.stem in args.tasks]

    client = boto3.client("bedrock-runtime", region_name=REGION)

    for task_path in task_files:
        task_name = task_path.stem
        prompt = task_path.read_text()
        for model_key in args.models:
            model_id = MODELS[model_key]
            print(f"[generate] task={task_name} model={model_key} ...", file=sys.stderr)
            try:
                result = call_model(client, model_id, prompt)
            except Exception as e:
                print(f"  ERROR: {e}", file=sys.stderr)
                continue

            out_dir = GENERATED_DIR / model_key / task_name
            for stale in out_dir.glob("*.tf"):
                stale.unlink()
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / "_raw_response.md").write_text(result["text"])
            (out_dir / "_meta.json").write_text(json.dumps({
                "elapsed_sec": result["elapsed_sec"],
                "input_tokens": result["input_tokens"],
                "output_tokens": result["output_tokens"],
            }, indent=2))

            files = extract_files(result["text"])
            for filename, code in files.items():
                safe_name = Path(filename).name
                (out_dir / safe_name).write_text(code.strip() + "\n")
            print(
                f"  wrote {list(files.keys())} to {out_dir} "
                f"({result['elapsed_sec']:.1f}s, "
                f"{result['input_tokens']}in/{result['output_tokens']}out tokens)",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
