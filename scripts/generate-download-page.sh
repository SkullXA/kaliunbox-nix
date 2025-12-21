#!/bin/bash
# Generate downloads page HTML for local preview
# This uses sample data matching the production page CSS and layout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/dist"
OUTPUT_FILE="$OUTPUT_DIR/index.html"

mkdir -p "$OUTPUT_DIR"

# Sample data for preview (mimics production releases)
LATEST_VERSION="v0.2.0"
LATEST_DATE=$(date +%Y-%m-%d)

cat > "$OUTPUT_FILE" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SeloraBox ISO Downloads</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif;
            background: #181819;
            color: #e5e5e5;
            min-height: 100vh;
            padding: 40px 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: #272729;
            border: 1px solid #c7ae6a;
            border-radius: 12px;
            padding: 40px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.5);
        }
        .header {
            display: flex;
            align-items: center;
            gap: 20px;
            margin-bottom: 10px;
        }
        .header img {
            height: 60px;
            width: 60px;
            object-fit: contain;
        }
        h1 { color: #c7ae6a; font-size: 2rem; }
        h2 { color: #c7ae6a; margin: 30px 0 15px 0; font-size: 1.4rem; }
        .subtitle { color: #a0a0a0; margin-bottom: 30px; font-size: 1.1rem; }
        .latest-section {
            background: #1a1a1b;
            border: 2px solid #c7ae6a;
            border-radius: 12px;
            padding: 30px;
            margin: 20px 0 40px 0;
        }
        .latest-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
        }
        .latest-version {
            font-size: 1.8rem;
            color: #c7ae6a;
            font-weight: 700;
        }
        .latest-badge {
            background: transparent;
            color: #c7ae6a;
            padding: 6px 16px;
            border: 1px solid #c7ae6a;
            border-radius: 20px;
            font-weight: 600;
            font-size: 0.9rem;
        }
        .latest-downloads {
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
        }
        .download-card {
            background: #272729;
            border: 1px solid #3a3a3c;
            border-radius: 8px;
            padding: 20px;
            flex: 1;
            min-width: 280px;
        }
        .download-card h3 {
            color: #e5e5e5;
            margin-bottom: 10px;
            font-size: 1.1rem;
        }
        .download-card .meta {
            color: #808080;
            font-size: 0.9rem;
            margin-bottom: 15px;
        }
        .download-card .checksum {
            font-family: monospace;
            font-size: 0.75rem;
            color: #606060;
            word-break: break-all;
            margin-bottom: 15px;
        }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; }
        th, td { border: 1px solid #3a3a3c; padding: 12px 16px; text-align: left; }
        th {
            background: #1a1a1b;
            color: #c7ae6a;
            font-weight: 600;
            border-bottom: 2px solid #c7ae6a;
        }
        tr { transition: background-color 0.2s; }
        tr:hover { background-color: #2a2a2c; }
        a { color: #c7ae6a; text-decoration: none; font-weight: 600; transition: color 0.2s; }
        a:hover { color: #d4bf7a; text-decoration: underline; }
        .download-btn {
            background: #c7ae6a;
            color: #181819;
            padding: 8px 20px;
            border-radius: 6px;
            display: inline-block;
            transition: all 0.2s;
            font-weight: 600;
        }
        .download-btn:hover {
            background: #d4bf7a;
            color: #181819;
            transform: translateY(-2px);
            text-decoration: none;
            box-shadow: 0 4px 12px rgba(199, 174, 106, 0.3);
        }
        .download-btn-small {
            background: #3a3a3c;
            color: #e5e5e5;
            padding: 6px 14px;
            border-radius: 4px;
            font-size: 0.9rem;
        }
        .download-btn-small:hover {
            background: #4a4a4c;
        }
        .release-notes-link {
            font-weight: normal;
            font-size: 0.9rem;
        }
        .footer {
            margin-top: 40px;
            text-align: center;
            color: #808080;
            font-size: 0.9em;
            border-top: 1px solid #3a3a3c;
            padding-top: 20px;
        }
        .footer a { color: #c7ae6a; }
        .preview-banner {
            background: #3a2a10;
            border: 1px solid #c7ae6a;
            border-radius: 8px;
            padding: 15px;
            margin-bottom: 20px;
            text-align: center;
            color: #c7ae6a;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="preview-banner">
            LOCAL PREVIEW - This page uses sample data for testing CSS/layout
        </div>
        <div class="header">
            <img src="https://selorahomes.com/selora-logo.png" alt="Selora Homes">
            <h1>SeloraBox ISO Downloads</h1>
        </div>
        <p class="subtitle">NixOS-based home automation appliance images</p>
EOF

# Add latest section
cat >> "$OUTPUT_FILE" << EOF
<div class="latest-section">
<div class="latest-header">
<span class="latest-version">${LATEST_VERSION}</span>
<span class="latest-badge">Latest Release</span>
</div>
<p style="margin-bottom: 20px;"><a href="https://gitlab.com/SeloraHomes/products/selorabox-nix/-/releases/${LATEST_VERSION}" class="release-notes-link">View Release Notes &rarr;</a></p>
<div class="latest-downloads">
<div class="download-card">
<h3>aarch64</h3>
<p class="meta">1750 MB &bull; ${LATEST_DATE}</p>
<p class="checksum">SHA256: a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456</p>
<a href="#" class="download-btn">Download</a>
 <a href="#" class="download-btn-small">Checksum</a>
</div>
<div class="download-card">
<h3>x86_64</h3>
<p class="meta">1730 MB &bull; ${LATEST_DATE}</p>
<p class="checksum">SHA256: f1e2d3c4b5a6789012345678901234567890fedcba1234567890fedcba123456</p>
<a href="#" class="download-btn">Download</a>
 <a href="#" class="download-btn-small">Checksum</a>
</div>
</div></div>
EOF

# Add previous releases table
cat >> "$OUTPUT_FILE" << 'EOF'
        <h2>Previous Releases</h2>
        <table>
            <thead>
                <tr>
                    <th>Version</th>
                    <th>Architecture</th>
                    <th>Size</th>
                    <th>Date</th>
                    <th>Release Notes</th>
                    <th>Download</th>
                </tr>
            </thead>
            <tbody>
<tr>
<td>v0.1.2</td>
<td>aarch64</td>
<td>1739 MB</td>
<td>2025-12-01</td>
<td><a href="https://gitlab.com/SeloraHomes/products/selorabox-nix/-/releases/v0.1.2">View</a></td>
<td><a href="#" class="download-btn-small">Download</a></td>
</tr>
<tr>
<td>v0.1.2</td>
<td>x86_64</td>
<td>1719 MB</td>
<td>2025-12-01</td>
<td><a href="https://gitlab.com/SeloraHomes/products/selorabox-nix/-/releases/v0.1.2">View</a></td>
<td><a href="#" class="download-btn-small">Download</a></td>
</tr>
<tr>
<td>v0.1.1</td>
<td>aarch64</td>
<td>1827 MB</td>
<td>2025-11-30</td>
<td><a href="https://gitlab.com/SeloraHomes/products/selorabox-nix/-/releases/v0.1.1">View</a></td>
<td><a href="#" class="download-btn-small">Download</a></td>
</tr>
<tr>
<td>v0.1.1</td>
<td>x86_64</td>
<td>1809 MB</td>
<td>2025-11-30</td>
<td><a href="https://gitlab.com/SeloraHomes/products/selorabox-nix/-/releases/v0.1.1">View</a></td>
<td><a href="#" class="download-btn-small">Download</a></td>
</tr>
<tr>
<td>v0.1.0</td>
<td>aarch64</td>
<td>1827 MB</td>
<td>2025-11-26</td>
<td><a href="https://gitlab.com/SeloraHomes/products/selorabox-nix/-/releases/v0.1.0">View</a></td>
<td><a href="#" class="download-btn-small">Download</a></td>
</tr>
<tr>
<td>v0.1.0</td>
<td>x86_64</td>
<td>1809 MB</td>
<td>2025-11-26</td>
<td><a href="https://gitlab.com/SeloraHomes/products/selorabox-nix/-/releases/v0.1.0">View</a></td>
<td><a href="#" class="download-btn-small">Download</a></td>
</tr>
</tbody></table>
EOF

# Add footer with current timestamp
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S")
cat >> "$OUTPUT_FILE" << EOF
        <div class="footer">
            <p>Last updated: ${TIMESTAMP} UTC</p>
            <p><a href="https://selorahomes.com">SeloraHomes.com</a> | <a href="https://gitlab.com/SeloraHomes/products/selorabox-nix">GitLab Repository</a></p>
        </div>
    </div>
</body>
</html>
EOF

echo "Generated: $OUTPUT_FILE"
