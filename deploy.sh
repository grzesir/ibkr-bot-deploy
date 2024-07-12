#!/usr/bin/env bash
set -e

# Get the directory of the current script
dir="$(realpath "$(dirname "$0")")"
OS="$(uname)"

# Source the .env.deploy file if it exists
if [ -f "$dir/.env.deploy" ]; then
    echo "Loading environment variables from .env.deploy file"
    source "$dir/.env.deploy"
fi

# Change directory to the script directory
cd "$dir"

# Free ports by stopping running Docker containers
docker ps --format "{{.Names}}" | grep 'strategy' | xargs -r docker kill > /dev/null
docker ps --format "{{.Names}}" | grep 'ib-gateway' | xargs -r docker kill > /dev/null

# Reset .env file if it exists
rm -f "$dir/.env"

# Ensure all required environment variables are set
: "${IBKR_USERNAME:?Environment variable IBKR_USERNAME is required. In Heroku you can set it in the Config Vars section of the app Settings.}"
: "${IBKR_PASSWORD:?Environment variable IBKR_PASSWORD is required. In Heroku you can set it in the Config Vars section of the app Settings.}"
: "${LUMIBOT_STRATEGY_GITHUB_URL:?Environment variable LUMIBOT_STRATEGY_GITHUB_URL is required. In Heroku you can set it in the Config Vars section of the app Settings.}"
: "${TRADING_MODE:?Environment variable TRADING_MODE is required. In Heroku you can set it in the Config Vars section of the app Settings.}"
: "${CONFIG_CHOICE:?Environment variable CONFIG_CHOICE is required. In Heroku you can set it in the Config Vars section of the app Settings.}"
: "${GITHUB_TOKEN:?Environment variable GITHUB_TOKEN is required. In Heroku you can set it in the Config Vars section of the app Settings.}"

# Normalize the IBKR_IS_PAPER variable to lowercase
IBKR_IS_PAPER=$(echo "${IBKR_IS_PAPER:-true}" | tr '[:upper:]' '[:lower:]')

# Echo the env variable IBKR_USERNAME to the user
echo "IBKR_USERNAME: $IBKR_USERNAME"

# Determine the trading mode based on IBKR_IS_PAPER
if [ "$IBKR_IS_PAPER" == "true" ]; then
    printf "TRADING_MODE=paper\n" >> .env
    PORT=4004
    echo "[*] Will Deploy Paper"
elif [ "$IBKR_IS_PAPER" == "false" ]; then
    printf "TRADING_MODE=live\n" >> .env
    PORT=4003
    echo "[*] Will Deploy Live"
else
    echo "Invalid value for IBKR_IS_PAPER: $IBKR_IS_PAPER. Expected 'true' or 'false'. Exiting..."
    exit 1
fi

# Check if port is in use and find an available port if necessary
while ss -tuln | grep ":$PORT " > /dev/null; do
    echo "Port $PORT is in use. Exiting..."
    exit 1
done
echo "Using port $PORT."

# Create .env if not available
if [ ! -e "environment/.cred" ]; then
    tws_userid="${IBKR_USERNAME:-}"
    tws_password="${IBKR_PASSWORD:-}"

    echo "TWS_USERID=$tws_userid" >> environment/.cred
    echo "TWS_PASSWORD=$tws_password" >> environment/.cred
fi

if [ ! -e "environment/.pref" ]; then
    bot_repo="${LUMIBOT_STRATEGY_GITHUB_URL:-}"
    echo "bot_repo=$bot_repo" >> environment/.pref

    echo 'ALPACA_BASE_URL="https://paper-api.alpaca.markets/v2"' >> environment/.pref
    echo 'BROKER=IBKR' >> environment/.pref
    echo "INTERACTIVE_BROKERS_IP=ib-gateway" >> environment/.pref
fi

# Generate a random client ID and set the broker port
printf "INTERACTIVE_BROKERS_CLIENT_ID=%s\n" "$((RANDOM % 1000 + 1))" >> .env
printf "INTERACTIVE_BROKERS_PORT=%s\n" "$PORT" >> .env

# Add variables to local .env
cat "$dir/environment/.cred" >> .env
cat "$dir/environment/.pref" >> .env

# Load env variables
source "$dir/.env"

# Fix the GitHub repository URL
repo_url=$(echo $LUMIBOT_STRATEGY_GITHUB_URL | sed 's/https:\/\/github.com\///')

# Clone the repository only if the directory does not exist
if [ ! -d "$dir/environment/bot" ]; then
    git clone https://${GITHUB_TOKEN}@github.com/${repo_url} "$dir/environment/bot" || { echo "Probably not logged into git. Exiting..."; exit 1; }
else
    echo "Directory $dir/environment/bot already exists. Skipping clone."
fi

# Copy necessary files
cp environment/requirements.txt environment/bot/
cp environment/Dockerfile environment/bot/
cp environment/launch.sh environment/bot/
cp environment/healthcheck.py environment/bot/

# Patch credentials and pick config
case $OS in
    'Linux')
        sed -i 's/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG)/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG, max_connection_retries=50)/' environment/bot/credentials.py
        sed -i 's/if ALPACA_CONFIG\["API_KEY"\]:/if ALPACA_CONFIG["API_KEY"] and os.environ.get("BROKER", "").lower() == "alpaca":/' environment/bot/credentials.py
        sed -i "s/LIVE_TRADING_CONFIGURATION_FILE_NAME = '.*'/LIVE_TRADING_CONFIGURATION_FILE_NAME = '${selected_config}'/" environment/bot/main.py
        ;;
    'Darwin')
        sed -i '' 's/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG)/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG, max_connection_retries=50)/' environment/bot/credentials.py
        sed -i '' 's/if ALPACA_CONFIG\["API_KEY"\]:/if ALPACA_CONFIG["API_KEY"] and os.environ.get("BROKER", "").lower() == "alpaca":/' environment/bot/credentials.py
        sed -i '' "s/LIVE_TRADING_CONFIGURATION_FILE_NAME = '.*'/LIVE_TRADING_CONFIGURATION_FILE_NAME = '${selected_config}'/" environment/bot/main.py
        ;;
    *)
        exit 1
        ;;
esac

# List available configuration files
echo "Available configuration files:"
config_files=$(ls -1 "environment/bot/configurations")
i=1
for file in $config_files; do
    echo "[$i] $file"
    ((i++))
done

# Read configuration choice from the environment variable
config_choice="${CONFIG_CHOICE:-}"

# Validate user input
if ! [[ "$config_choice" =~ ^[0-9]+$ ]] || ((config_choice < 1 || config_choice > i-1)); then
    echo "Choice was $config_choice"
    echo "Invalid choice. Exiting..."
    exit 1
fi

# Get the selected configuration file
selected_config="$(basename "$(ls -1 "environment/bot/configurations" | grep ".py$" | sed -n "${config_choice}p")" .py)"

# Set the selected configuration file in .env
echo "CONFIG_FILE=$selected_config" >> .env

# Set config based on OS
case $OS in
    'Linux')
        sed -i "s/LIVE_TRADING_CONFIGURATION_FILE_NAME = '.*'/LIVE_TRADING_CONFIGURATION_FILE_NAME = '${selected_config}'/" environment/bot/main.py
        ;;
    'Darwin')
        sed -i '' "s/LIVE_TRADING_CONFIGURATION_FILE_NAME = '.*'/LIVE_TRADING_CONFIGURATION_FILE_NAME = '${selected_config}'/" environment/bot/main.py
        ;;
    *)
        exit 1
        ;;
esac

# Start Docker Compose
echo "Starting Docker Compose..."
docker-compose up --remove-orphans -d