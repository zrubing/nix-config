---
name: tradingagents
description: 用于通过 TradingAgents 多智能体框架进行股票分析。支持搜索股票代码、使用 DeepSeek 模型进行基本面/技术面/情绪面多维度分析并生成交易决策。
---

# TradingAgents 股票分析

当用户要求分析股票、研究公司、获取交易建议、或使用 TradingAgents 进行多维度分析时，使用此技能。

## 核心能力

1. **股票搜索** — 通过公司名称搜索股票代码（支持全球市场）
2. **多智能体分析** — 调用 TradingAgents 框架进行基本面、技术面、情绪面、新闻面综合分析
3. **交易决策** — 生成包含买入/卖出/持有建议的完整分析报告

## 环境要求

使用 `nix develop ~/nix-config#trading` 进入预配置环境，该环境包含：

- Python 3.12 + TradingAgents 包
- 预配置的 DeepSeek API 密钥（通过 sops）
- 默认 LLM 提供商：`deepseek`

```bash
nix develop ~/nix-config#trading --command python3 <skill_dir>/scripts/trading_cli.py <command> [args]
```

### 支持模型

| 角色 | 模型 | 用途 |
|------|------|------|
| deep_think_llm | `deepseek/deepseek-v4-pro` | 复杂推理（分析师、研究员、投资组合经理） |
| quick_think_llm | `deepseek/deepseek-v4-flash` | 快速任务（新闻摘要、数据格式化） |

## CLI 使用

### 1. 搜索股票代码

```bash
nix develop ~/nix-config#trading --command \
  python3 <skill_dir>/scripts/trading_cli.py search "Apple"
```

输出：符号、名称、交易所、类型、行业等。

### 2. 分析股票

```bash
# 使用今天日期分析（默认 yfinance 数据源）
nix develop ~/nix-config#trading --command \
  python3 <skill_dir>/scripts/trading_cli.py analyze AAPL

# 指定分析日期 + Alpha Vantage 数据源（需 Premium 订阅）
nix develop ~/nix-config#trading --command \
  python3 <skill_dir>/scripts/trading_cli.py analyze NVDA --date 2025-06-13 --data-vendor alpha_vantage

# 指定模型
nix develop ~/nix-config#trading --command \
  python3 <skill_dir>/scripts/trading_cli.py analyze TSLA \
    --deep-model deepseek-v4-pro \
    --quick-model deepseek-v4-flash
```

### 3. Python 代码内联调用

```python
from tradingagents.graph.trading_graph import TradingAgentsGraph
from tradingagents.default_config import DEFAULT_CONFIG

config = DEFAULT_CONFIG.copy()
config["llm_provider"] = "deepseek"
config["deep_think_llm"] = "deepseek-v4-pro"
config["quick_think_llm"] = "deepseek-v4-flash"
config["max_debate_rounds"] = 1

ta = TradingAgentsGraph(debug=True, config=config)
_, decision = ta.propagate("NVDA", "2025-06-13")
print(decision)
```

### 全球股票代码格式

| 市场 | 示例 |
|------|------|
| 美国 | `AAPL`, `SPY`, `NVDA` |
| 香港 | `0700.HK` |
| 东京 | `7203.T` |
| 伦敦 | `AZN.L` |
| 印度 | `RELIANCE.NS`, `.BO` |
| 加拿大 | `SHOP.TO` |
| 澳大利亚 | `BHP.AX` |
| 中国A股(上海) | `600519.SS` |
| 中国A股(深圳) | `000001.SZ` |
| 加密货币 | `BTC-USD`, `ETH-USD` |

## 分析流程

TradingAgents 会按以下步骤执行（该流程无需用户干预）：

1. **基本面分析师** — 评估公司财务和业绩指标
2. **情绪分析师** — 汇总新闻、StockTwits、Reddit 情绪
3. **新闻分析师** — 监控全球新闻和宏观经济指标
4. **技术分析师** — 利用 MACD、RSI 等技术指标
5. **研究团队（看涨/看跌）** — 批判性评估分析师见解
6. **交易员** — 综合报告做出交易决策
7. **风险管理+投资组合经理** — 评估风险、批准/拒绝交易

## 注意事项

- 此框架仅供研究目的，**不构成财务、投资或交易建议**
- 分析结果受模型温度、数据质量、市场波动等非确定性因素影响
- 分析约需 2-5 分钟，取决于新闻量和辩论轮次
- 结果会保存到 `~/.tradingagents/logs/` 和 `~/.tradingagents/memory/trading_memory.md`
