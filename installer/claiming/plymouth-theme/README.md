# Plymouth Theme Images

This directory contains image assets for the SeloraBox Plymouth boot theme.

## Required Images

### background.png
- Full screen background image
- Recommended size: 1920x1080 (or your target resolution)
- Should be a solid color or subtle gradient
- This should be created by the design team

### logo.png
- Selora logo
- Recommended size: 400x200 (or appropriate aspect ratio)
- Transparent background (PNG with alpha channel)
- Positioned at top center of screen
- This should be provided by the design/marketing team

### qr.png (placeholder)
- QR code placeholder
- Size: 300x300 pixels
- This will be replaced dynamically by the claiming script
- The placeholder should be a simple frame or text saying "QR Code"

## Creating Placeholder Images

You can create simple placeholder images using ImageMagick:

```bash
# Background (solid dark blue)
convert -size 1920x1080 xc:'#1a237e' background.png

# Logo placeholder (white text on transparent)
convert -size 400x200 xc:transparent \
  -gravity center -pointsize 48 -fill white \
  -annotate +0+0 "SELORA" \
  logo.png

# QR code placeholder (white frame)
convert -size 300x300 xc:transparent \
  -stroke white -strokewidth 4 -fill none \
  -draw "rectangle 20,20 280,280" \
  -gravity center -pointsize 24 -fill white \
  -annotate +0+0 "QR CODE" \
  qr.png
```

## Notes

- All images should be PNG format
- The claiming script will replace qr.png with the actual QR code
- Plymouth will automatically reload qr.png when updated
- Images are displayed in this Z-order: background (0), logo (1), QR (2), message text (3)
