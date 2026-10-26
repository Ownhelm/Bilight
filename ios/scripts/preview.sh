#!/bin/bash
set -euo pipefail
code_dir="$(cd "$(dirname "$0")/../.." && pwd)"
local_dir="${BILIGHT_LOCAL_DIR:-$(dirname "$code_dir")/Local}"
assets_dir="${BILIGHT_DEMO_ASSETS_DIR:-$(dirname "$code_dir")/Promotion/DemoAssets}"
preview_dir="$local_dir/Builds/Preview"
if [ ! -d "$assets_dir" ]; then
  echo "缺少外部演示素材目录：$assets_dir" >&2
  exit 1
fi
mkdir -p "$preview_dir"
python3 - "$assets_dir" "$preview_dir/overlay.json" "$code_dir/ios/project.yml" <<'PY'
import json, sys
from pathlib import Path
spec = {"include": [{"path": sys.argv[3], "relativePaths": True}], "name": "BilightPreview", "targets": {"Bilight": {"sources": [{"path": sys.argv[1], "type": "folder", "buildPhase": "resources"}]}}}
Path(sys.argv[2]).write_text(json.dumps(spec, ensure_ascii=False, indent=2) + "\n")
PY
xcodegen generate --spec "$preview_dir/overlay.json" --project-root "$code_dir/ios" --project "$code_dir/ios"
echo "预览工程：$code_dir/ios/BilightPreview.xcodeproj；使用 Bilight scheme，启动参数 --demo。"
