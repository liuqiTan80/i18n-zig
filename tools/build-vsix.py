#!/usr/bin/env python3
# 本地打包 VS Code 扩展（无 npm 依赖的离线备选路径）。
#
# 官方路径仍是 `cd editors/vscode && npx @vscode/vsce package`；本脚本只解决
# 「机器上没有 npm / 不能联网」时如何产出可安装的 .vsix。所有元数据（名称、
# 版本、publisher、引擎约束、显示名、描述）一律从 editors/vscode/package.json
# 读取——不手抄，避免 manifest 与 package.json 两处版本漂移。
#
# 用法：python3 tools/build-vsix.py [--out DIR]
# 产物：editors/vscode/zzc-dialect-<version>.vsix（或 --out 指定目录）
#
# VSIX 即 OPC（zip）包：根下 [Content_Types].xml + extension.vsixmanifest，
# 扩展本体在 extension/ 子目录。条目按名称排序、时间戳固定为 1980-01-01，
# 以保证同一份源码两次打包逐字节相同（便于核验）。

import json
import os
import sys
import zipfile
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT_DIR = os.path.join(ROOT, "editors", "vscode")
SKIP_DIRS = {"node_modules", "node_modules_cache"}
SKIP_SUFFIXES = (".vsix", ".vsixmanifest")


def read_manifest():
    with open(os.path.join(EXT_DIR, "package.json"), encoding="utf-8") as f:
        return json.load(f)


def collect_files():
    """扩展目录内全部待打包文件（相对路径、正斜杠、按名排序）。"""
    out = []
    for base, dirs, files in os.walk(EXT_DIR):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if name.endswith(SKIP_SUFFIXES):
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, EXT_DIR).replace(os.sep, "/")
            out.append(rel)
    return sorted(out)


def content_types():
    return """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".md" ContentType="text/markdown"/>
  <Default Extension=".tmLanguage" ContentType="text/xml"/>
  <Default Extension=".txt" ContentType="text/plain"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
  <Default Extension=".png" ContentType="image/png"/>
</Types>
"""


def vsix_manifest(pkg):
    engine = (pkg.get("engines") or {}).get("vscode", "*")
    display = escape(pkg.get("displayName") or pkg["name"])
    desc = escape(pkg.get("description") or "")
    categories = ";".join(pkg.get("categories") or []) or "Programming Languages"
    tags = ";".join(pkg.get("keywords") or [])
    return f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="zh-CN" Id="{escape(pkg['name'])}" Version="{escape(pkg['version'])}" Publisher="{escape(pkg['publisher'])}" />
    <DisplayName>{display}</DisplayName>
    <Description xml:space="preserve">{desc}</Description>
    <Tags>{escape(tags)}</Tags>
    <Categories>{escape(categories)}</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="{escape(engine)}" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.LocalizedLanguages" Value="" />
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
  </Assets>
</PackageManifest>
"""


def add(zf, name, data):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    zf.writestr(info, data)


def main(argv):
    out_dir = EXT_DIR
    if "--out" in argv:
        out_dir = os.path.abspath(argv[argv.index("--out") + 1])
    pkg = read_manifest()
    target = os.path.join(out_dir, f"{pkg['name']}-{pkg['version']}.vsix")
    files = collect_files()
    with zipfile.ZipFile(target, "w") as zf:
        add(zf, "[Content_Types].xml", content_types())
        add(zf, "extension.vsixmanifest", vsix_manifest(pkg))
        for rel in files:
            with open(os.path.join(EXT_DIR, rel), "rb") as f:
                add(zf, "extension/" + rel, f.read())
    size = os.path.getsize(target)
    print(f"打包完成：{target}")
    print(f"  {pkg['publisher']}.{pkg['name']}@{pkg['version']}，{len(files)} 个文件，{size} 字节")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
