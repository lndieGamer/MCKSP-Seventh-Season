#!/usr/bin/env python3
"""
check-deps.py -- validates the dependency graph of a packwiz modpack.

Reads mods/*.pw.toml, downloads every jar (with an on-disk cache), extracts
mod metadata from neoforge.mods.toml / mods.toml / fabric.mod.json including
JarJar-nested mods, then verifies:

  1. every required dependency is present in the pack
  2. the present version satisfies the declared version range
  3. the dependency's `side` is compatible with the dependent's `side`
  4. the dependency's unsup flavor is compatible with the dependent's flavor
  5. the loader version in pack.toml satisfies every mod's requirement

Exit code 1 if any hard error is found.

    python3 check-deps.py [--cache DIR] [--pack DIR] [--quiet-optional]
"""

import argparse
import json
import os
import pathlib
import re
import sys
import urllib.parse
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

try:
    import tomllib
except ImportError:
    import tomli as tomllib

# Mod ids provided by the environment rather than by a jar in the pack.
BUILTIN = {"minecraft", "neoforge", "forge", "fabricloader", "fabric",
           "java", "mcp", "fml", "javafml", "lowcodefml", "connectormod"}


def norm(modid):
    """fabric-api and fabric_api are the same mod."""
    return str(modid).replace("-", "_").lower()


# ---------------------------------------------------------------- versions

MC_PREFIXES = []          # filled from pack.toml, e.g. ["1.21.1", "1.21"]


def parse_version(v):
    """'1.21.1-3.3.2' -> (3,3,2). Strips the pack's MC version and qualifiers."""
    v = str(v).split("+")[0].strip()
    for mc in MC_PREFIXES:            # only strip the pack's own MC version
        for sep in ("-", "_", "+"):
            if v.startswith(mc + sep):
                v = v[len(mc) + 1:]
                break
        else:
            continue
        break
    v = re.split(r"[-_](?=[A-Za-z])", v)[0]   # drop -beta / -neoforge tails
    nums = re.findall(r"\d+", v)
    return tuple(int(n) for n in nums[:5]) or (0,)


def cmp_pad(a, b):
    """Compare version tuples with zero padding: (1,) == (1,0,0)."""
    n = max(len(a), len(b))
    return (a + (0,) * n)[:n], (b + (0,) * n)[:n]


def in_range(version, spec):
    """Maven range check: [a,b) (a,b] [a,] a  -- returns True when unsure."""
    if not spec or version is None:
        return True
    if "${" in str(version) or "${" in str(spec):
        return True                    # unresolved gradle placeholder
    spec = spec.strip()
    if not spec or spec in ("*", "[1,)"):
        return True
    v = parse_version(version)
    if not (spec[0] in "[(" and spec[-1] in "])"):
        x, y = cmp_pad(v, parse_version(spec))
        return x >= y            # bare version = minimum
    lo_inc, hi_inc = spec[0] == "[", spec[-1] == "]"
    body = spec[1:-1]
    lo, _, hi = body.partition(",")
    if not _:                                    # [1.2.3] = exact
        x, y = cmp_pad(v, parse_version(lo))
        return x == y
    if lo.strip():
        x, lo_v = cmp_pad(v, parse_version(lo))
        if x < lo_v or (x == lo_v and not lo_inc):
            return False
    if hi.strip():
        x, hi_v = cmp_pad(v, parse_version(hi))
        if x > hi_v or (x == hi_v and not hi_inc):
            return False
    return True


# ------------------------------------------------------------ jar metadata

def read_mods_toml(raw, jar_version=None):
    """Parse a NeoForge/Forge mods.toml into (mods, dependencies)."""
    try:
        data = tomllib.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return [], {}
    mods = []
    for m in data.get("mods", []):
        ver = m.get("version", "0")
        if "${" in str(ver) and jar_version:
            ver = jar_version          # resolve ${file.jarVersion} from MANIFEST
        mods.append((m.get("modId"), ver))
    deps = {}
    for owner, entries in (data.get("dependencies") or {}).items():
        if isinstance(entries, dict):
            entries = [entries]
        out = []
        for d in entries or []:
            required = d.get("type", "required" if d.get("mandatory", True) else "optional")
            out.append({
                "modId": d.get("modId"),
                "required": str(required).lower() == "required",
                "range": d.get("versionRange", ""),
                "side": str(d.get("side", "BOTH")).upper(),
            })
        deps[owner] = out
    return mods, deps


