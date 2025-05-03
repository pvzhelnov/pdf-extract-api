#!/bin/bash

echo "$DISABLE_LOCAL_OLLAMA"

DISABLE_CONDA="${DISABLE_CONDA:-0}"
DISABLE_LOCAL_OLLAMA="${DISABLE_LOCAL_OLLAMA:-0}"

RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Define conda environment name
CONDA_ENV_NAME="text_extract_env"

if [ "$DISABLE_CONDA" -eq 1 ]; then
    echo "  Conda environment disabled"
else
    echo "  Setting up Conda environment"
    
    # Check if conda is available in PATH
    if ! command -v conda &> /dev/null; then
        echo -e "${RED}Error: conda is not found in PATH${RESET}"
        echo "Please make sure Conda is installed and initialized:"
        echo -e "${CYAN}  For Miniconda: bash ~/miniconda3/etc/profile.d/conda.sh${RESET}"
        echo -e "${CYAN}  For Anaconda: bash ~/anaconda3/etc/profile.d/conda.sh${RESET}"
        exit 1
    fi
    
    # Check if the environment exists, create if it doesn't
    if ! conda env list | grep -q "${CONDA_ENV_NAME}"; then
        echo "Creating new Conda environment: ${CONDA_ENV_NAME}"
        conda create -y -n "${CONDA_ENV_NAME}" python=3.9  # Adjust Python version as needed
    else
        echo "Using existing Conda environment: ${CONDA_ENV_NAME}"
    fi
    
    # Activate the conda environment
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV_NAME}" || { 
        echo -e "${RED}Failed to activate Conda environment${RESET}"; 
        exit 1; 
    }
    
    echo "Conda environment '${CONDA_ENV_NAME}' activated"
fi

echo "Installing current package..."
if ! pip install -e . 2>logs/init.log; then
    echo "Failed to install the package in editable mode."
    printf "Error log: %s" "$RED"
    cat logs/init.log
    echo -e "$RESET Please check the setup and consider manually reinstalling in your conda environment:"
    echo -e "$CYAN    conda activate ${CONDA_ENV_NAME} && pip install -e . $RESET"
    exit 1
fi

# The rest of your script continues below...
if [ ! -f .env.localhost ]; then
  cp .env.localhost.example .env.localhost
fi

set -a; source .env.localhost; set +a

if [ "$DISABLE_LOCAL_OLLAMA" -eq 1 ]; then
  echo "Local Ollama disabled by env \`DISABLE_LOCAL_OLLAMA=$DISABLE_LOCAL_OLLAMA\`"
  echo "External Ollama should be listening on OLLAMA_HOST=$OLLAMA_HOST"
else
  echo "Starting Ollama Server"
  ollama serve &

  echo "Pulling LLama3.1 model"
  ollama pull llama3.1

  echo "Pulling LLama3.2-vision model"
  ollama pull llama3.2-vision
fi

echo "Starting Redis"

echo "Your ENV settings loaded from .env.localhost file: "
printenv

# Update Celery bin path for conda environment
CELERY_BIN="$(which celery)"
CELERY_PIDS=$(pgrep -f "$CELERY_BIN")

if [ -n "$CELERY_PIDS" ]; then
  echo "Killing existing Celery processes from $CELERY_BIN with PIDs:"
  echo "$CELERY_PIDS"
  for PID in $CELERY_PIDS; do
    kill "$PID" || echo "Failed to kill process with PID: $PID"
  done
else
  echo "No running Celery process found."
fi

REDIS_PORT=6379 # will move it to .envs in near future

if lsof -i :$REDIS_PORT | grep LISTEN >/dev/null; then
  echo "Redis is already running on port $REDIS_PORT. Skipping Redis start."
else
  echo "Starting Redis..."
  docker run -p $REDIS_PORT:6379 --restart always --detach redis &
fi


echo "Starting Celery Worker and FastAPI server"
if [ $APP_ENV = 'production' ]; then
    celery -A text_extract_api.celery_init worker --loglevel=info --pool=solo & # to scale by concurrent processing please run this line as many times as many concurrent processess you want to have running; keep in mind that after next run they will be killed
    uvicorn text_extract_api.main:app --host 0.0.0.0 --port 8000;
else
  trap 'kill $(jobs -p) && exit' SIGINT SIGTERM
  (
      celery -A text_extract_api.celery_app worker --loglevel=debug --pool=solo &
      uvicorn text_extract_api.main:app --host 0.0.0.0 --port 8000 --reload
  )
fi