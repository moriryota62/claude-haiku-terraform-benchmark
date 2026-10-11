#!/usr/bin/env python3
"""
モデル呼び出しスクリプトのテンプレート(Amazon Bedrock Converse API版)。
実際のタスクに合わせてMODELS/TASKS_DIR/抽出ロジックを調整して使う。
"""
import argparse
import re
import sys
from pathlib import Path

import boto3

ROOT = Path(__file__).resolve().parent.parent
TASKS_DIR = ROOT / "tasks"
GENERATED_DIR = ROOT / "generated"

# モデルIDは記憶で書かず、AWS Bedrockのモデルカードで確認してから埋める
MODELS = {
    "model-a": "us.anthropic.claude-xxx",
    "model-b": "us.anthropic.claude-yyy",
}

REGION = "us-east-1"

CODE_BLOCK_RE = re.compile(r"```(?:\w+)?\n(?P<code>.*?)```", re.DOTALL)
# ファイル分割マーカーの例。タスクプロンプトの「出力形式」指示と対応させる
FILE_MARKER_RE = re.compile(r"#\s*ファイル名[:：]\s*(?P<filename>[\w.\-/]+)\s*\n")


def call_model(client, model_id: str, prompt: str) -> str:
    response = client.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 8192},
        # temperatureなどのパラメータは非対応のモデルがある。
        # ValidationExceptionが出たら該当パラメータを削る。
    )
    parts = response["output"]["message"]["content"]
    return "".join(p.get("text", "") for p in parts)


def extract_files(text: str, default_filename: str) -> dict[str, str]:
    """単一コードブロック内にファイルマーカーが埋め込まれるケースにも対応する。"""
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

    return {default_filename: combined}


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
                raw_text = call_model(client, model_id, prompt)
            except Exception as e:
                print(f"  ERROR: {e}", file=sys.stderr)
                continue

            out_dir = GENERATED_DIR / model_key / task_name
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / "_raw_response.md").write_text(raw_text)

            files = extract_files(raw_text, default_filename="main.tf")
            for filename, code in files.items():
                safe_name = Path(filename).name
                (out_dir / safe_name).write_text(code.strip() + "\n")
            print(f"  wrote {list(files.keys())} to {out_dir}", file=sys.stderr)


if __name__ == "__main__":
    main()