def read_fabric_json(raw):
    try:
        data = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return [], {}
    mid = data.get("id")
    mods = [(mid, data.get("version", "0"))]
    deps = {mid: [{"modId": k, "required": True, "range": "", "side": "BOTH"}
                  for k in (data.get("depends") or {})]}
    return mods, deps


def scan_jar(path, depth=0):
    """Return (mods, deps) for a jar, recursing into JarJar-nested jars."""
    mods, deps = [], {}
    try:
        z = zipfile.ZipFile(path)
    except Exception:
        return mods, deps
    with z:
        jar_version = None
        if "META-INF/MANIFEST.MF" in z.namelist():
            mf = z.read("META-INF/MANIFEST.MF").decode("utf-8", "replace")
            hit = re.search(r"Implementation-Version:\s*(\S+)", mf)
            if hit:
                jar_version = hit.group(1)
        for entry in ("META-INF/neoforge.mods.toml", "META-INF/mods.toml"):
            if entry in z.namelist():
                m, d = read_mods_toml(z.read(entry), jar_version)
                mods += m
                deps.update(d)
                break
        else:
            if "fabric.mod.json" in z.namelist():
                m, d = read_fabric_json(z.read("fabric.mod.json"))
                mods += m
                deps.update(d)
        if depth < 2:
            for n in z.namelist():
                if n.startswith("META-INF/jarjar/") and n.endswith(".jar"):
                    tmp = pathlib.Path("/tmp") / f"_jij_{depth}_{os.path.basename(n)}"
                    tmp.write_bytes(z.read(n))
                    m, _ = scan_jar(tmp, depth + 1)   # nested deps are internal
                    mods += m
                    tmp.unlink(missing_ok=True)
    return mods, deps


# ----------------------------------------------------------------- fetching

def metafile_url(text, filename):
    m = re.search(r'^url\s*=\s*"([^"]+)"', text, re.M)
    if m:
        return m.group(1)
    m = re.search(r"file-id\s*=\s*(\d+)", text)
    if m:
        fid = int(m.group(1))
        return (f"https://mediafilez.forgecdn.net/files/"
                f"{fid // 1000}/{fid % 1000}/{urllib.parse.quote(filename)}")
    return None


