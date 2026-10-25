/**
 * drain-config.mjs — TypeScript/JS adapter over the canonical configuration contract.
 *
 * The authoritative definitions live in lib/config-schema.json (keys, types,
 * defaults, env mappings, ranges) and the authoritative resolver is
 * lib/drain-config.py. This module implements the SAME semantics in
 * dependency-free JavaScript for the separately-deployed plugin package:
 * identical precedence (CLI options > environment > YAML > defaults),
 * identical type coercion, validation, hostname normalization, and provenance.
 *
 * Cross-language consistency is enforced by shared fixtures in
 * tests/fixtures/config/ exercised by both tests/test-config.bats (shell)
 * and plugin/tests/drain-config.test.mjs (JS). Do not change semantics here
 * without updating lib/drain-config.py and the shared fixtures.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import os from "node:os";

const TRUE_SET = new Set(["1", "true", "yes", "on"]);
const FALSE_SET = new Set(["0", "false", "no", "off"]);

function schemaCandidates() {
  const here = dirname(fileURLToPath(import.meta.url));
  return [
    join(here, "config-schema.json"), // published copy
    join(here, "..", "config-schema.json"),
    join(here, "..", "..", "lib", "config-schema.json"), // monorepo dev
    "/Users/lou/git/task-drain/lib/config-schema.json",
  ];
}

export function loadSchema(schemaPath) {
  const candidates = schemaPath ? [schemaPath] : schemaCandidates();
  for (const p of candidates) {
    try {
      if (existsSync(p)) return JSON.parse(readFileSync(p, "utf8"));
    } catch {
      // try next
    }
  }
  throw new Error("config schema not found (tried: " + candidates.join(", ") + ")");
}

export function defaultConfigPath(env = process.env) {
  return env.DRAIN_CONFIG || join(os.homedir(), ".task-drain", "config.yaml");
}

// --- strict YAML subset parser (mirrors lib/drain-config.py) ---
function parseScalar(s) {
  const t = s.trim();
  if (t === "" || t === "~" || t === "null" || t === "Null" || t === "NULL") return null;
  const low = t.toLowerCase();
  if (low === "true" || low === "yes" || low === "on") return true;
  if (low === "false" || low === "no" || low === "off") return false;
  if (t.length >= 2 && ((t[0] === '"' && t[t.length - 1] === '"') || (t[0] === "'" && t[t.length - 1] === "'"))) {
    let inner = t.slice(1, -1);
    if (t[0] === "'") inner = inner.replace(/''/g, "'");
    else inner = inner.replace(/\\"/g, '"').replace(/\\\\/g, "\\").replace(/\\n/g, "\n").replace(/\\t/g, "\t");
    return inner;
  }
  if (/^[+-]?\d+$/.test(t)) return parseInt(t, 10);
  return t;
}

function stripInlineComment(s) {
  let inS = null;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (inS) {
      if (ch === inS) inS = null;
    } else if (ch === '"' || ch === "'") inS = ch;
    else if (ch === "#") return s.slice(0, i).replace(/\s+$/, "");
  }
  return s.replace(/\s+$/, "");
}

export function parseYamlSubset(text, path = "<config>") {
  const root = {};
  const stack = [{ indent: -1, obj: root }];
  const seenStack = [new Set()];
  const lines = text.split("\n");
  for (let ln = 0; ln < lines.length; ln++) {
    const raw = lines[ln];
    const lineno = ln + 1;
    const stripped0 = raw.replace(/^\s*/, "");
    if (!stripped0 || stripped0.startsWith("#")) continue;
    const indent = raw.length - raw.replace(/^\s*/, "").length;
    const indentStr = raw.slice(0, indent);
    if (indentStr.includes("\t")) throw new Error(`${path}:${lineno}: tabs are not allowed for indentation (use spaces)`);
    let content = stripInlineComment(raw.trim());
    if (!content) continue;
    if (content.startsWith("- ") || content === "-") throw new Error(`${path}:${lineno}: sequences are not supported in task-drain config (use maps)`);
    if (content.startsWith("?") || content.startsWith(":") || content.trimStart().startsWith("*") || content.trimStart().startsWith("&") || content.trimStart().startsWith("!")) {
      throw new Error(`${path}:${lineno}: anchors, aliases, and tags are not supported`);
    }
    const ci = content.indexOf(":");
    if (ci === -1) throw new Error(`${path}:${lineno}: expected 'key: value'`);
    const key = content.slice(0, ci).trim();
    const val = content.slice(ci + 1).trim();
    if (!key || !/^[A-Za-z0-9_.-]+$/.test(key)) throw new Error(`${path}:${lineno}: invalid key ${JSON.stringify(key)} (use [A-Za-z0-9_.-])`);
    while (stack.length && stack[stack.length - 1].indent >= indent) {
      stack.pop();
      seenStack.pop();
    }
    if (!stack.length) throw new Error(`${path}:${lineno}: bad indentation`);
    const parent = stack[stack.length - 1].obj;
    const seen = seenStack[seenStack.length - 1];
    if (seen.has(key)) throw new Error(`${path}:${lineno}: duplicate key ${JSON.stringify(key)}`);
    seen.add(key);
    if (val === "") {
      const child = {};
      parent[key] = child;
      stack.push({ indent, obj: child });
      seenStack.push(new Set());
    } else {
      if (["&", "*", "!", "|", ">"].includes(val[0])) throw new Error(`${path}:${lineno}: anchors, aliases, tags, and block scalars are not supported`);
      if (val.startsWith("{") || val.startsWith("[")) throw new Error(`${path}:${lineno}: flow collections are not supported`);
      if (/\s<<\s/.test(" " + val + " ")) throw new Error(`${path}:${lineno}: anchors, aliases, and tags are not supported`);
      parent[key] = parseScalar(val);
    }
  }
  return root;
}

