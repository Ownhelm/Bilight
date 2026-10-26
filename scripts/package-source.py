#!/usr/bin/env python3
"""Package the portable code tree, including canonical brand sources, without local material."""
from pathlib import Path
import re,subprocess
from zipfile import ZipFile,ZIP_DEFLATED
root=Path(__file__).resolve().parents[1]
output=root/'releases/Bilight-v0.1.0-source.zip';output.parent.mkdir(exist_ok=True)
files=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')
excluded={'releases','release','Promotion','Local','Legal','.git','.secrets','node_modules','xcuserdata','BilightPreview.xcodeproj','__pycache__'}
with ZipFile(output,'w',ZIP_DEFLATED) as archive:
 for name in sorted(set(files)):
  path=root/name;relative=Path(name)
  if not name or not path.is_file() or excluded.intersection(relative.parts):continue
  if path.suffix.lower() in {'.ipa','.zip','.p12','.p8','.key','.pem','.mobileprovision','.sqlite','.db','.log'}:continue
  if path.suffix.lower() in {'.png','.jpg','.jpeg','.webp','.gif'} and name!='ios/Bilight/Assets.xcassets/AppIcon.appiconset/AppIcon.png':continue
  if path.suffix.lower() in {'.mp4','.mov','.wav','.mp3','.m4a'} and name!='ios/BilightTests/Fixtures/fullscreen-motion.mp4':continue
  if path.name=='project.pbxproj':archive.writestr('Bilight/'+name,re.sub(r'DEVELOPMENT_TEAM = [^;]*;', 'DEVELOPMENT_TEAM = "";',path.read_text()))
  else:archive.write(path,'Bilight/'+name)
 assert archive.testzip() is None
print(output)
