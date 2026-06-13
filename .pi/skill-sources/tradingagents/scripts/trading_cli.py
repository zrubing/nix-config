#!/usr/bin/env python3
"""
TradingAgents CLI — stock search, multi-agent analysis, and utilities.

Usage:
  trading_cli.py search <query>              # Search for stock tickers
  trading_cli.py analyze <ticker> [options]   # Run multi-agent analysis
  trading_cli.py list-models [--provider]     # List available LLM models
  trading_cli.py history [--last N]           # View past analysis decisions
  trading_cli.py config                       # Show current configuration
  trading_cli.py cache [--clear]              # Manage data cache
"""

import argparse
import json
import os
import shutil
import sys
from datetime import date, datetime
from pathlib import Path


# ---------------------------------------------------------------------------
# Stock Search
# ---------------------------------------------------------------------------

def cmd_search(args: argparse.Namespace) -> int:
    """Search for stock tickers by company name using yfinance."""
    try:
        import yfinance as yf
    except ImportError:
        print("ERROR: yfinance not available. Run in 'nix develop ~/nix-config#trading'.", file=sys.stderr)
        return 1

    query = args.query
    print(f"Searching for: {query}\n")

    try:
        s = yf.Search(query)
    except Exception as e:
        print(f"Search failed: {e}", file=sys.stderr)
        return 1

    quotes = s.quotes
    if not quotes:
        print("No results found.")
        return 0

    max_results = args.max_results
    for i, q in enumerate(quotes[:max_results]):
        symbol = q.get("symbol", "N/A")
        name = q.get("shortname") or q.get("longname") or "N/A"
        exchange = q.get("exchange", "N/A")
        quote_type = q.get("quoteType", "N/A")
        sector = q.get("sector", "")
        industry = q.get("industry", "")

        print(f"{i+1:2d}. {symbol:15s} {name}")
        print(f"    Exchange: {exchange}  Type: {quote_type}", end="")
        if sector:
            print(f"  Sector: {sector}", end="")
        if industry:
            print(f" / {industry}", end="")
        print()
        print()

    if len(quotes) > max_results:
        print(f"... and {len(quotes) - max_results} more results (use --max-results to show more)")

    return 0


# ---------------------------------------------------------------------------
# Stock Analysis
# ---------------------------------------------------------------------------

def cmd_analyze(args: argparse.Namespace) -> int:
    """Analyze a stock using TradingAgents multi-agent framework."""
    try:
        from tradingagents.graph.trading_graph import TradingAgentsGraph
        from tradingagents.default_config import DEFAULT_CONFIG
    except ImportError:
        print("ERROR: tradingagents not available. Run in 'nix develop ~/nix-config#trading'.", file=sys.stderr)
        return 1

    ticker = args.ticker.upper()
    analysis_date = args.date or date.today().isoformat()

    # Build config
    config = DEFAULT_CONFIG.copy()
    config["llm_provider"] = args.provider or "deepseek"
    config["deep_think_llm"] = args.deep_model or "deepseek-v4-pro"
    config["quick_think_llm"] = args.quick_model or "deepseek-v4-flash"

    # Data vendor switch
    if args.data_vendor:
        config["data_vendors"] = {
            "core_stock_apis": args.data_vendor,
            "technical_indicators": args.data_vendor,
            "fundamental_data": args.data_vendor,
            "news_data": args.data_vendor,
        }
    config["max_debate_rounds"] = args.debate_rounds
    config["max_risk_discuss_rounds"] = args.risk_rounds

    if args.temperature is not None:
        config["temperature"] = args.temperature

    if args.language:
        config["output_language"] = args.language

    print(f"╔══════════════════════════════════════════════════════════╗")
    print(f"║  TradingAgents Analysis                                  ║")
    print(f"╠══════════════════════════════════════════════════════════╣")
    print(f"║  Ticker:      {ticker:<42s}║")
    print(f"║  Date:        {analysis_date:<42s}║")
    print(f"║  Provider:    {config['llm_provider']:<42s}║")
    print(f"║  Data Vendor: {config['data_vendors'].get('core_stock_apis', 'default'):<42s}║")
    print(f"║  Deep Think:  {config['deep_think_llm']:<42s}║")
    print(f"║  Quick Think: {config['quick_think_llm']:<42s}║")
    print(f"║  Debate Rnds: {config['max_debate_rounds']:<42}║")
    print(f"╚══════════════════════════════════════════════════════════╝")
    print()
    print("Starting analysis... (this may take 2-5 minutes)")
    print()

    try:
        ta = TradingAgentsGraph(debug=not args.quiet, config=config)
        _, decision = ta.propagate(ticker, analysis_date)
    except Exception as e:
        print(f"\nAnalysis failed: {e}", file=sys.stderr)
        return 1

    print()
    print("=" * 60)
    print("DECISION")
    print("=" * 60)
    print(decision)

    # Show log paths
    results_dir = os.path.expanduser(config.get("results_dir", "~/.tradingagents/logs"))
    memory_path = os.path.expanduser(config.get("memory_log_path", "~/.tradingagents/memory/trading_memory.md"))
    print()
    print(f"Results saved to: {results_dir}")
    print(f"Memory log:       {memory_path}")

    return 0