export function flatten(nested, prefix = "") {
  const out = {};
  for (const [k, v] of Object.entries(nested)) {
    const full = prefix ? `${prefix}.${k}` : k;
    if (v !== null && typeof v === "object" && !Array.isArray(v)) Object.assign(out, flatten(v, full));
    else out[full] = v;
  }
  return out;
}

export function normalizeHostname(v) {
  if (v == null) return null;
  const s = String(v).trim().toLowerCase().replace(/\.+$/, "");
  return s || null;
}

export function hostMatch(configured, actual) {
  const c = normalizeHostname(configured);
  const a = normalizeHostname(actual);
  if (!c || !a) return false;
  if (c === a) return true;
  return c.split(".")[0] === a.split(".")[0] && c.split(".")[0] !== "";
}

function parseBoolEnv(raw) {
  const t = String(raw).trim().toLowerCase();
  if (TRUE_SET.has(t)) return true;
  if (FALSE_SET.has(t)) return false;
  return undefined; // invalid marker
}

export function coerceValue(setting, raw, sourceLabel) {
  const typ = setting.type;
  const key = setting.key;
  if (typ === "bool") {
    if (typeof raw === "boolean") return raw;
    if (typeof raw === "number" && (raw === 0 || raw === 1)) return Boolean(raw);
    if (typeof raw === "string") {
      const b = parseBoolEnv(raw);
      if (b === undefined) throw new Error(`invalid boolean for ${key} from ${sourceLabel}: ${JSON.stringify(raw)} (expected one of: 0/1, true/false, yes/no, on/off)`);
      return b;
    }
    throw new Error(`invalid boolean for ${key} from ${sourceLabel}: ${JSON.stringify(raw)}`);
  }
  if (typ === "int") {
    let v;
    if (typeof raw === "boolean") throw new Error(`invalid integer for ${key} from ${sourceLabel}: ${JSON.stringify(raw)} (expected ${setting.min}..${setting.max})`);
    if (typeof raw === "number" && Number.isInteger(raw)) v = raw;
    else if (typeof raw === "string" && /^[+-]?\d+$/.test(raw.trim())) v = parseInt(raw.trim(), 10);
    else throw new Error(`invalid integer for ${key} from ${sourceLabel}: ${JSON.stringify(raw)} (expected ${setting.min}..${setting.max})`);
    if ((setting.min != null && v < setting.min) || (setting.max != null && v > setting.max)) {
      throw new Error(`value ${v} for ${key} from ${sourceLabel} out of range (expected ${setting.min}..${setting.max})`);
    }
    return v;
  }
  if (typ === "enum") {
    if (typeof raw !== "string" || !setting.enum.includes(raw.trim())) {
      throw new Error(`invalid value for ${key} from ${sourceLabel}: ${JSON.stringify(raw)} (expected one of: ${setting.enum.join(", ")})`);
    }
    return raw.trim();
  }
  if (typ === "string") {
    if (typeof raw !== "string") throw new Error(`invalid string for ${key} from ${sourceLabel}: ${JSON.stringify(raw)}`);
    if (raw.length < (setting.minLength ?? 0)) throw new Error(`value for ${key} from ${sourceLabel} is too short (min ${setting.minLength})`);
    if (setting.maxLength != null && raw.length > setting.maxLength) throw new Error(`value for ${key} from ${sourceLabel} is too long (max ${setting.maxLength})`);
    return raw;
  }
  if (typ === "path") {
    if (typeof raw !== "string" || !raw.trim()) throw new Error(`invalid path for ${key} from ${sourceLabel}: ${JSON.stringify(raw)} (expected non-empty string)`);
    return raw.trim();
  }
  if (typ === "path_or_null") {
    if (raw == null) return null;
    if (typeof raw === "string" && raw.trim() === "") return null;
    if (typeof raw !== "string") throw new Error(`invalid path for ${key} from ${sourceLabel}: ${JSON.stringify(raw)}`);
    return raw.trim();
  }
  if (typ === "hostname_or_null") {
    if (raw == null) return null;
    if (typeof raw === "string" && raw.trim() === "") return null;
    if (typeof raw !== "string") throw new Error(`invalid hostname for ${key} from ${sourceLabel}: ${JSON.stringify(raw)}`);
    const h = normalizeHostname(raw);
    if (!h || !/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/.test(h)) throw new Error(`invalid hostname for ${key} from ${sourceLabel}: ${JSON.stringify(raw)}`);
    return h;
  }
  throw new Error(`unknown type ${typ} for ${key}`);
}

