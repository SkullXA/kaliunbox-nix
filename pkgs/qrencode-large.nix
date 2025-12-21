{
  writeShellScriptBin,
  qrencode,
}:
# Wrapper around qrencode for generating large QR codes suitable for Plymouth display
writeShellScriptBin "qrencode-large" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # Generate a large QR code (suitable for 1920x1080 displays)
  # Args: $1 = text to encode, $2 = output file
  TEXT="''${1:?Usage: qrencode-large <text> <output-file>}"
  OUTPUT="''${2:?Usage: qrencode-large <text> <output-file>}"

  # Generate PNG with high module size for visibility
  ${qrencode}/bin/qrencode \
    -o "$OUTPUT" \
    -s 10 \
    -l H \
    -m 2 \
    "$TEXT"

  echo "QR code generated: $OUTPUT"
''
