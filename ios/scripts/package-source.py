#!/usr/bin/env python3
"""Package only portable source; credentials, personal signing state and build products stay outside."""
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile

source = Path(__file__).resolve().parents[1]
destination = source.parent / "artifacts" / "Bilight-iOS-source.zip"
destination.parent.mkdir(parents=True, exist_ok=True)
excluded = {".build", ".artifacts", "xcuserdata", ".DS_Store", "__pycache__", "ACCEPTANCE.md"}
private_suffixes = {".xcuserstate", ".mobileprovision", ".p12", ".p8", ".pem", ".key", ".ipa", ".sqlite", ".db"}
with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if path.is_file() and not excluded.intersection(relative.parts) and path.suffix not in private_suffixes:
            name = str(Path("Bilight-iOS") / relative)
            if path.name == "project.pbxproj":
                archive.writestr(name, re.sub(r'DEVELOPMENT_TEAM = [^;]*;', 'DEVELOPMENT_TEAM = "";', path.read_text()))
            else:
                archive.write(path, name)
    archive.write(source.parent / "LICENSE", "Bilight-iOS/LICENSE")
    archive.write(source.parent / "THIRD_PARTY_NOTICES.md", "Bilight-iOS/THIRD_PARTY_NOTICES.md")
print(destination)
