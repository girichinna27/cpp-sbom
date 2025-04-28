#!/bin/bash

# Usage check
if [ $# -ne 1 ]; then
  echo "Usage: $0 <docker_image_name:tag>"
  exit 1
fi

image="$1"
image_name=$(echo "$image" | sed 's/[:/]/-/g')  # replace / and : with - for filename safety
input_file="${image_name}.json"
base_name="${input_file%.json}"
converted_file="${base_name}-converted-v1.6.json"
tmp_file=$(mktemp)
final_components=$(mktemp)
output_file="${base_name}-bomref-v1.6.json"

schema_added=0
type_converted=0
bomref_added=0

# Step 0: Generate SBOM using tern
echo "🔍 Generating SBOM for image: $image ..."
tern report --image "$image" --report-format cyclonedxjson --output-file "$input_file"

# Step 1: Convert SBOM to CycloneDX v1.6
echo "🔄 Converting SBOM to CycloneDX v1.6 format..."
cyclonedx convert --input-file "$input_file" \
                  --output-file "$converted_file" \
                  --output-format json \
                  --output-version v1_6

# Step 2: Add "$schema" field if missing
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

# Step 3: Replace "type": "application" with "type": "library"
type_converted=$(grep -o '"type": "application"' "$tmp_file" | wc -l)
sed -i 's/"type": "application"/"type": "library"/g' "$tmp_file"

# Step 4: Add bom-ref with UUIDs per component (fixed version)
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
    updated_components+=("$comp")
    bomref_added=$((bomref_added + 1))
  fi
done < <(jq -c '.components[]' "$tmp_file")

# Save updated components
printf '%s\n' "${updated_components[@]}" | jq -s '.' > "$final_components"

# Step 5: Merge updated components back into main JSON
jq --slurpfile new_components "$final_components" '.components = $new_components[0]' "$tmp_file" > "$output_file"

# Cleanup
rm "$tmp_file" "$converted_file" "$final_components"

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