# ---------------------------------------------------------------------------
# List Models
# ---------------------------------------------------------------------------

def cmd_list_models(args: argparse.Namespace) -> int:
    """List available LLM models from TradingAgents model catalog."""
    try:
        from tradingagents.llm_clients.model_catalog import MODEL_OPTIONS
    except ImportError:
        print("ERROR: tradingagents not available. Run in 'nix develop ~/nix-config#trading'.", file=sys.stderr)
        return 1

    providers = [args.provider] if args.provider else sorted(MODEL_OPTIONS.keys())

    for provider in providers:
        if provider not in MODEL_OPTIONS:
            print(f"Unknown provider: {provider}")
            continue

        modes = MODEL_OPTIONS[provider]
        print(f"\n{'=' * 50}")
        print(f"  {provider}")
        print(f"{'=' * 50}")

        for mode in ["deep", "quick"]:
            if mode not in modes:
                continue
            role = "Deep Think (complex reasoning)" if mode == "deep" else "Quick Think (fast tasks)"
            print(f"\n  [{role}]")
            for label, mid in modes[mode]:
                print(f"    • {label}")
                print(f"      ID: {mid}")

    print()
    print("Note: Set provider + models via --provider / --deep-model / --quick-model in analyze command.")
    return 0


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

def cmd_history(args: argparse.Namespace) -> int:
    """View past TradingAgents analysis decisions from trading_memory.md."""
    memory_path = os.path.expanduser(
        os.environ.get("TRADINGAGENTS_MEMORY_LOG_PATH", "~/.tradingagents/memory/trading_memory.md")
    )

    if not os.path.exists(memory_path):
        print(f"No history found at {memory_path}")
        return 0

    with open(memory_path, "r") as f:
        content = f.read()

    # Split by <!-- ENTRY_END --> markers
    entries = [e.strip() for e in content.split("<!-- ENTRY_END -->") if e.strip()]

    if not entries:
        print("No entries in history.")
        return 0

    last_n = args.last or len(entries)
    entries = entries[-last_n:]

    print(f"TradingAgents History ({len(entries)} of {len(content.split('<!-- ENTRY_END -->')) - 1} entries)\n")

    for i, entry in enumerate(entries, 1):
        lines = entry.strip().split("\n")
        print(f"{'=' * 60}")
        print(f"  Entry {i}")
        print(f"{'=' * 60}")

        # Show header + first ~40 lines
        header_lines = []
        for line in lines:
            header_lines.append(line)
            if line.startswith("**Time Horizon"):
                break
            if len(header_lines) >= 50:
                break

        print("\n".join(header_lines[:50]))
        if len(lines) > 50:
            print(f"\n  ... ({len(lines) - 50} more lines — use --last 1 for full detail)")
        print()

    return 0


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def cmd_config(args: argparse.Namespace) -> int:
    """Show current TradingAgents configuration (env vars + defaults)."""
    try:
        from tradingagents.default_config import DEFAULT_CONFIG
    except ImportError:
        print("ERROR: tradingagents not available. Run in 'nix develop ~/nix-config#trading'.", file=sys.stderr)
        return 1

    # Display key env vars
    env_vars = [
        "TRADINGAGENTS_LLM_PROVIDER",
        "TRADINGAGENTS_DEEP_THINK_LLM",
        "TRADINGAGENTS_QUICK_THINK_LLM",
        "TRADINGAGENTS_OUTPUT_LANGUAGE",
        "TRADINGAGENTS_TEMPERATURE",
        "TRADINGAGENTS_CACHE_DIR",
        "TRADINGAGENTS_MEMORY_LOG_PATH",
        "TRADINGAGENTS_MAX_DEBATE_ROUNDS",
        "TRADINGAGENTS_MAX_RISK_DISCUSS_ROUNDS",
        "DEEPSEEK_API_KEY",
        "ALPHA_VANTAGE_API_KEY",
    ]

    # Check secrets status
    secret_vars = {
        "DEEPSEEK_API_KEY": "DeepSeek",
        "ANTHROPIC_API_KEY": "Anthropic/Zhipu",
        "GOOGLE_API_KEY": "Google Gemini",
        "XAI_API_KEY": "xAI Grok",
        "DASHSCOPE_API_KEY": "Qwen (International)",
        "DASHSCOPE_CN_API_KEY": "Qwen (China)",
        "ZHIPU_API_KEY": "GLM (International)",
        "ZHIPU_CN_API_KEY": "GLM (China)",
        "MINIMAX_API_KEY": "MiniMax (Global)",
        "MINIMAX_CN_API_KEY": "MiniMax (China)",
        "ALPHA_VANTAGE_API_KEY": "Alpha Vantage",
    }

    print("╔══════════════════════════════════════════════════════════╗")
    print("║  TradingAgents Configuration                              ║")
    print("╠══════════════════════════════════════════════════════════╣")
    print()

    print("── LLM & Analysis Settings ──")
    keys = [
        ("llm_provider", "LLM Provider"),
        ("deep_think_llm", "Deep Think Model"),
        ("quick_think_llm", "Quick Think Model"),
        ("output_language", "Output Language"),
        ("max_debate_rounds", "Debate Rounds"),
        ("max_risk_discuss_rounds", "Risk Discussion Rounds"),
    ]
    for key, label in keys:
        val = DEFAULT_CONFIG.get(key, "N/A")
        print(f"  {label:<28s} {val}")

    print()
    print("── Data Sources ──")
    dv = DEFAULT_CONFIG.get("data_vendors", {})
    for k, v in dv.items():
        print(f"  {k:<28s} {v}")

    print()
    print("── API Keys ──")
    for var, name in secret_vars.items():
        val = os.environ.get(var)
        if val:
            masked = val[:6] + "..." + val[-4:] if len(val) > 10 else "***"
            print(f"  {name:<28s} ✅ {masked}")
        else:
            print(f"  {name:<28s} ❌ not set")

    print()
    print("── Storage ──")
    paths = [
        ("Cache", os.path.expanduser(DEFAULT_CONFIG.get("data_cache_dir", ""))),
        ("Logs", os.path.expanduser(DEFAULT_CONFIG.get("results_dir", ""))),
        ("Memory", os.path.expanduser(DEFAULT_CONFIG.get("memory_log_path", ""))),
    ]
    for label, p in paths:
        if os.path.exists(p):
            size = get_dir_size(p)
            print(f"  {label:<28s} {p} ({size})")
        else:
            print(f"  {label:<28s} {p} (not created yet)")

    print()
    return 0


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

