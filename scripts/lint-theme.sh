#!/bin/zsh
# Fails if a view holds a style number instead of a theme token (Shared/Theme) or kit part
# (Shared/Kit). Drawing code (logos, mode icons, the K mark), the theme itself, and the
# debug hook are exempt; a line can opt out with `// lint:allow <reason>`.
cd "$(dirname "$0")/.." || exit 2
patterns=(
  'cornerRadius: *[0-9]'
  '\.padding\( *[0-9]'
  '\.padding\(\.[a-zA-Z]+, *[0-9]'
  'spacing: *[1-9]'
  'minLength: *[1-9]'
  '\.frame\([^)]*(width|height|minWidth|maxWidth|minHeight|maxHeight): *[0-9]'
  '\.font\(\.system\(size:'
  '\.kore\( *[0-9]'
  '\.koreMono\('
  'Color\((red|white|hex|\.)'
  '\.opacity\( *0?\.[0-9]'
  'lineWidth: *[0-9]'
  'lineSpacing\( *[0-9]'
  'duration: *[0-9]'
  '\.shadow\('
  'ProviderLogo\(.*size: *[0-9]'
  'BrandMark\(height: *[0-9]'
  'defaultSize\(width: *[0-9]'
)
files=(${(f)"$(find Sources/Kore -name '*.swift' \
  -not -path '*/Shared/Theme/*' -not -path '*/Shared/Kit/*' \
  -not -name BrandMark.swift -not -name Logos.swift -not -name ModeIcons.swift -not -name DevSnapshot.swift -not -name DevGallery.swift -not -name DevTimelineGallery.swift)"})
hits=$(grep -nE "${(j:|:)patterns}" $files | grep -v 'lint:allow')
if [[ -n $hits ]]; then
  print -r -- "$hits"
  print "\n$(print -r -- "$hits" | wc -l | tr -d ' ') style literal(s) in views: use Shared/Theme tokens or Shared/Kit parts."
  exit 1
fi
print "theme lint: clean"
