#!/usr/bin/env python3
"""iOS 树自洽性审计 —— 任何云构建派发前必须通过。
回归背景（2026-11-09 Diablo III 连续三次 run 挂 step12）：
  run1: settings.tsv(新) 引用 DM_GAME_UPSCALER_N，但 game.py(老) 不生成该宏
  run2: Swift 调 dm_switch2_*，桥接头(老) 没 import dm_switch2.h；project.yml(老) 缺 -framework CoreBluetooth
  run3: 桥接头(照搬 PR645) import DmGameMenu.h，但该文件在本树不存在
本脚本三项检查分别对应这三个失败模式。用法: ios_tree_audit.py <tree-ish>（cwd=nxnative 仓库）
退出码 0=通过，1=有发现。
"""
import re
import subprocess
import sys

SWIFT_CALL = re.compile(r'(?<![\.\w])([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\s*\(')
SWIFT_KW = {'self', 'init', 'guard', 'while', 'repeat', 'defer', 'where', 'catch',
            'async', 'await', 'try', 'throw', 'return', 'switch', 'func', 'let', 'var', 'if', 'for', 'in'}
# C 函数声明或 struct/typedef 类型名（Swift 构造调用也算引用）
HEADER_DECL = [re.compile(r'\b([a-zA-Z_]\w*)\s*\('), re.compile(r'\}\s*(\w+)\s*;'), re.compile(r'\btypedef\b[^;]*?(\w+)\s*;')]

def git(*args):
    r = subprocess.run(['git', *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def show(tree, path):
    return git('show', f'{tree}:{path}')


def audit(tree):
    files = (git('ls-tree', '-r', '--name-only', tree) or '').splitlines()
    ios = [f for f in files if f.startswith('dm/ios/')]
    fails, warns = [], []

    # ---- 检查A: 桥接头 import 闭包（run3 模式：import 的文件必须存在于本树）
    bh = next((f for f in ios if f.endswith('DmIOS-Bridging-Header.h')), None)
    if not bh:
        return ['no bridging header found'], warns
    reachable = set()
    queue = [bh]
    while queue:
        want = queue.pop()
        base = want.rsplit('/', 1)[-1]
        if base in reachable:
            continue
        cands = [f for f in ios if f.rsplit('/', 1)[-1] == base]
        if not cands:
            fails.append(f'[A] 桥接头链 import 不存在: {base}')
            continue
        for p in cands:
            reachable.add(p.rsplit('/', 1)[-1])
            text = show(tree, p) or ''
            queue += re.findall(r'^\s*#import\s+"([^"]+)"', text, re.M)

    # ---- 检查B: Swift→C 符号闭包（run2 模式：符号有声明但桥接头够不到）
    decl = {}  # symbol -> set(basenames)
    for p in ios:
        if not p.endswith('.h'):
            continue
        text = show(tree, p) or ''
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        text = re.sub(r'//[^\n]*', '', text)
        for rx in HEADER_DECL:
            for s in rx.findall(text):
                if re.fullmatch(r'[a-z][a-z0-9]*(?:_[a-z0-9]+)+', s):
                    decl.setdefault(s, set()).add(p.rsplit('/', 1)[-1])
    for p in ios:
        if not p.endswith('.swift'):
            continue
        text = show(tree, p) or ''
        for s in set(SWIFT_CALL.findall(text)) - SWIFT_KW:
            if s not in decl:
                warns.append(f'[B] Swift 引用未在 dm/ios 头声明(不判死): {s} ({p})')
            elif not (decl[s] & reachable):
                fails.append(f'[B] Swift 调 {s}，声明在 {sorted(decl[s])}，但桥接头链够不到')

    # ---- 检查C: settings.tsv 引用的 DM_GAME_* 宏必须由 game.py 从 profile 生成（run1 模式；其余 DM_* 是宿主固定宏，不归 game.py 管）
    tsv = show(tree, 'dm/games/settings.tsv')
    gpy_path = next((f for f in files if f.startswith('dm/games/') and f.endswith('game.py')), None)
    if tsv and gpy_path:
        gpy = show(tree, gpy_path) or ''
        for tok in sorted(set(re.findall(r'DM_GAME_[A-Z0-9_]+', tsv))):
            if tok not in gpy:
                fails.append(f'[C] settings.tsv 用 {tok}，但 {gpy_path} 不生成该宏')


    return fails, warns


if __name__ == '__main__':
    tree = sys.argv[1]
    f, w = audit(tree)
    for line in f:
        print('FAIL', line)
    for line in w:
        print('warn', line)
    print(f'== {tree}: ' + ('PASS' if not f else f'FAIL ({len(f)})'))
    sys.exit(0 if not f else 1)