def get_dir_size(path: str) -> str:
    """Get human-readable directory size."""
    try:
        total = 0
        for dirpath, dirnames, filenames in os.walk(path):
            for f in filenames:
                fp = os.path.join(dirpath, f)
                try:
                    total += os.path.getsize(fp)
                except OSError:
                    pass
        for unit in ["B", "KB", "MB", "GB"]:
            if total < 1024:
                return f"{total:.1f} {unit}"
            total /= 1024
        return f"{total:.1f} TB"
    except Exception:
        return "unknown"


def cmd_cache(args: argparse.Namespace) -> int:
    """Manage TradingAgents data cache."""
    try:
        from tradingagents.default_config import DEFAULT_CONFIG
    except ImportError:
        print("ERROR: tradingagents not available.", file=sys.stderr)
        return 1

    cache_dir = os.path.expanduser(DEFAULT_CONFIG.get("data_cache_dir", "~/.tradingagents/cache"))
    checkpoint_dir = os.path.join(cache_dir, "checkpoints")

    if args.clear:
        cleared = []
        for d, label in [(cache_dir, "data cache"), (checkpoint_dir, "checkpoints")]:
            if os.path.exists(d):
                try:
                    shutil.rmtree(d)
                    cleared.append(label)
                except Exception as e:
                    print(f"Failed to clear {label}: {e}", file=sys.stderr)

        if cleared:
            print(f"Cleared: {', '.join(cleared)}")
        else:
            print("Nothing to clear.")
        return 0

    # Show status
    print("TradingAgents Cache Status\n")
    for d, label in [(cache_dir, "Data cache"), (checkpoint_dir, "Checkpoints")]:
        if os.path.exists(d):
            size = get_dir_size(d)
            file_count = sum(1 for _ in Path(d).rglob("*") if _.is_file())
            print(f"  {label}:")
            print(f"    Path:  {d}")
            print(f"    Size:  {size}")
            print(f"    Files: {file_count}")
        else:
            print(f"  {label}: not created yet")
        print()

    print("Use --clear to remove all cached data.")

    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="TradingAgents CLI — stock search & multi-agent analysis",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  trading_cli.py search "Apple Inc"
  trading_cli.py search "Tesla" --max-results 10
  trading_cli.py analyze AAPL
  trading_cli.py analyze NVDA --date 2025-06-13 --data-vendor alpha_vantage
  trading_cli.py list-models
  trading_cli.py list-models --provider deepseek
  trading_cli.py history --last 3
  trading_cli.py config
  trading_cli.py cache
  trading_cli.py cache --clear
        """,
    )

    sub = parser.add_subparsers(dest="command", required=True)

    # --- search ---
    p_search = sub.add_parser("search", help="Search for stock tickers")
    p_search.add_argument("query", help="Company name or keyword (English name for best results)")
    p_search.add_argument("--max-results", type=int, default=10, help="Max results (default: 10)")

    # --- analyze ---
    p_analyze = sub.add_parser("analyze", help="Analyze a stock")
    p_analyze.add_argument("ticker", help="Stock ticker (e.g., AAPL, 0700.HK, BTC-USD)")
    p_analyze.add_argument("--date", help="Analysis date (default: today)")
    p_analyze.add_argument("--provider", default="deepseek", help="LLM provider (default: deepseek)")
    p_analyze.add_argument("--deep-model", default="deepseek-v4-pro", help="Deep thinking model")
    p_analyze.add_argument("--quick-model", default="deepseek-v4-flash", help="Quick thinking model")
    p_analyze.add_argument("--debate-rounds", type=int, default=1, help="Debate rounds (default: 1)")
    p_analyze.add_argument("--risk-rounds", type=int, default=1, help="Risk discussion rounds (default: 1)")
    p_analyze.add_argument("--temperature", type=float, help="LLM temperature")
    p_analyze.add_argument("--language", help="Output language (e.g., English, Chinese)")
    p_analyze.add_argument("--data-vendor", choices=["alpha_vantage", "yfinance"], default="yfinance",
                           help="Data source vendor (default: yfinance)")
    p_analyze.add_argument("--quiet", action="store_true", help="Suppress debug output")

    # --- list-models ---
    p_models = sub.add_parser("list-models", help="List available LLM models")
    p_models.add_argument("--provider", help="Filter by provider (e.g., deepseek, openai, anthropic)")

    # --- history ---
    p_hist = sub.add_parser("history", help="View past analysis decisions")
    p_hist.add_argument("--last", type=int, help="Show last N entries (default: all)")

    # --- config ---
    sub.add_parser("config", help="Show current configuration")

    # --- cache ---
    p_cache = sub.add_parser("cache", help="Manage data cache")
    p_cache.add_argument("--clear", action="store_true", help="Clear all cached data")

    args = parser.parse_args()

    commands = {
        "search": cmd_search,
        "analyze": cmd_analyze,
        "list-models": cmd_list_models,
        "history": cmd_history,
        "config": cmd_config,
        "cache": cmd_cache,
    }

    if args.command in commands:
        return commands[args.command](args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
