#!/usr/bin/env bash
set -euo pipefail

# Get input parameters
GITHUB_REPOSITORY="$1"
GITHUB_REPOSITORY_OWNER="$2"
GITHUB_REPOSITORY_DESCRIPTION="$3"

# Extract repository name from full repository path
REPOSITORY_NAME=$(basename "$GITHUB_REPOSITORY")

# Update package.json with new repository information
if [ -f "package.json" ]; then
    # Use sed to update package.json fields
    sed -i.bak "s|\"name\": \".*\"|\"name\": \"$REPOSITORY_NAME\"|g" package.json
    sed -i.bak "s|\"description\": \".*\"|\"description\": \"$GITHUB_REPOSITORY_DESCRIPTION\"|g" package.json
    sed -i.bak "s|\"url\": \"git+https://github.com/.*/.*\\.git\"|\"url\": \"git+https://github.com/$GITHUB_REPOSITORY.git\"|g" package.json
    sed -i.bak "s|\"homepage\": \"https://github.com/.*/.*#readme\"|\"homepage\": \"https://github.com/$GITHUB_REPOSITORY#readme\"|g" package.json
    sed -i.bak "s|\"url\": \"https://github.com/.*/.*\\/issues\"|\"url\": \"https://github.com/$GITHUB_REPOSITORY/issues\"|g" package.json
    
    # Remove backup file
    rm -f package.json.bak
fi

# Update README.md if it exists
if [ -f "README.md" ]; then
    sed -i.bak "1s/^# .*/# $REPOSITORY_NAME/" README.md
    rm -f README.md.bak
fi

echo "Repository renamed to: $REPOSITORY_NAME"
echo "Description: $GITHUB_REPOSITORY_DESCRIPTION"
echo "Owner: $GITHUB_REPOSITORY_OWNER"