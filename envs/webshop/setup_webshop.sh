#!/usr/bin/env bash
# setup_webshop.sh — Create the webshop conda environment and download data.
#
# Usage:
#   bash setup_webshop.sh          # Full setup (create env + download data + build indexes)
#   bash setup_webshop.sh --check  # Just verify the env is usable
#
# The webshop conda env is isolated because WebShop pins old versions of
# torch (1.11), transformers (4.19), spacy (3.3) etc. that conflict with
# the main 'mem' environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_ENV_NAME="webshop"
REQUIREMENTS="$SCRIPT_DIR/webshop_requirements.txt"
DATA_DIR="$SCRIPT_DIR/data"
SEARCH_DIR="$SCRIPT_DIR/search_engine"
BRIDGE_SCRIPT="$SCRIPT_DIR/webshop_bridge.py"

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
conda_env_exists() {
    conda env list 2>/dev/null | grep -qw "$CONDA_ENV_NAME"
}

# ---------------------------------------------------------------------------
# --check mode: verify the env can import the bridge deps
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--check" ]]; then
    if ! conda_env_exists; then
        echo -e "${RED}✗ Conda env '$CONDA_ENV_NAME' not found.${NC}"
        exit 1
    fi

    # Verify critical imports inside the webshop env
    if PYTHONPATH="$SCRIPT_DIR" conda run --no-capture-output -n "$CONDA_ENV_NAME" python -c \
        "import gym; from web_agent_site.envs import WebAgentTextEnv; print('OK')" \
        2>/dev/null; then
        echo -e "${GREEN}✓ WebShop environment is functional.${NC}"
        exit 0
    else
        echo -e "${RED}✗ Import check failed inside '$CONDA_ENV_NAME' env.${NC}"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Full setup
# ---------------------------------------------------------------------------
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN} WebShop Environment Setup${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

# Step 1: Create conda env
if conda_env_exists; then
    echo -e "${GREEN}✓ Conda env '$CONDA_ENV_NAME' already exists.${NC}"
else
    echo -e "${YELLOW}Creating conda env '$CONDA_ENV_NAME' (Python 3.9)...${NC}"
    conda create -y -n "$CONDA_ENV_NAME" python=3.9
fi

# Step 2: Install requirements
echo -e "${CYAN}Installing requirements into '$CONDA_ENV_NAME'...${NC}"
if [[ -f "$REQUIREMENTS" ]]; then
    conda run --no-capture-output -n "$CONDA_ENV_NAME" pip install -r "$REQUIREMENTS"
else
    echo -e "${RED}✗ Requirements file not found: $REQUIREMENTS${NC}"
    exit 1
fi

# Step 2b: Install API clients (pydantic conflict with spacy 3.3, force install)
echo -e "${CYAN}Installing API clients (openai, anthropic, google-genai)...${NC}"
conda run --no-capture-output -n "$CONDA_ENV_NAME" pip install --no-deps openai anthropic google-genai httpx anyio 2>/dev/null || true

# Step 3: Install spacy model
echo -e "${CYAN}Installing spacy en_core_web_sm model...${NC}"
conda run --no-capture-output -n "$CONDA_ENV_NAME" python -m spacy download en_core_web_sm 2>/dev/null || true

# Step 4: Download WebShop data if missing
if [[ ! -d "$DATA_DIR" ]] || [[ ! -f "$DATA_DIR/items_shuffle.json" ]]; then
    echo -e "${YELLOW}Downloading WebShop data...${NC}"
    mkdir -p "$DATA_DIR"

    # WebShop data hosted on the princeton-nlp project
    # items_shuffle.json (~1.5GB), items_ins_v2.json, items_human_ins.json, reviews.json
    WEBSHOP_DATA_URL="https://drive.google.com/drive/folders/1jTyidOblW5U_Oy5H_5ysJEVwMXN6l8JU"
    echo -e "${YELLOW}WebShop product data must be downloaded manually.${NC}"
    echo ""
    echo "  The data files are hosted at:"
    echo "    $WEBSHOP_DATA_URL"
    echo ""
    echo "  Download the following files into: $DATA_DIR/"
    echo "    - items_shuffle.json  (~1.5 GB)"
    echo "    - items_ins_v2.json"
    echo "    - items_human_ins.json"
    echo ""
    echo "  Alternatively, use gdown:"
    echo "    pip install gdown"
    echo "    cd $DATA_DIR"
    echo "    gdown --folder $WEBSHOP_DATA_URL"
    echo ""
    echo -e "${YELLOW}NOTE: The experiments will fall back to StandaloneSimulator if data is missing.${NC}"
    echo -e "${YELLOW}      This is fine for parity testing but uses synthetic products.${NC}"
else
    echo -e "${GREEN}✓ Data directory exists: $DATA_DIR${NC}"
fi

# Step 5: Build search indexes (if data is available)
if [[ -f "$DATA_DIR/items_shuffle.json" ]]; then
    RESOURCES_DIR="$SEARCH_DIR/resources"
    if [[ ! -d "$SEARCH_DIR/indexes" ]]; then
        echo -e "${CYAN}Building search indexes...${NC}"
        # Convert products to pyserini format
        conda run --no-capture-output -n "$CONDA_ENV_NAME" python \
            "$SEARCH_DIR/convert_product_file_format.py" \
            --input "$DATA_DIR/items_shuffle.json" \
            --output "$RESOURCES_DIR" 2>/dev/null || true

        # Build Lucene indexes
        if [[ -d "$RESOURCES_DIR" ]]; then
            cd "$SEARCH_DIR"
            conda run --no-capture-output -n "$CONDA_ENV_NAME" bash run_indexing.sh 2>/dev/null || true
            cd "$SCRIPT_DIR"
        fi
    else
        echo -e "${GREEN}✓ Search indexes already built.${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Skipping index build (no data files yet).${NC}"
fi

# Step 6: Verify
echo ""
echo -e "${CYAN}Verifying setup...${NC}"
if conda run --no-capture-output -n "$CONDA_ENV_NAME" python -c \
    "import gym, torch, spacy, openai; print('Core imports OK')" 2>/dev/null; then
    echo -e "${GREEN}✓ Core imports verified.${NC}"
else
    echo -e "${RED}✗ Some imports failed. Check the logs above.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Setup complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Next steps:"
echo "  1. Download product data (if not done) — see instructions above"
echo "  2. Verify: bash $0 --check"
echo "  3. Run:    python Objective-Drifting.py --mode aggressive --victim gpt4o --num_tasks 2"
