#!/bin/bash

#### Installing all pre-requisite utilities
set -e

echo "🔧 Starting installation of prerequisite utilities and Tern..."

# Helper to validate existence
validate_tool() {
    local tool_name=$1
    local version_cmd=$2
    echo -n "🔹 Checking $tool_name... "
    if command -v $tool_name &>/dev/null; then
        echo "✅ FOUND - Version: $($version_cmd)"
    else
        echo "❌ NOT FOUND!"
    fi
}

echo "📦 Updating system packages and installing dependencies..."
sudo apt update
sudo apt install -y python3 python3-pip python3-venv pipx git jq uuid-runtime skopeo attr gcc python3-dev libffi-dev libssl-dev make curl

# Ensure pipx path is active
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"

# Validate common tools
validate_tool python3 "python3 --version"
validate_tool pip3 "pip3 --version"
validate_tool pipx "pipx --version"
validate_tool jq "jq --version"
validate_tool skopeo "skopeo --version"
validate_tool getfattr "getfattr --version"

# Install cyclonedx-cli 
if ! command -v cyclonedx &>/dev/null; then
    echo "⬇️ Installing CycloneDX CLI..."
    curl -LO https://github.com/CycloneDX/cyclonedx-cli/releases/download/v0.27.2/cyclonedx-linux-x64
    chmod +x cyclonedx-linux-x64
    sudo mv cyclonedx-linux-x64 /usr/local/bin/cyclonedx
fi
validate_tool cyclonedx "cyclonedx --version"

# Install Tern via virtualenv (since pipx method failed earlier)
if [ ! -d "$HOME/.tern-venv" ]; then
    echo "🐍 Creating Python virtual environment for Tern..."
    python3 -m venv ~/.tern-venv
fi
source ~/.tern-venv/bin/activate

if [ ! -d "$HOME/tern" ]; then
    echo "📥 Cloning Tern from GitHub..."
    git clone https://github.com/tern-tools/tern.git ~/tern
fi

cd ~/tern
echo "📦 Installing Python dependencies for Tern..."
pip install --upgrade pip setuptools wheel
pip install -r requirements.txt

echo "🔧 Installing Tern..."
python3 setup.py install

# Ensure fs_hash.sh is executable
chmod +x ~/.tern-venv/lib/python*/site-packages/tern/tools/fs_hash.sh

validate_tool tern "tern --version"

echo ""
echo "✅ All utilities and Tern installed successfully!"

##### Generate the SBOM, fix all the format issues like: adding schema, change the spec version to 1.6, add bom reference for each component elements, change type from application to library etc etc
image_name="${DOCKER_IMAGE}:${TAG}"
echo $image_name
image_base=$(echo "$image_name" | tr '/:' '-')
sbom_file="${image_base}.json"
base_name="${image_base}"
converted_file="${base_name}-converted-v1.6.json"
tmp_file=$(mktemp)
final_components=$(mktemp)
output_file="${base_name}-bomref-v1.6.json"

schema_added=0
type_converted=0
bomref_added=0

# Save current directory
ROOT_DIR=$(pwd)

# Step 0: Generate SBOM
echo "🐳 Generating SBOM for Docker image: $image_name..."
tern report --image "$image_name" --report-format cyclonedxjson --output-file "$sbom_file"

# Step 1: Convert SBOM to CycloneDX v1.6
echo "🔄 Converting SBOM to CycloneDX v1.6 format..."
cyclonedx convert --input-file "$sbom_file" \
                  --output-file "$converted_file" \
                  --output-format json \
                  --output-version v1_6

# Step 2: Add "$schema" if missing
if ! jq 'has("$schema")' "$converted_file" | grep -q true; then
  jq 'to_entries |
      map(if .key == "bomFormat"
          then {"key":"$schema","value":"http://cyclonedx.org/schema/bom-1.6.schema.json"}, .
          else . end) |
      from_entries' "$converted_file" > "$tmp_file"
  schema_added=1
else
  cp "$converted_file" "$tmp_file"
fi

# Step 3: Replace "application" with "library"
type_converted=$(grep -o '"type": "application"' "$tmp_file" | wc -l)
sed -i 's/"type": "application"/"type": "library"/g' "$tmp_file"

# Step 4: Add missing bom-refs
components=$(jq -c '.components[]' "$tmp_file")
updated_components=()

while IFS= read -r comp; do
  if echo "$comp" | jq -e 'has("bom-ref")' > /dev/null; then
    updated_components+=("$comp")
  else
    purl=$(echo "$comp" | jq -r '.purl // empty')
    if [[ -n "$purl" ]]; then
      suffix=$(uuidgen | tr -d '-' | cut -c1-16)
      bomref="${purl}?package-id=${suffix}"
      comp=$(echo "$comp" | jq --arg bomref "$bomref" '. + { "bom-ref": $bomref }')
    else
      uuid=$(uuidgen)
      comp=$(echo "$comp" | jq --arg uuid "$uuid" '. + { "bom-ref": $uuid }')
    fi
    bomref_added=$((bomref_added + 1))
    updated_components+=("$comp")
  fi
done <<< "$components"

printf "%s\n" "${updated_components[@]}" | jq -s '.' > "$final_components"
jq --slurpfile new_components "$final_components" '.components = $new_components[0]' "$tmp_file" > "$output_file"

# Cleanup
rm "$tmp_file" "$converted_file" "$final_components" "$sbom_file"

# Summary
echo "✅ Output written to: $output_file"
echo "📄 Summary of changes:"
if [ "$schema_added" -eq 1 ]; then
  echo "  • Added \$schema declaration"
else
  echo "  • \$schema already present"
fi
echo "  • Updated specVersion from 1.3 → 1.6"
echo "  • Converted $type_converted \"type: application\" → \"type: library\""
echo "  • Added $bomref_added missing \"bom-ref\" fields"

# -------------------------------------------
# Git operations
# -------------------------------------------

REPO_NAME="cpp-sbom"
###REPO_URL="git@github.com:girichinna27/cpp-sbom.git"
REPO_URL="https://${GITHUB_TOKEN}@github.com/girichinna27/cpp-sbom.git"
LOCAL_REPO="$ROOT_DIR/$REPO_NAME"

# 1. Check if repo folder exists
if [ ! -d "$LOCAL_REPO/.git" ]; then
  echo "🔄 Cloning repo $REPO_URL..."
  git clone "$REPO_URL" "$LOCAL_REPO"
  ####git clone "https://${GITHUB_TOKEN}@github.com/girichinna27/cpp-sbom.git" "$LOCAL_REPO"
else
  echo "📂 Repo exists. Pulling latest changes..."
  cd "$LOCAL_REPO"
  git pull
  cd "$ROOT_DIR"
fi

# 2. Make sure sbom-reports folder exists
if [ ! -d "$LOCAL_REPO/sbom-reports" ]; then
  echo "📂 Creating sbom-reports folder..."
  mkdir -p "$LOCAL_REPO/sbom-reports"
fi

# 3. Copy output file into correct folder
cp "$output_file" "$LOCAL_REPO/sbom-reports/"

# 4. Git add, commit and push
cd "$LOCAL_REPO"
git add "sbom-reports/$output_file"
git commit -m "Add SBOM report for $image_name"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/girichinna27/cpp-sbom.git"
git push

echo "🎉 Successfully pushed $output_file to GitHub repo under sbom-reports/"
echo "output_file=$output_file" > /tmp/output_file.env