def load_pack(pack_dir, cache_dir):
    """Return list of dicts describing every mod metafile in the pack."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    entries = []
    for p in sorted((pack_dir / "mods").glob("*.pw.toml")):
        t = p.read_text(encoding="utf-8")
        fn = re.search(r'^filename\s*=\s*"([^"]+)"', t, re.M)
        if not fn:
            continue
        side = re.search(r'^side\s*=\s*"([^"]+)"', t, re.M)
        entries.append({
            "meta": p.stem,
            "filename": fn.group(1),
            "side": side.group(1) if side else "both",
            "url": metafile_url(t, fn.group(1)),
        })

    def fetch(e):
        dst = cache_dir / e["filename"]
        if dst.exists() and dst.stat().st_size > 0:
            return None
        if not e["url"]:
            return f"{e['meta']}: no download url"
        try:
            urllib.request.urlretrieve(e["url"], dst)
        except Exception as ex:
            return f"{e['meta']}: {ex}"
        return None

    with ThreadPoolExecutor(8) as ex:
        for err in ex.map(fetch, entries):
            if err:
                print(f"  ! не скачался {err}", file=sys.stderr)
    return entries


def load_flavors(pack_dir):
    """metafile stem -> set of flavor ids, from unsup.toml."""
    f = pack_dir / "unsup.toml"
    if not f.exists():
        return {}
    try:
        data = tomllib.loads(f.read_text(encoding="utf-8"))
    except Exception:
        return {}
    out = {}
    for name, body in (data.get("metafile") or {}).items():
        fl = body.get("flavors", [])
        out[name] = {fl} if isinstance(fl, str) else set(fl)
    return out


# -------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", default=".", type=pathlib.Path)
    ap.add_argument("--cache", default=pathlib.Path(".jarcache"), type=pathlib.Path)
    ap.add_argument("--quiet-optional", action="store_true")
    args = ap.parse_args()

    pack = args.pack
    entries = load_pack(pack, args.cache)
    flavors = load_flavors(pack)

    loader_version = None
    pk = pack / "pack.toml"
    if pk.exists():
        data = tomllib.loads(pk.read_text(encoding="utf-8"))
        vers = data.get("versions", {})
        loader_version = vers.get("neoforge") or vers.get("forge") or vers.get("fabric")
        mc = vers.get("minecraft")
        if mc:
            MC_PREFIXES.append(mc)
            if mc.count(".") == 2:
                MC_PREFIXES.append(mc.rsplit(".", 1)[0])

    provides = {}   # modid -> (version, side, metafile stem)
    requires = []   # (owner_modid, metafile stem, dep dict)

    for e in entries:
        jar = args.cache / e["filename"]
        if not jar.exists():
            continue
        mods, deps = scan_jar(jar)
        for mid, ver in mods:
            if mid:
                provides.setdefault(norm(mid), (ver, e["side"], e["meta"]))
        for owner, dl in deps.items():
            for d in dl:
                if d["modId"]:
                    requires.append((owner, e["meta"], d))

    errors, warnings = [], []

    for owner, meta, d in requires:
        dep = norm(d["modId"])
        own_side = next((e["side"] for e in entries if e["meta"] == meta), "both")

        # a CLIENT-only dependency is irrelevant for a server-side install
        if d["side"] == "CLIENT" and own_side == "server":
            continue
        if d["side"] == "SERVER" and own_side == "client":
            continue
        if dep in ("minecraft", "java"):
            continue

        if dep in ("neoforge", "forge"):
            if loader_version and not in_range(loader_version, d["range"]):
                errors.append(
                    f"{owner} ({meta}) требует {dep} {d['range']}, "
                    f"в pack.toml указан {loader_version}")
            continue

        if dep in BUILTIN:
            continue

        if dep not in provides:
            if d["required"]:
                errors.append(f"{owner} ({meta}) требует {dep} {d['range']} — мода нет в паке")
            elif not args.quiet_optional:
                warnings.append(f"{owner} ({meta}) может использовать {dep} — не установлен")
            continue

        have_ver, dep_side, dep_meta = provides[dep]
        if d["required"] and not in_range(have_ver, d["range"]):
            errors.append(
                f"{owner} ({meta}) требует {dep} {d['range']}, "
                f"в паке {have_ver} ({dep_meta})")

        if d["required"]:
            if (own_side == "both" and dep_side in ("client", "server")
                    and d["side"] == "BOTH"):
                errors.append(
                    f"{owner} ({meta}, side=both) требует {dep}, "
                    f"а {dep_meta} помечен side={dep_side}")

            own_fl = flavors.get(meta, set())
            dep_fl = flavors.get(dep_meta, set())
            if dep_fl and not own_fl:
                errors.append(
                    f"{owner} ({meta}) не привязан к флейворам, но требует {dep} "
                    f"из {sorted(dep_fl)} — сломается при отключении группы")
            elif dep_fl and own_fl and not own_fl <= dep_fl:
                errors.append(
                    f"{owner} ({meta}) во флейворах {sorted(own_fl)} требует {dep} "
                    f"из {sorted(dep_fl)} — комбинация {sorted(own_fl - dep_fl)} сломается")

    print(f"метафайлов: {len(entries)}   модов найдено: {len(provides)}   "
          f"зависимостей проверено: {len(requires)}")
    if loader_version:
        print(f"загрузчик из pack.toml: {loader_version}")
    print()

    if warnings and not args.quiet_optional:
        print(f"необязательные, отсутствуют ({len(warnings)}):")
        for w in sorted(set(warnings)):
            print(f"  · {w}")
        print()

    if errors:
        print(f"ОШИБКИ ({len(set(errors))}):")
        for e in sorted(set(errors)):
            print(f"  ✗ {e}")
        return 1

    print("Все обязательные зависимости на месте.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
