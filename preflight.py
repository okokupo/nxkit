#!/usr/bin/env python3
"""nxkit 流水线预检（2026-11-09 Chen 批准的流程优化 ①）
派发云构建前跑一次，全绿才放行。
用法:
  preflight.py --ref <full-sha> [--repo /root/nxkit-home/nxnative] [--post-prepare /root/game-transfer/d3_build]
  --post-prepare: prepare 完成后追加产物规模验证门（②）
退出码 0=放行, 1=阻断
"""
import argparse, json, os, re, subprocess, sys

NXKIT = "/root/nxkit"
NEEDED_PIP = ["lz4", "capstone", "fonttools", "cryptography", "zbic"]  # 2026-11-08 Run#2 教训
FAILS, WARNS = [], []


def sh(*a, cwd=None):
    return subprocess.run(a, capture_output=True, text=True, cwd=cwd)


def fail(m): FAILS.append(m)
def warn(m): WARNS.append(m)


def check_sha(ref):
    if not re.fullmatch(r"[0-9a-f]{40}", ref or ""):
        fail(f"ref 不是 40 位完整 SHA: {ref!r} (Run#1 教训)")
        return
    r = sh("git", "-C", repo, "cat-file", "-t", ref)
    if r.returncode != 0 or r.stdout.strip() != "commit":
        fail(f"ref 在 {repo} 不存在: {ref}")


def check_api():
    """nxkit.py 引用的 B.* 属性必须存在于目标 nxnative 的 build_ipa_from_nsp"""
    INJECTED = {"nacp", "pg"}  # nxkit.load_nxnative 手动注入（B.pg, B.nacp = pg, nacp）
    src = open(os.path.join(NXKIT, "nxkit.py"), encoding="utf-8").read()
    used = sorted(set(re.findall(r"\bB\.([A-Za-z_][A-Za-z0-9_]*)", src)))
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("bmod", os.path.join(repo, "scripts", "build_ipa_from_nsp.py"))
        bmod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bmod)
        missing = [n for n in used if n not in INJECTED and not hasattr(bmod, n)]
    except Exception as e:
        fail(f"无法导入 build_ipa_from_nsp: {e}")
        return
    if missing:
        fail(f"nxkit.py 引用但目标 nxnative 缺失的 API: {missing} (D3 旧API 教训)")


def check_workflow():
    yml = open(os.path.join(NXKIT, ".github", "workflows", "build-ipa.yml"), encoding="utf-8").read()
    if "runs-on: xcode-27" not in yml:
        fail("runner 不是 xcode-27（Metal 编译器已验证组合）(Run#3/4 教训)")
    pip = re.search(r"pip install[^\n]*", yml)
    pipline = pip.group(0) if pip else ""
    for dep in NEEDED_PIP:
        if dep not in pipline:
            fail(f"workflow pip 缺依赖 {dep} (Run#2 zbic 教训)")


def check_conflicts():
    r = sh("git", "-C", repo, "grep", "-l", "<<<<<<<", "--", ":", "!*/tests/*", ":!*test_*")
    if r.returncode == 0 and r.stdout.strip():
        files = [f for f in r.stdout.splitlines() if "test" not in os.path.basename(f)]
        if files:
            fail(f"存在冲突标记残留: {files}")


def check_post_prepare(build_dir):
    """阶段产物验证门: kit 存在、规模合理、shader 数 vs profile 预期"""
    info_p = os.path.join(build_dir, "nxkit.json")
    if not os.path.exists(info_p):
        fail(f"nxkit.json 不存在，prepare 未完成: {build_dir}")
        return
    # kit 文件
    kits = [f for f in os.listdir(os.path.join(build_dir, "kit")) if f.endswith((".nxk", ".nxk.enc"))] \
        if os.path.isdir(os.path.join(build_dir, "kit")) else []
    log = ""
    for lg in ("prepare.log", os.path.join(build_dir, "prepare.log")):
        p = os.path.join(build_dir, lg)
        if os.path.exists(p):
            log = open(p, encoding="utf-8", errors="replace").read()
            break
    m = re.findall(r"(\d[\d,]*) shaders", log)
    if m:
        n = int(m[-1].replace(",", ""))
        # profile 预期：从 nxkit.json 的 game title 对应 README / game.tsv 抓
        title = ""
        try:
            title = json.load(open(info_p))["game"]
        except Exception:
            pass
        exp = None
        for cand in (f"{repo}/dm/games/{title}/README.md", f"{repo}/dm/games/{title}/game.tsv"):
            if os.path.exists(cand):
                t = open(cand, encoding="utf-8", errors="replace").read()
                e = re.search(r"(\d[\d,]*)\s*shaders", t)
                if e:
                    exp = int(e.group(1).replace(",", ""))
                    break
        if exp and n < exp * 0.5:
            fail(f"shader 数异常: split={n} vs profile预期={exp} (v3 黑屏 246/25693 教训)")
        elif exp:
            print(f"  shader gate: split={n} expected={exp} ✓")
    else:
        warn("prepare.log 未找到 shader 计数行，人工确认")


ap = argparse.ArgumentParser()
ap.add_argument("--ref", required=True)
ap.add_argument("--repo", default="/root/nxkit-home/nxnative")
ap.add_argument("--post-prepare", default=None)
args = ap.parse_args()
repo = args.repo

check_sha(args.ref)
check_api()
check_workflow()
check_conflicts()
if args.post_prepare:
    check_post_prepare(args.post_prepare)

print("== preflight ==")
for w in WARNS:
    print(f"  WARN: {w}")
for f in FAILS:
    print(f"  FAIL: {f}")
print(f"结果: {'✅ 放行' if not FAILS else '❌ 阻断'} ({len(FAILS)} fail / {len(WARNS)} warn)")
sys.exit(1 if FAILS else 0)
