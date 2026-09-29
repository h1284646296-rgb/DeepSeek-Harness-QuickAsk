#!/usr/bin/env node
/**
 * 模型目录提取器。
 *
 * 从 `$DSH_HOME/settings.yaml` 和 DeepSeek 适配器的内置目录里，抽出「哪些模型可选、
 * 每个模型支持哪些推理档位」，输出一份 JSON 给 DSH Quick Ask 的面板用。
 *
 *   node tools/model-catalog.js <settings.yaml> <dsh 入口 bin.js>
 *
 * 只用 Node（dsh 自己就依赖 js-yaml，所以它一定在机器上），不引入任何新依赖。
 */
"use strict";

const fs = require("fs");
const path = require("path");

const settingsPath = process.argv[2] || path.join(process.env.HOME || "", ".dsh", "settings.yaml");
const dshEntry = process.argv[3] || "";

/** js-yaml 跟着 dsh 一起装：从 dsh 入口逐级向上找 node_modules。 */
function loadYaml() {
  const bases = [];
  let dir = dshEntry ? path.dirname(dshEntry) : process.cwd();
  for (let depth = 0; depth < 8 && dir && dir !== "/"; depth += 1) {
    bases.push(dir);
    dir = path.dirname(dir);
  }
  bases.push(process.cwd());
  for (const base of bases) {
    try {
      return require(require.resolve("js-yaml", { paths: [base] }));
    } catch (_error) {
      /* 换下一个候选 */
    }
  }
  return null;
}

/** DeepSeek 内置适配器的默认模型（与 dsh-llm-deepseek 的 DEFAULT_MODELS 对齐）。 */
const DEEPSEEK_FALLBACK = [
  { model: "deepseek-flash", name: "DeepSeek-V41-Flash" },
  { model: "deepseek-v4-flash", name: "DeepSeek-V4-Flash" },
  { model: "deepseek-v4-pro", name: "DeepSeek-V4-Pro" },
  { model: "deepseek-v4-flash-vision-exp", name: "DeepSeek-V4-Flash-Vision-Exp" },
];

/** DeepSeek 原生适配器接受的推理档位（见 dsh-llm-deepseek 的 Config.reasoningEffort）。 */
const DEEPSEEK_EFFORTS = ["off", "low", "high", "max"];

/**
 * 把设置里的 `reasoningEfforts` 归一成字符串数组。
 * - `false`  → 只支持关闭（适配器对非推理模型只接受 off）
 * - 对象     → 取其键名（qwen 那种 off/minimal/…/max 的阶梯）
 * - 数组     → 原样
 * - 缺失     → null，表示「未知」，面板上显示「默认」且不发送该参数
 */
function effortList(raw, fallback) {
  if (raw === false) return ["off"];
  if (Array.isArray(raw)) return raw.filter((item) => typeof item === "string");
  if (raw && typeof raw === "object") return Object.keys(raw);
  return fallback === undefined ? null : fallback;
}

function main() {
  const yaml = loadYaml();
  let doc = {};
  let warning = null;

  if (!yaml) {
    warning = "找不到 js-yaml（跟着 dsh 安装），只输出内置模型列表";
  } else if (!fs.existsSync(settingsPath)) {
    warning = `没有 ${settingsPath}，只输出内置模型列表`;
  } else {
    try {
      doc = yaml.load(fs.readFileSync(settingsPath, "utf8")) || {};
    } catch (error) {
      warning = `settings.yaml 解析失败：${error.message}`;
      doc = {};
    }
  }

  const models = [];

  // 1) DeepSeek 原生路由
  const deepseek = doc["llm-deepseek"];
  if (deepseek && Array.isArray(deepseek.models) && deepseek.models.length > 0) {
    for (const entry of deepseek.models) {
      if (!entry || !entry.id) continue;
      models.push({
        provider: "deepseek-official",
        model: String(entry.id),
        name: String(entry.name || entry.id),
        efforts: effortList(entry.reasoningEfforts, effortList(deepseek.reasoningEffort, DEEPSEEK_EFFORTS)),
      });
    }
  } else {
    for (const entry of DEEPSEEK_FALLBACK) {
      models.push({
        provider: "deepseek-official",
        model: entry.model,
        name: entry.name,
        efforts: DEEPSEEK_EFFORTS,
      });
    }
  }

  // 2) pi-ai 多provider（百炼、Ollama …）
  const piProviders = doc["llm-pi-ai"] && doc["llm-pi-ai"].providers;
  if (piProviders && typeof piProviders === "object") {
    for (const key of Object.keys(piProviders)) {
      const provider = piProviders[key];
      if (!provider || !Array.isArray(provider.models)) continue;
      const display = provider.displayName || key;
      for (const entry of provider.models) {
        if (!entry || !entry.id) continue;
        models.push({
          provider: key,
          model: String(entry.id),
          name: `${String(entry.name || entry.id)} · ${display}`,
          efforts: effortList(entry.reasoningEfforts),
        });
      }
    }
  }

  const current = doc["agent-default-model"] || null;
  process.stdout.write(
    JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        settingsPath,
        warning,
        current: current
          ? { provider: current.provider, model: current.model, effort: current.reasoningEffort || null }
          : null,
        models,
      },
      null,
      2
    ) + "\n"
  );
}

main();
