#!/bin/bash
# Build the same pinned Whisper source as the qualified local app, macOS only.
set -euo pipefail
revision=764482c3175d9c3bc6089c1ec84df7d1b9537d83
root="$HOME/VoiceInk-Dependencies/whisper.cpp"
if [[ -e "$root" ]]; then
  [[ $(git -C "$root" rev-parse HEAD) == "$revision" && -z $(git -C "$root" status --porcelain) ]] || { echo 'Existing Whisper checkout differs; preserve it and select a clean runner.' >&2; exit 1; }
else
  mkdir -p "$(dirname "$root")"
  git init "$root"
  git -C "$root" remote add origin https://github.com/ggml-org/whisper.cpp.git
  git -C "$root" fetch --depth 1 origin "$revision"
  git -C "$root" checkout --detach FETCH_HEAD
fi
[[ $(git -C "$root" rev-parse HEAD) == "$revision" ]]
if [[ -d "$root/build-apple/whisper.xcframework" ]]; then exit 0; fi
cd "$root"
cmake -S . -B build-ci -G Xcode -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF
cmake --build build-ci --config Release -- -quiet
framework="$root/build-ci/framework/whisper.framework"
mkdir -p "$framework/Versions/A/Headers" "$framework/Versions/A/Modules" "$framework/Versions/A/Resources"
ln -sfn A "$framework/Versions/Current"
for part in Headers Modules Resources whisper; do ln -sfn "Versions/Current/$part" "$framework/$part"; done
cp include/whisper.h ggml/include/ggml*.h ggml/include/gguf.h "$framework/Headers/"
cat > "$framework/Modules/module.modulemap" <<'MODULE'
framework module whisper {
  header "whisper.h"
  header "ggml.h"
  header "ggml-alloc.h"
  header "ggml-backend.h"
  header "ggml-metal.h"
  header "ggml-cpu.h"
  header "ggml-blas.h"
  header "gguf.h"
  link "c++"
  link framework "Accelerate"
  link framework "Metal"
  link framework "Foundation"
  export *
}
MODULE
mapfile_path="$root/build-ci/static-libraries.txt"
find "$root/build-ci" -type f -name '*.a' ! -name combined.a > "$mapfile_path"
libraries=(); while IFS= read -r library; do libraries+=("$library"); done < "$mapfile_path"
[[ ${#libraries[@]} -gt 0 ]]
xcrun libtool -static -o "$root/build-ci/combined.a" "${libraries[@]}"
xcrun --sdk macosx clang++ -dynamiclib -arch arm64 -mmacosx-version-min=15.0 \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -Wl,-force_load,"$root/build-ci/combined.a" \
  -framework Foundation -framework Metal -framework Accelerate -framework CoreML \
  -install_name @rpath/whisper.framework/Versions/Current/whisper -o "$framework/Versions/A/whisper"
cat > "$framework/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.whispercpp.whisper</string><key>CFBundleExecutable</key><string>whisper</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.8.3</string><key>MinimumOSVersion</key><string>15.0</string></dict></plist>
PLIST
mkdir -p "$root/build-apple"
xcodebuild -create-xcframework -framework "$framework" -output "$root/build-apple/whisper.xcframework"
