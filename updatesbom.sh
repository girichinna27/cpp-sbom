#!/bin/bash

# Usage check
if [ $# -ne 1 ]; then
  echo "Usage: $0 <docker_image:tag>"
  exit 1
fi

image_name="$1"
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
REPO_URL="git@github.com:girichinna27/cpp-sbom.git"
LOCAL_REPO="$ROOT_DIR/$REPO_NAME"

# 1. Check if repo folder exists
if [ ! -d "$LOCAL_REPO/.git" ]; then
  echo "🔄 Cloning repo $REPO_URL..."
  git clone "$REPO_URL" "$LOCAL_REPO"
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
git push

echo "🎉 Successfully pushed $output_file to GitHub repo under sbom-reports/"