/**
 * Resolve configuration. Options:
 * { configPath, cli (object key->string raw), environ, schema, readFile }
 * Returns { values, sources, configPath, configPresent, maps } or throws Error
 * aggregating all validation errors (message joined by "\n").
 */
export function resolveDrainConfig(opts = {}) {
  const schema = opts.schema || loadSchema(opts.schemaPath);
  const byKey = Object.fromEntries(schema.settings.map((s) => [s.key, s]));
  const env = opts.environ || process.env;
  const cfgPath = opts.configPath || defaultConfigPath(env);
  const readFile = opts.readFile || ((p) => readFileSync(p, "utf8"));
  const errors = [];
  let yamlFlat = {};
  let configPresent = existsSync(cfgPath);
  if (opts.yamlText != null) {
    configPresent = true;
    try {
      yamlFlat = flatten(parseYamlSubset(opts.yamlText, cfgPath));
    } catch (e) {
      throw new Error(e.message);
    }
  } else if (configPresent) {
    try {
      yamlFlat = flatten(parseYamlSubset(readFile(cfgPath), cfgPath));
    } catch (e) {
      throw new Error(e.message);
    }
  }
  // unknown-key rejection
  const known = new Set(Object.keys(byKey));
  for (const full of Object.keys(yamlFlat)) {
    const top = full.split(".")[0];
    if (known.has(full)) continue;
    if (top === "repos" || top === "remotes") {
      const parts = full.split(".");
      if (top === "repos" && parts.length === 3 && ["path", "url"].includes(parts[2])) {
        const v = yamlFlat[full];
        if (v != null && typeof v !== "string") errors.push(`invalid value for ${full} from yaml: expected string, got ${JSON.stringify(v)}`);
        continue;
      }
      if (top === "remotes" && parts.length === 3 && ["ssh", "git_root"].includes(parts[2])) {
        const v = yamlFlat[full];
        if (v != null && typeof v !== "string") errors.push(`invalid value for ${full} from yaml: expected string, got ${JSON.stringify(v)}`);
        continue;
      }
      errors.push(`unknown config key ${JSON.stringify(full)} from yaml (allowed under ${top}: ${top === "repos" ? "path, url" : "ssh, git_root"})`);
      continue;
    }
    if (full === "default_remote") {
      const v = yamlFlat[full];
      if (v != null && typeof v !== "string") errors.push(`invalid value for default_remote from yaml: expected string, got ${JSON.stringify(v)}`);
      continue;
    }
    errors.push(`unknown config key ${JSON.stringify(full)} from yaml`);
  }
  if (errors.length) throw new Error(errors.join("\n"));
  for (const s of schema.settings) {
    if (s.sensitive && s.key in yamlFlat) errors.push(`sensitive setting ${s.key} must not be stored in YAML (use environment)`);
  }
  if (errors.length) throw new Error(errors.join("\n"));

  const cli = opts.cli || {};
  for (const k of Object.keys(cli)) {
    if (!byKey[k]) errors.push(`unknown config key ${JSON.stringify(k)} from cli`);
  }
  if (errors.length) throw new Error(errors.join("\n"));

  const values = {};
  const sources = {};
  for (const [key, setting] of Object.entries(byKey)) {
    let value = setting.default;
    if (setting.type === "hostname_or_null" && typeof value === "string") value = normalizeHostname(value);
    let source = "default";
    try {
      if (key in yamlFlat) {
        const raw = yamlFlat[key];
        if (!(raw == null && ["hostname_or_null", "path_or_null"].includes(setting.type))) {
          value = coerceValue(setting, raw, "yaml");
          source = "yaml";
        }
      }
      // env layer
      const candidates = [];
      if (setting.env) candidates.push(setting.env);
      for (const a of setting.env_aliases || []) candidates.push(a);
      const seen = {};
      for (const n of candidates) {
        if (env[n] != null && env[n] !== "") seen[n] = env[n];
      }
      const generic = "DRAIN_CONFIG_" + key.toUpperCase().replace(/\./g, "_");
      if (env[generic] != null && env[generic] !== "" && generic !== "DRAIN_CONFIG" && !(generic in seen)) seen[generic] = env[generic];
      const names = Object.keys(seen);
      let envRaw;
      let envName;
      if (names.length > 1) {
        if (new Set(Object.values(seen)).size > 1) throw new Error(`conflicting environment aliases for ${key}: ${names.sort().map((n) => `${n}=${JSON.stringify(seen[n])}`).join(", ")} (set only one)`);
        envName = setting.env && setting.env in seen ? setting.env : names.sort()[0];
        envRaw = seen[envName];
      } else if (names.length === 1) {
        envName = names[0];
        envRaw = seen[envName];
      }
      if (key === "logging.level" && envRaw === undefined && (env.DRAIN_DEBUG ?? "") !== "") {
        const b = parseBoolEnv(env.DRAIN_DEBUG);
        if (b === undefined) throw new Error(`invalid boolean for logging.level from environment (DRAIN_DEBUG): ${JSON.stringify(env.DRAIN_DEBUG)}`);
        if (b === true) {
          envRaw = "debug";
          envName = "DRAIN_DEBUG";
        }
      }
      if (envRaw !== undefined) {
        value = coerceValue(setting, envRaw, `environment (${envName})`);
        source = "environment";
      }
      if (key in cli) {
        value = coerceValue(setting, cli[key], "cli");
        source = "cli";
      }
    } catch (e) {
      errors.push(e.message);
      continue;
    }
    values[key] = value;
    sources[key] = source;
  }
  if ("supervisor.min_workers" in values && "supervisor.max_workers" in values) {
    const mn = values["supervisor.min_workers"];
    const mx = values["supervisor.max_workers"];
    if (Number.isInteger(mn) && Number.isInteger(mx) && mn > mx) errors.push(`supervisor.min_workers (${mn}) cannot exceed supervisor.max_workers (${mx})`);
  }
  if (errors.length) throw new Error(errors.join("\n"));
  const maps = Object.fromEntries(Object.entries(yamlFlat).filter(([k]) => !known.has(k)));
  return { values, sources, configPath: cfgPath, configPresent, maps };
}
