#!/usr/bin/env python3
"""drain-config.py — single authoritative configuration resolver for task-drain.

Owns: defaults, YAML loading, env mapping, CLI overrides, type coercion,
validation, normalization, provenance. Shell (lib/config.sh) and the
TypeScript plugin adapter (plugin/src/drain-config.mjs) consume this same
contract via lib/config-schema.json. Do not reimplement defaults or
validation elsewhere.

Precedence (high to low): CLI --set key=value > environment > YAML > defaults.

Usage:
  drain-config.py resolve [--config PATH] [--set key=value ...] [--format json|exports|show]
  drain-config.py validate [--config PATH] [--set ...]
  drain-config.py defaults
  drain-config.py template
  drain-config.py path [--config PATH]

Exit codes: 0 ok, 2 invalid configuration, 1 operational error.

Security: stdlib only, no YAML deserialization beyond the strict subset
parser below (no exec/eval of YAML content, no anchors/aliases/tags).
Empty environment values are treated as unset (fall through to next layer).
Secrets (DRAIN_ERROR_WEBHOOK, FORGE_TOKEN) are never read from YAML and are
redacted in all output.
"""

import json
import os
import re
import sys

SCHEMA_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "config-schema.json"
)

TRUE_SET = {"1", "true", "yes", "on"}
FALSE_SET = {"0", "false", "no", "off"}

SENSITIVE_ENVS = {"DRAIN_ERROR_WEBHOOK", "FORGE_TOKEN"}


def load_schema():
    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def die(msg, code=1):
    print(f"drain-config: {msg}", file=sys.stderr)
    sys.exit(code)


# --- Strict YAML subset parser (stdlib only) ---
# Supports: nested maps via 2+ space indent, `key: value` scalars,
# `#` comments, quoted strings, null/bool/int. Rejects tabs, flow
# collections, anchors, aliases, tags, duplicate keys.


def parse_scalar(s):
    t = s.strip()
    if t in ("", "~", "null", "Null", "NULL"):
        return None
    low = t.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if len(t) >= 2 and t[0] == t[-1] and t[0] in ('"', "'"):
        inner = t[1:-1]
        if t[0] == "'":
            inner = inner.replace("''", "'")
        else:
            # minimal double-quote unescape
            inner = (
                inner.replace('\\"', '"')
                .replace("\\\\", "\\")
                .replace("\\n", "\n")
                .replace("\\t", "\t")
            )
        return inner
    if re.fullmatch(r"[+-]?\d+", t):
        try:
            return int(t)
        except ValueError:
            pass
    return t


def strip_inline_comment(s):
    in_s = None
    for i, ch in enumerate(s):
        if in_s:
            if ch == in_s:
                in_s = None
        elif ch in ('"', "'"):
            in_s = ch
        elif ch == "#":
            return s[:i].rstrip()
    return s.rstrip()


