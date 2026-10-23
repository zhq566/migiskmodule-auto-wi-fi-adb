"""检查并打包 Magisk 模块。

用法: python build.py
输出: dist/<id>-<version>.zip

- 检查 CRLF 换行（打包时自动转换为 LF，源文件不改动）
- 检查 module.prop 必填字段和 id 格式
- 用 sh -n 检查 shell 脚本语法（找不到 sh 则跳过）
"""
import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(ROOT, "dist")

# 打包进 zip 的文件（相对路径，使用 /）
FILES = [
    "module.prop",
    "service.sh",
    "customize.sh",
    "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
]
SHELL_SCRIPTS = [
    "service.sh",
    "customize.sh",
    "META-INF/com/google/android/update-binary",
]
REQUIRED_PROPS = ["id", "name", "version", "versionCode", "author", "description"]

errors = []
warnings = []


def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read()


def find_sh():
    sh = shutil.which("sh")
    if sh:
        return sh
    for p in (r"C:\Program Files\Git\bin\sh.exe", r"C:\Program Files (x86)\Git\bin\sh.exe"):
        if os.path.isfile(p):
            return p
    return None


def main():
    contents = {}

    # 1. 文件存在 / 换行 / BOM
    for rel in FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            errors.append(f"缺少文件: {rel}")
            continue
        data = read(rel)
        if data.startswith(b"\xef\xbb\xbf"):
            warnings.append(f"{rel}: 含 UTF-8 BOM，打包时已去除")
            data = data[3:]
        if b"\r" in data:
            warnings.append(f"{rel}: 含 CRLF 换行，打包时已转换为 LF")
            data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        if not data.endswith(b"\n"):
            data += b"\n"
        contents[rel] = data

    # 2. module.prop
    props = {}
    if "module.prop" in contents:
        for line in contents["module.prop"].decode("utf-8").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip()
        for k in REQUIRED_PROPS:
            if not props.get(k):
                errors.append(f"module.prop 缺少字段: {k}")
        if props.get("id") and not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9._-]+", props["id"]):
            errors.append(f"module.prop id 格式非法: {props['id']}")
        if props.get("versionCode") and not props["versionCode"].isdigit():
            errors.append(f"module.prop versionCode 必须是整数: {props['versionCode']}")

    # 3. shell 语法
    sh = find_sh()
    if not sh:
        warnings.append("未找到 sh，跳过语法检查（安装 Git for Windows 即可）")
    else:
        for rel in SHELL_SCRIPTS:
            if rel not in contents:
                continue
            r = subprocess.run([sh, "-n"], input=contents[rel], capture_output=True)
            if r.returncode != 0:
                msg = r.stderr.decode("utf-8", "replace").strip()
                errors.append(f"{rel}: 语法错误\n    {msg}")

    for w in warnings:
        print(f"[警告] {w}")
    if errors:
        for e in errors:
            print(f"[错误] {e}")
        print("检查未通过，未打包。")
        return 1

    # 4. 打包（zip 内路径用 /，脚本设为可执行）
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"{props['id']}-{props['version']}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in FILES:
            info = zipfile.ZipInfo(rel, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if rel in SHELL_SCRIPTS else 0o644
            info.external_attr = (0o100000 | mode) << 16
            z.writestr(info, contents[rel])

    print(f"检查通过，已生成: {os.path.relpath(out, ROOT)}")
    for name in zipfile.ZipFile(out).namelist():
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