def parse_yaml_subset(path):
    """Return (data_dict_nested, error_string_or_None)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return {}, None
    except OSError as e:
        return None, f"cannot read config file {path}: {e}"
    root = {}
    # stack of (indent, dict)
    stack = [(-1, root)]
    # track per-dict key first-seen line for duplicate detection
    seen_stack = [set()]
    for lineno, raw in enumerate(lines, 1):
        if (
            "\t" in raw.split("#")[0]
            and raw.strip()
            and not raw.lstrip().startswith("#")
        ):
            # tabs for indentation are rejected
            stripped = raw.lstrip()
            if (
                raw[: len(raw) - len(stripped)]
                and "\t" in raw[: len(raw) - len(stripped)]
            ):
                return (
                    None,
                    f"{path}:{lineno}: tabs are not allowed for indentation (use spaces)",
                )
        line = raw.rstrip("\n")
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(stripped)
        content = strip_inline_comment(stripped)
        if not content:
            continue
        if content.startswith("- ") or content == "-":
            return (
                None,
                f"{path}:{lineno}: sequences are not supported in task-drain config (use maps)",
            )
        if content.startswith("?") or content.startswith(":"):
            return None, f"{path}:{lineno}: unsupported YAML construct"
        # anchor/alias/tag rejection
        nospace = content.replace(" ", "")
        if (
            "<<" in nospace
            or content.strip().startswith("*")
            or content.strip().startswith("&")
            or content.strip().startswith("!")
        ):
            return (
                None,
                f"{path}:{lineno}: anchors, aliases, and tags are not supported",
            )
        if ":" not in content:
            return None, f"{path}:{lineno}: expected 'key: value'"
        key, _, val = content.partition(":")
        key = key.strip()
        val = val.strip()
        if not key or not re.fullmatch(r"[A-Za-z0-9_.-]+", key):
            return None, f"{path}:{lineno}: invalid key {key!r} (use [A-Za-z0-9_.-])"
        if " " in key:
            return None, f"{path}:{lineno}: invalid key {key!r}"
        while stack and stack[-1][0] >= indent:
            stack.pop()
            seen_stack.pop()
        if not stack:
            return None, f"{path}:{lineno}: bad indentation"
        parent = stack[-1][1]
        seen = seen_stack[-1]
        if key in seen:
            # duplicate key at same level
            # compute dotted path for message
            return None, f"{path}:{lineno}: duplicate key {key!r}"
        seen.add(key)
        if val == "":
            child = {}
            parent[key] = child
            stack.append((indent, child))
            seen_stack.append(set())
        else:
            if val[:1] in ("&", "*", "!", "|", ">"):
                return None, f"{path}:{lineno}: anchors, aliases, tags, and block scalars are not supported"
            if val.startswith("{") or val.startswith("["):
                return None, f"{path}:{lineno}: flow collections are not supported"
            parent[key] = parse_scalar(val)
    return root, None


def flatten(nested, prefix=""):
    out = {}
    if isinstance(nested, dict):
        for k, v in nested.items():
            full = f"{prefix}.{k}" if prefix else k
            if isinstance(v, dict):
                out.update(flatten(v, full))
            else:
                out[full] = v
    return out


def normalize_hostname(v):
    if v is None:
        return None
    s = str(v).strip().lower().rstrip(".")
    return s if s else None


def host_match(configured, actual):
    """Short/FQDN equivalence without false positives. Dot-boundary only."""
    c = normalize_hostname(configured)
    a = normalize_hostname(actual)
    if not c or not a:
        return False
    if c == a:
        return True
    c_short = c.split(".")[0]
    a_short = a.split(".")[0]
    return c_short == a_short and c_short != ""


def parse_bool_env(raw):
    t = raw.strip().lower()
    if t in TRUE_SET:
        return True
    if t in FALSE_SET:
        return False
    return None  # signals invalid


def coerce_value(setting, raw, source_label):
    """Coerce raw (YAML typed or env/CLI string) to typed value. Returns (value, error)."""
    typ = setting["type"]
    key = setting["key"]
    if typ == "bool":
        if isinstance(raw, bool):
            return raw, None
        if isinstance(raw, int) and raw in (0, 1):
            return bool(raw), None
        if isinstance(raw, str):
            b = parse_bool_env(raw)
            if b is None:
                return (
                    None,
                    f"invalid boolean for {key} from {source_label}: {raw!r} (expected one of: 0/1, true/false, yes/no, on/off)",
                )
            return b, None
        return None, f"invalid boolean for {key} from {source_label}: {raw!r}"
    if typ == "int":
        if isinstance(raw, bool):
            return (
                None,
                f"invalid integer for {key} from {source_label}: {raw!r} (expected {setting.get('min')}..{setting.get('max')})",
            )
        if isinstance(raw, int):
            v = raw
        elif isinstance(raw, str):
            s = raw.strip()
            if not re.fullmatch(r"[+-]?\d+", s):
                return (
                    None,
                    f"invalid integer for {key} from {source_label}: {raw!r} (expected {setting.get('min')}..{setting.get('max')})",
                )
            v = int(s)
        else:
            return None, f"invalid integer for {key} from {source_label}: {raw!r}"
        lo, hi = setting.get("min"), setting.get("max")
        if (lo is not None and v < lo) or (hi is not None and v > hi):
            return (
                None,
                f"value {v} for {key} from {source_label} out of range (expected {lo}..{hi})",
            )
        return v, None
    if typ == "enum":
        if not isinstance(raw, str):
            return (
                None,
                f"invalid value for {key} from {source_label}: {raw!r} (expected one of: {', '.join(setting['enum'])})",
            )
        s = raw.strip()
        # agent enum is lowercase; logging level lowercase
        if s not in setting["enum"]:
            # try case-insensitive for logging level? No — strict.
            return (
                None,
                f"invalid value for {key} from {source_label}: {raw!r} (expected one of: {', '.join(setting['enum'])})",
            )
        return s, None
    if typ == "string":
        if not isinstance(raw, str):
            return None, f"invalid string for {key} from {source_label}: {raw!r}"
        s = raw
        # env strings: strip? keep as-is except strip surrounding whitespace? Preserve inner.
        if len(s) < setting.get("minLength", 0):
            return (
                None,
                f"value for {key} from {source_label} is too short (min {setting.get('minLength')})",
            )
        if "maxLength" in setting and len(s) > setting["maxLength"]:
            return (
                None,
                f"value for {key} from {source_label} is too long (max {setting.get('maxLength')})",
            )
        return s, None
    if typ == "path":
        if not isinstance(raw, str) or not raw.strip():
            return (
                None,
                f"invalid path for {key} from {source_label}: {raw!r} (expected non-empty string)",
            )
        return raw.strip(), None
    if typ == "path_or_null":
        if raw is None:
            return None, None
        if isinstance(raw, str) and raw.strip() == "":
            return None, None
        if not isinstance(raw, str):
            return None, f"invalid path for {key} from {source_label}: {raw!r}"
        return raw.strip(), None
    if typ == "hostname_or_null":
        if raw is None:
            return None, None
        if isinstance(raw, str) and raw.strip() == "":
            return None, None
        if not isinstance(raw, str):
            return None, f"invalid hostname for {key} from {source_label}: {raw!r}"
        h = normalize_hostname(raw)
        if not h or not re.fullmatch(r"[a-z0-9]([a-z0-9.-]*[a-z0-9])?", h):
            return None, f"invalid hostname for {key} from {source_label}: {raw!r}"
        return h, None
    return None, f"unknown type {typ} for {key}"


def default_config_path():
    return os.environ.get("DRAIN_CONFIG") or os.path.join(
        os.path.expanduser("~"), ".task-drain", "config.yaml"
    )


def resolve(config_path=None, cli_overrides=None, environ=None):
    """Full resolution. Returns (resolved_dict, errors_list).

    resolved_dict: key -> {value, source: default|yaml|environment|cli, sensitive}
    """
    schema = load_schema()
    settings = schema["settings"]
    by_key = {s["key"]: s for s in settings}
    env = environ if environ is not None else os.environ
    cfg_path = config_path or default_config_path()
    errors = []

    # YAML layer
    yaml_flat = {}
    yaml_present = os.path.exists(cfg_path)
    if yaml_present:
        nested, err = parse_yaml_subset(cfg_path)
        if err:
            return None, [err]
        if not isinstance(nested, dict):
            return None, [f"{cfg_path}: top level must be a map"]
        yaml_flat = flatten(nested)
        # unknown-key rejection (except map sections)
        allowed_tops = set(schema.get("map_sections", {}).get("allowed", []))
        known = set(by_key.keys())
        for full in yaml_flat:
            top = full.split(".")[0]
            if full in known:
                continue
            # map-section allowance: repos.*, remotes.*, default_remote
            if top in ("repos", "remotes"):
                # validate structure lightly: repos.<proj>.path|url strings; remotes.<n>.ssh|git_root strings
                parts = full.split(".")
                if top == "repos" and len(parts) == 3 and parts[2] in ("path", "url"):
                    v = yaml_flat[full]
                    if v is not None and not isinstance(v, str):
                        errors.append(
                            f"invalid value for {full} from yaml: expected string, got {v!r}"
                        )
                    continue
                if (
                    top == "remotes"
                    and len(parts) == 3
                    and parts[2] in ("ssh", "git_root")
                ):
                    v = yaml_flat[full]
                    if v is not None and not isinstance(v, str):
                        errors.append(
                            f"invalid value for {full} from yaml: expected string, got {v!r}"
                        )
                    continue
                errors.append(
                    f"unknown config key {full!r} from yaml (allowed under {top}: {', '.join(['path', 'url'] if top == 'repos' else ['ssh', 'git_root'])})"
                )
                continue
            if full == "default_remote":
                v = yaml_flat[full]
                if v is not None and not isinstance(v, str):
                    errors.append(
                        f"invalid value for default_remote from yaml: expected string, got {v!r}"
                    )
                continue
            errors.append(f"unknown config key {full!r} from yaml")
        if errors:
            return None, errors
        # validate map-section values that are present
        for full, v in yaml_flat.items():
            if full in known:
                continue
            if v is None:
                continue
    else:
        yaml_flat = {}

    # check YAML secret leakage: reject sensitive keys if ever added to YAML
    # (currently no sensitive settings have YAML keys, but guard anyway)
    for s in settings:
        if s.get("sensitive") and s["key"] in yaml_flat:
            errors.append(
                f"sensitive setting {s['key']} must not be stored in YAML (use environment)"
            )
    if errors:
        return None, errors

    cli_map = {}
    if cli_overrides:
        for item in cli_overrides:
            if "=" not in item:
                errors.append(f"invalid --set {item!r} (expected key=value)")
                continue
            k, _, v = item.partition("=")
            k = k.strip()
            if k not in by_key:
                errors.append(f"unknown config key {k!r} from cli")
                continue
            cli_map[k] = v
    if errors:
        return None, errors

    resolved = {}
    for key, setting in by_key.items():
        default = setting.get("default")
        # normalize default hostname
        if setting["type"] == "hostname_or_null" and isinstance(default, str):
            default = normalize_hostname(default)
        value = default
        source = "default"
        # YAML layer
        if key in yaml_flat:
            raw = yaml_flat[key]
            # YAML null for nullable types means unset -> default
            if raw is None and setting["type"] in ("hostname_or_null", "path_or_null"):
                pass
            else:
                coerced, err = coerce_value(setting, raw, "yaml")
                if err:
                    errors.append(err)
                    continue
                value = coerced
                source = "yaml"
        # env layer (incl. aliases, legacy DRAIN_DEBUG for logging.level)
        env_raw = None
        env_name = None
        primary_env = setting.get("env")
        candidates = []
        if primary_env:
            candidates.append(primary_env)
        for a in setting.get("env_aliases", []):
            candidates.append(a)
        seen_vals = {}
        for name in candidates:
            if name in env and env[name] != "":
                seen_vals[name] = env[name]
        generic_name = "DRAIN_CONFIG_" + key.upper().replace(".", "_")
        if generic_name in env and env[generic_name] != "" and generic_name != "DRAIN_CONFIG":
            if generic_name not in seen_vals:
                seen_vals[generic_name] = env[generic_name]
        if len(seen_vals) > 1:
            vals = set(seen_vals.values())
            if len(vals) > 1:
                errors.append(
                    f"conflicting environment aliases for {key}: "
                    + ", ".join(f"{n}={v!r}" for n, v in sorted(seen_vals.items()))
                    + " (set only one)"
                )
                continue
            # same value twice: prefer primary
            env_raw = (
                seen_vals[primary_env]
                if primary_env in seen_vals
                else list(seen_vals.values())[0]
            )
            env_name = (
                primary_env if primary_env in seen_vals else sorted(seen_vals.keys())[0]
            )
        elif len(seen_vals) == 1:
            env_name, env_raw = next(iter(seen_vals.items()))
        # legacy DRAIN_DEBUG=1 maps to logging.level=debug (only when level not otherwise set via env)
        if (
            key == "logging.level"
            and env_raw is None
            and env.get("DRAIN_DEBUG", "") != ""
        ):
            dbg = env.get("DRAIN_DEBUG", "")
            b = parse_bool_env(dbg) if isinstance(dbg, str) else None
            if b is None:
                errors.append(
                    f"invalid boolean for logging.level from environment (DRAIN_DEBUG): {dbg!r}"
                )
                continue
            if b is True:
                env_raw = "debug"
                env_name = "DRAIN_DEBUG"
        # TASK_AUTO_SYNC special: "0" disables, anything else enables? Strict: use bool parsing.
        # Empty already filtered. "0"->False handled by generic bool coercion.
        if env_raw is not None:
            coerced, err = coerce_value(setting, env_raw, f"environment ({env_name})")
            if err:
                errors.append(err)
                continue
            value = coerced
            source = "environment"
        # CLI layer
        if key in cli_map:
            coerced, err = coerce_value(setting, cli_map[key], "cli")
            if err:
                errors.append(err)
                continue
            value = coerced
            source = "cli"
        # dynamic defaults for paths.task_bin fallback handled by consumers? Keep "task" and let shell expand.
        resolved[key] = {
            "value": value,
            "source": source,
            "sensitive": bool(setting.get("sensitive", False)),
        }
    # cross-field validation
    if "supervisor.min_workers" in resolved and "supervisor.max_workers" in resolved:
        mn = resolved["supervisor.min_workers"]["value"]
        mx = resolved["supervisor.max_workers"]["value"]
        if isinstance(mn, int) and isinstance(mx, int) and mn > mx:
            errors.append(
                f"supervisor.min_workers ({mn}) cannot exceed supervisor.max_workers ({mx})"
            )
    if errors:
        return None, errors
    maps = {k: v for k, v in yaml_flat.items() if k not in by_key}
    return {
        "values": resolved,
        "config_path": cfg_path,
        "config_present": yaml_present,
        "maps": maps,
    }, []


def redact_for_display(resolved):
    out = []
    for key in sorted(resolved["values"].keys()):
        entry = resolved["values"][key]
        v = entry["value"]
        if entry.get("sensitive"):
            disp = "***"
        elif v is None:
            disp = "(unset)"
        elif isinstance(v, bool):
            disp = "true" if v else "false"
        else:
            disp = str(v)
        out.append((key, disp, entry["source"]))
    return out


def cmd_resolve(args):
    import argparse

    p = argparse.ArgumentParser(prog="drain-config resolve")
    p.add_argument("--config", default=None)
    p.add_argument("--set", action="append", default=[], dest="sets")
    p.add_argument("--format", default="json", choices=["json", "exports", "show"])
    ns = p.parse_args(args)
    result, errors = resolve(config_path=ns.config, cli_overrides=ns.sets)
    if errors:
        for e in errors:
            print(f"drain-config: error: {e}", file=sys.stderr)
        sys.exit(2)
    if ns.format == "json":
        flat = {k: v["value"] for k, v in result["values"].items()}
        prov = {k: v["source"] for k, v in result["values"].items()}
        print(
            json.dumps(
                {
                    "values": flat,
                    "sources": prov,
                    "config_path": result["config_path"],
                    "config_present": result["config_present"],
                    "maps": result.get("maps", {}),
                }
            )
        )
    elif ns.format == "exports":
        for k, v in sorted(result["values"].items()):
            entry = v
            val = entry["value"]
            if isinstance(val, bool):
                s = "1" if val else "0"
            elif val is None:
                s = ""
            else:
                s = str(val)
            s = s.replace("'", "'\\''")
            var = "DRAIN_RESOLVED_" + k.upper().replace(".", "_")
            print(f"{var}='{s}'")
            print(f"{var}__SOURCE='{entry['source']}'")
        print(f"DRAIN_RESOLVED_CONFIG_PATH='{result['config_path']}'")
        print(
            f"DRAIN_RESOLVED_CONFIG_PRESENT='{'1' if result['config_present'] else '0'}'"
        )
    else:
        for key, disp, src in redact_for_display(result):
            print(f"{key:<42} {disp:<30} {src}")


def cmd_validate(args):
    import argparse

    p = argparse.ArgumentParser(prog="drain-config validate")
    p.add_argument("--config", default=None)
    p.add_argument("--set", action="append", default=[], dest="sets")
    ns = p.parse_args(args)
    _, errors = resolve(config_path=ns.config, cli_overrides=ns.sets)
    if errors:
        for e in errors:
            # never echo secret values: coerce errors already use repr of raw;
            # redact if the key is sensitive or env name is sensitive
            msg = e
            for s in SENSITIVE_ENVS:
                if s in msg:
                    msg = re.sub(r"=.*", "=***", msg)
            print(f"drain-config: error: {msg}", file=sys.stderr)
        sys.exit(2)
    print("configuration valid")


def cmd_defaults(_args):
    schema = load_schema()
    print("# task-drain configuration template (generated by `drain config defaults`)")
    print(
        "# Copy to ~/.task-drain/config.yaml and edit. Missing file = defaults below."
    )
    print("# Docs: docs/configuration.md")
    print("")
    # group by section
    sections = {}
    for s in schema["settings"]:
        top = s["key"].split(".")[0]
        sections.setdefault(top, []).append(s)
    order = [
        "worker",
        "supervisor",
        "sync",
        "locks",
        "history",
        "display",
        "logging",
        "paths",
        "task",
    ]
    for top in order + [k for k in sections if k not in order]:
        if top not in sections:
            continue
        print(f"{top}:")
        for s in sections[top]:
            default = s.get("default")
            if isinstance(default, bool):
                d = "true" if default else "false"
            elif default is None:
                d = '""  # unset'
                print(
                    f"  # {s['key'].split('.', 1)[1]}: {s['description']} [env {s.get('env')}]"
                )
                print(f"  # {s['key'].split('.', 1)[1]}: {d}")
                continue
            elif isinstance(default, str) and default.startswith("$HOME"):
                d = f'"{default}"'
            elif isinstance(default, str):
                d = (
                    f'"{default}"'
                    if " " in default or "/" in default or "." in default
                    else default
                )
            else:
                d = str(default)
            extra = ""
            if s["type"] == "int":
                extra = f"  # range {s.get('min')}..{s.get('max')}"
            elif s["type"] == "enum":
                extra = f"  # one of: {', '.join(s['enum'])}"
            print(
                f"  # {s['key'].split('.', 1)[1]}: {s['description']} [env {s.get('env')}]"
            )
            print(f"  {s['key'].split('.', 1)[1]}: {d}{extra}")
        print("")


def cmd_template(_args):
    # machine-readable template: valid YAML with defaults
    schema = load_schema()
    grouped = {}
    for s in schema["settings"]:
        top, _, rest = s["key"].partition(".")
        grouped.setdefault(top, {})[rest] = s.get("default")
    lines = []
    for top in [
        "worker",
        "supervisor",
        "sync",
        "locks",
        "history",
        "display",
        "logging",
        "paths",
        "task",
    ]:
        if top not in grouped:
            continue
        lines.append(f"{top}:")
        for k, v in grouped[top].items():
            if isinstance(v, bool):
                lines.append(f"  {k}: {'true' if v else 'false'}")
            elif v is None:
                lines.append(f'  # {k}: ""')
            elif isinstance(v, str):
                q = f'"{v}"' if any(c in v for c in " /#:.") or v == "" else v
                lines.append(f"  {k}: {q}")
            else:
                lines.append(f"  {k}: {v}")
    print("\n".join(lines) + "\n")


def cmd_match_host(args):
    import argparse
    p = argparse.ArgumentParser(prog="drain-config match-host")
    p.add_argument("--configured", required=True)
    p.add_argument("--actual", required=True)
    ns = p.parse_args(args)
    import sys as _sys
    _sys.exit(0 if host_match(ns.configured, ns.actual) else 1)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd, rest = argv[1], argv[2:]
    if cmd == "match-host":
        cmd_match_host(rest)
    elif cmd == "resolve":
        cmd_resolve(rest)
    elif cmd == "validate":
        cmd_validate(rest)
    elif cmd == "defaults":
        cmd_defaults(rest)
    elif cmd == "template":
        cmd_template(rest)
    elif cmd == "path":
        import argparse

        p = argparse.ArgumentParser()
        p.add_argument("--config", default=None)
        ns = p.parse_args(rest)
        print(ns.config or default_config_path())
    else:
        die(f"unknown command: {cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
