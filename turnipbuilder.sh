#!/bin/bash -e

# A bash script for Linux designed to build ADPKG and Magisk Mesa Turnip drivers on Debian-based systems.
# Based on work by ilhan-athn7 and K11MCH1.
# Cross compile script provided by Aurified.Dev and Lumo
# Optimized for Mesa 26.X.X (Stable/Dev) with Android NDK r27d.
# Ensure update NDK for next LTS version

# Define variables
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[1;33m'
nocolor='\033[0m'
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r27d"
ndk_base="$workdir/$ndkver"
# Persistent NDK cache OUTSIDE the workdir so it survives wipes
ndk_cache="$HOME/.cache/turnip_builder_ndk"
sdkver="34"

# === BUILD CONFIGURATION ===
BUILD_TYPE="STABLE"  # <--- Change to "STABLE" or "DEV"

if [ "$BUILD_TYPE" == "DEV" ]; then
    mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.zip"
    NAME_PREFIX="DEVEL"
    DESCRIPTION="Development branch open-source Vulkan driver for Adreno GPUs based on Mesa."
    MODULE_NAME="Aurified.Turnip DEVEL"
elif [ "$BUILD_TYPE" == "STABLE" ]; then
    mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-26.2.2/mesa-mesa-26.2.2.zip"
    NAME_PREFIX="GA"
    DESCRIPTION="Stable open-source Vulkan driver for Adreno GPUs based on Mesa."
    MODULE_NAME="Aurified.Turnip GA"
else
    echo -e "$red ERROR: Invalid BUILD_TYPE '$BUILD_TYPE'. Must be 'STABLE' or 'DEV'. $nocolor"
    exit 1
fi

clear

run_all(){
    check_deps
    prepare_workdir
    build_lib_for_android
    port_lib_for_magisk
    create_backup_package
}

# === VERSION HELPER (top-level, called explicitly, defined ONCE) ===
get_mesa_version(){
    if [ -z "$MESASRC_DIR" ]; then
        echo -e "$red ERROR: Mesa source directory variable not set! $nocolor"
        exit 1
    fi
    version=$(grep -oP '^\d+\.\d+\.\d+' "$workdir/$MESASRC_DIR/VERSION" 2>/dev/null || echo "Unknown")

    # Date-stamp DEV builds: same reported version + different code = distinguishable packages
    if [ "$BUILD_TYPE" == "DEV" ]; then
        version="${version}_$(date +%Y%m%d)"
    fi

    version_code=$(echo "$version" | tr -cd '0-9')
    # Guard: invalid or empty versionCode would break module.prop parsing in Magisk
    if [ -z "$version_code" ] || [ "$version_code" -lt 100000 ]; then
        version_code=$((10000 + $(date +%y%m%d)))  # Fallback: YYMMDD keeps increments monotonic
    fi
    export version
    export version_code
}

check_deps(){
    echo "Checking system for required Dependencies ..."
    deps_missing=0

    bin_deps="meson ninja patchelf unzip curl flex bison zip glslang glslangValidator python3"
    pkg_deps="python3-dev python3-pip ninja-build python3-yaml libarchive-dev libconfig-dev libncurses-dev libconfig-doc libconfig11 libxml2 libelf-dev cmake g++ libzstd-dev"

    for dep in $bin_deps; do
        if command -v "$dep" >/dev/null 2>&1; then
            echo -e "$green ✓ $dep found $nocolor"
        else
            echo -e "$red ✗ $dep not found $nocolor"
            deps_missing=1
        fi
    done

    for pkg in $pkg_deps; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            echo -e "$green ✓ $pkg installed $nocolor"
        else
            echo -e "$red ✗ $pkg not installed $nocolor"
            deps_missing=1
        fi
    done

    if [ "$deps_missing" -eq 1 ]; then
        echo -e "\n$red Missing dependencies detected! $nocolor"
        echo "Install them with:"
        echo "  sudo apt update && sudo apt install ${bin_deps// / } ${pkg_deps// / }"
        exit 1
    fi

    echo -e "\nInstalling Python dependencies for Mesa..."
    pip3 install pyyaml mako --break-system-packages 2>/dev/null || pip install pyyaml mako
    echo -e "$green All dependencies satisfied! $nocolor\n"
}

prepare_workdir(){
    echo "Preparing work directory ..."
    rm -rf "$workdir"
    mkdir -p "$workdir"
    mkdir -p "$ndk_cache"

    # --- CACHED NDK DOWNLOAD ---
    # The NDK (~700MB) is stored OUTSIDE the wiped workdir and reused between runs.
    # To force a fresh NDK, delete ~/.cache/turnip_builder_ndk
    if [ -d "$ndk_cache/$ndkver" ]; then
        echo -e "$green Using cached NDK: $ndk_cache/$ndkver $nocolor"
    else
        echo "Downloading Android NDK ($ndkver)..."
        ndk_url="https://dl.google.com/android/repository/${ndkver}-linux.zip"
        if ! curl -L "$ndk_url" --output "$ndk_cache/${ndkver}.zip" --fail; then
            echo -e "$red Failed to download NDK. Trying alternative version... $nocolor"
            ndkver="android-ndk-r27c"
            ndk_url="https://dl.google.com/android/repository/${ndkver}-linux.zip"
            curl -L "$ndk_url" --output "$ndk_cache/${ndkver}.zip" --fail || {
                echo -e "$red Could not download NDK. Please download manually. $nocolor"
                exit 1
            }
        fi

        echo "Extracting NDK..."
        unzip -q -o "$ndk_cache/${ndkver}.zip" -d "$ndk_cache"
        rm -f "$ndk_cache/${ndkver}.zip"
    fi

    cd "$workdir"

    echo "Downloading Mesa source..."
    curl -L "$mesasrc" --output mesa-source.zip --fail
    echo "Extracting Mesa source..."
    unzip -q mesa-source.zip

    # Auto-detect the extracted directory name
    MESASRC_DIR=$(ls -d mesa-* 2>/dev/null | head -1)
    if [ -z "$MESASRC_DIR" ]; then
        echo -e "$red Failed to find extracted Mesa source directory! $nocolor"
        ls -la
        exit 1
    fi

    echo "Found Mesa source directory: $MESASRC_DIR"

    # EXPORT this variable so other functions can see it!
    export MESASRC_DIR

    cd "$MESASRC_DIR"
}

build_lib_for_android(){
    # NDK now lives in the persistent cache, not inside the wiped workdir
    NDK_TOOLCHAIN="$ndk_cache/$ndkver/toolchains/llvm/prebuilt/linux-x86_64"

    if [ ! -d "$NDK_TOOLCHAIN" ]; then
        echo -e "$red ERROR: NDK toolchain not found at $NDK_TOOLDIR $nocolor"
        echo "Delete $ndk_cache and re-run to re-download."
        exit 1
    fi

    # --- ZSTD HEADER SETUP ---
    echo "Downloading Zstd headers for cross-compilation..."
    ZSTD_VER="1.5.6"
    ZSTD_TARBALL="$workdir/zstd-${ZSTD_VER}.tar.gz"
    ZSTD_EXTRACTED="$workdir/zstd-${ZSTD_VER}"
    ZSTD_INC_DIR="$workdir/zstd-include"

    rm -rf "$ZSTD_EXTRACTED" "$ZSTD_INC_DIR"
    mkdir -p "$ZSTD_INC_DIR"

    # Download
    if curl -L "https://github.com/facebook/zstd/archive/refs/tags/v${ZSTD_VER}.tar.gz" --output "$ZSTD_TARBALL" --fail; then
        echo "Extracting Zstd source..."
        tar -xzf "$ZSTD_TARBALL" -C "$workdir"

        # The extracted folder is 'zstd-1.5.6', not 'zstd-src'
        if [ -d "$ZSTD_EXTRACTED" ]; then
            echo "Copying headers from $ZSTD_EXTRACTED..."
            # Copy the main header
            cp "$ZSTD_EXTRACTED/lib/zstd.h" "$ZSTD_INC_DIR/" 2>/dev/null

            # Copy sub-headers if they exist (common, compress, decompress)
            if [ -d "$ZSTD_EXTRACTED/lib/common" ]; then
                cp "$ZSTD_EXTRACTED/lib/common"/*.h "$ZSTD_INC_DIR/" 2>/dev/null
            fi
            if [ -d "$ZSTD_EXTRACTED/lib/compress" ]; then
                cp "$ZSTD_EXTRACTED/lib/compress"/*.h "$ZSTD_INC_DIR/" 2>/dev/null
            fi
            if [ -d "$ZSTD_EXTRACTED/lib/decompress" ]; then
                cp "$ZSTD_EXTRACTED/lib/decompress"/*.h "$ZSTD_INC_DIR/" 2>/dev/null
            fi

            echo "Zstd headers extracted to: $ZSTD_INC_DIR"

            # Cleanup source
            rm -rf "$ZSTD_EXTRACTED"
            rm "$ZSTD_TARBALL"
        else
            echo -e "$red ERROR: Zstd extraction failed. Folder not found. $nocolor"
            rm -f "$ZSTD_TARBALL"
        fi
    else
        echo -e "$red Failed to download Zstd headers. Disabling Zstd. $nocolor"
        rm -f "$ZSTD_TARBALL"
    fi
    # ---------------------------

    echo "Creating cross-compilation configuration files..."

    # Check for headers
    ZSTD_C_ARG=""
    if [ -d "$ZSTD_INC_DIR" ] && [ -f "$ZSTD_INC_DIR/zstd.h" ]; then
        ZSTD_C_ARG="-I$ZSTD_INC_DIR"
        echo "Zstd headers found. Adding to compiler args."
    else
        echo "Zstd headers NOT found. Disabling Zstd support."
    fi

    # Generate the c_args line based on whether we have headers
    if [ -n "$ZSTD_C_ARG" ]; then
        C_ARGS_LINE="c_args = ['-DANDROID', '$ZSTD_C_ARG']"
    else
        C_ARGS_LINE="c_args = ['-DANDROID']"
    fi

    cat >"android-aarch64.txt" <<EOF
[binaries]
c = ['$NDK_TOOLCHAIN/bin/aarch64-linux-android${sdkver}-clang']
cpp = ['$NDK_TOOLCHAIN/bin/aarch64-linux-android${sdkver}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
ar = '$NDK_TOOLCHAIN/bin/llvm-ar'
strip = '$NDK_TOOLCHAIN/bin/llvm-strip'
c_ld = 'lld'
cpp_ld = 'lld'
pkg-config = 'pkg-config'
python = '/usr/bin/python3'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
$C_ARGS_LINE
cpp_args = ['-DANDROID']
EOF

    cat >"native.txt" <<EOF
[build_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[binaries]
c = 'gcc'
cpp = 'g++'
ar = 'ar'
strip = 'strip'
python = '/usr/bin/python3'
EOF

    # Ensure 'python' command is available
    if ! command -v python >/dev/null 2>&1; then
        echo "Creating 'python' symlink to python3..."
        if sudo ln -sf $(which python3) /usr/local/bin/python 2>/dev/null; then
            echo "Created /usr/local/bin/python -> python3"
        else
            mkdir -p "$workdir/bin"
            ln -sf $(which python3) "$workdir/bin/python"
            export PATH="$workdir/bin:$PATH"
            echo "Created $workdir/bin/python -> python3"
        fi
    fi

    # Create zlib stubs to satisfy linker without real libz
    echo "Creating zlib stubs..."
    mkdir -p "$workdir/stub_libs"

    cat > "$workdir/stub_libs/zlib_stubs.c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
typedef void* gzFile;
gzFile gzopen(const char *path, const char *mode) { return NULL; }
int gzclose(gzFile file) { return 0; }
int gzwrite(gzFile file, const void *buf, unsigned len) { return 0; }
const char* gzerror(gzFile file, int *errnum) { return NULL; }
int gzflush(gzFile file, int flush) { return 0; }
int gzread(gzFile file, void *buf, unsigned len) { return 0; }
EOF

    # FIXED: proper error check pattern (works under set -e)
    if ! "$NDK_TOOLCHAIN/bin/aarch64-linux-android${sdkver}-clang" -c -o "$workdir/stub_libs/zlib_stubs.o" "$workdir/stub_libs/zlib_stubs.c"; then
        echo -e "$red ERROR: Failed to compile zlib stubs! $nocolor"
        exit 1
    fi
    if ! ar rcs "$workdir/stub_libs/libz_stub.a" "$workdir/stub_libs/zlib_stubs.o"; then
        echo -e "$red ERROR: Failed to archive zlib stubs! $nocolor"
        exit 1
    fi
    echo "Zlib stubs created."

    # Patch perfcntrs to avoid "Unknown variable" error (Robust Pattern Match)
    if [ -f "src/freedreno/perfcntrs/meson.build" ]; then
        # Find the line with "libfreedreno_drm" and comment it out
        sed -i '/libfreedreno_drm/s/^/# PATCHED: /' "src/freedreno/perfcntrs/meson.build"
        echo "Patched perfcntrs/meson.build for libfreedreno_drm."
    fi

    # Determine Zstd flag
    if [ -n "$ZSTD_C_ARG" ]; then
        ZSTD_FLAG="-Dzstd=enabled"
        echo "Zstd enabled with custom headers."
    else
        ZSTD_FLAG="-Dzstd=disabled"
        echo "Zstd disabled (headers missing)."
    fi

    echo "Configuring Meson build (Zstd: $ZSTD_FLAG)..."

    if ! meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --wipe \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version="$sdkver" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Db_lto=false \
        -Dstrip=true \
        -Degl=disabled \
        $ZSTD_FLAG \
        -Dspirv-tools=disabled \
        -Dzlib=disabled \
        -Dshader-cache=disabled \
        -Dc_link_args="-L$workdir/stub_libs -lz_stub -ldl" \
        >"$workdir/meson_config.log" 2>&1; then

        echo -e "$red Meson configuration failed! $nocolor"
        tail -50 "$workdir/meson_config.log"

        # Fallback: only fire when zstd is genuinely the culprit (log signature match,
        # not a broad grep that matches the success summary too)
        if grep -qiE "(zstd\.h.*(not found|No such)|dependency .zstd. .* not found|CMake failed for zstd)" "$workdir/meson_config.log"; then
            echo -e "$yellow Zstd failed. Retrying with Zstd disabled... $nocolor"
            ZSTD_FLAG="-Dzstd=disabled"

            # Also drop the zstd include from the cross-file so the fallback build
            # matches the disabled-zstd configuration
            sed -i "s|c_args = \['-DANDROID', '[^']*'\]|c_args = ['-DANDROID']|" android-aarch64.txt

            if ! meson setup build-android-aarch64 \
                --cross-file "android-aarch64.txt" \
                --native-file "native.txt" \
                --wipe \
                -Dbuildtype=release \
                -Dplatforms=android \
                -Dplatform-sdk-version="$sdkver" \
                -Dandroid-stub=true \
                -Dgallium-drivers= \
                -Dvulkan-drivers=freedreno \
                -Dvulkan-beta=true \
                -Dfreedreno-kmds=kgsl \
                -Db_lto=false \
                -Dstrip=true \
                -Degl=disabled \
                $ZSTD_FLAG \
                -Dspirv-tools=disabled \
                -Dzlib=disabled \
                -Dshader-cache=disabled \
                -Dc_link_args="-L$workdir/stub_libs -lz_stub -ldl" \
                >"$workdir/meson_config.log" 2>&1; then

                echo -e "$red Meson configuration failed even with Zstd disabled! $nocolor"
                tail -50 "$workdir/meson_config.log"
                exit 1
            fi
            echo -e "$green Build configured with Zstd disabled (Fallback). $nocolor"
        else
            exit 1
        fi
    else
        echo -e "$green Build configured with Zstd enabled! $nocolor"
    fi

    echo "Patching build.ninja to remove host libraries and inject stubs..."
    if [ -f "build-android-aarch64/build.ninja" ]; then
        # Remove host libelf, libz, AND libzstd paths (single consolidated block — was duplicated before)
        sed -i 's| /usr/lib/x86_64-linux-gnu/libelf.so||g' build-android-aarch64/build.ninja
        sed -i 's| /usr/lib/x86_64-linux-gnu/libz.so||g' build-android-aarch64/build.ninja
        sed -i 's| /usr/lib/x86_64-linux-gnu/libzstd.so||g' build-android-aarch64/build.ninja

        # Inject our stub library right before --end-group
        STUB_LIB_PATH="$workdir/stub_libs/libz_stub.a"
        sed -i "s| -Wl,--end-group| ${STUB_LIB_PATH} -Wl,--end-group|" build-android-aarch64/build.ninja

        if grep -q "${STUB_LIB_PATH}" build-android-aarch64/build.ninja; then
            echo "Successfully injected zlib stubs."
        else
            echo "WARNING: Stub injection might have failed. Check build.ninja."
        fi
    else
        echo "ERROR: build.ninja not found!"
        exit 1
    fi

    # Create dummy files for test tools to satisfy dependencies if they were built
    mkdir -p build-android-aarch64/src/freedreno/ir3/
    mkdir -p build-android-aarch64/src/freedreno/fdl/
    touch build-android-aarch64/src/freedreno/ir3/ir3_disasm
    touch build-android-aarch64/src/freedreno/ir3/ir3_delay_test
    touch build-android-aarch64/src/freedreno/fdl/fd5_layout
    touch build-android-aarch64/src/freedreno/fdl/fd6_layout

    echo "Building with Ninja..."
    if ! ninja -C build-android-aarch64 >"$workdir/ninja_build.log" 2>&1; then
        echo -e "$red Build failed! $nocolor"
        tail -50 "$workdir/ninja_build.log"
        exit 1
    fi

    if [ ! -f "build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so" ]; then
        echo -e "$red Output library not found! $nocolor"
        exit 1
    fi

    echo -e "$green Build completed successfully! $nocolor"
}

port_lib_for_magisk(){
    echo "Preparing Magisk module..."

    # Ensure we are in the workdir
    cd "$workdir"

    # Get the version ONCE via the top-level helper
    get_mesa_version
    echo "Packaging version: $version (versionCode: $version_code)"

    BUILD_PATH="$workdir/$MESASRC_DIR/build-android-aarch64"
    SOURCE_LIB="$BUILD_PATH/src/freedreno/vulkan/libvulkan_freedreno.so"

    # Verify the built library exists
    if [ ! -f "$SOURCE_LIB" ]; then
        echo -e "$red ERROR: Built library not found at: $SOURCE_LIB $nocolor"
        echo "Checking if build directory exists..."
        if [ -d "$BUILD_PATH" ]; then
            echo "Build directory exists. Contents:"
            ls -la "$BUILD_PATH/src/freedreno/vulkan/" 2>/dev/null || echo "Vulkan folder missing."
        else
            echo "Build directory does not exist: $BUILD_PATH"
        fi
        exit 1
    fi

    echo "Found library at: $SOURCE_LIB"

    # Copy the library to workdir root
    cp "$SOURCE_LIB" "$workdir/vulkan.turnip.so"

    # Set the soname
    patchelf --set-soname vulkan.turnip.so "$workdir/vulkan.turnip.so"

    magiskdir="$workdir/turnip_module"
    p1="system/vendor/lib64/hw"
    mkdir -p "$magiskdir/$p1"

    meta="META-INF/com/google/android"
    mkdir -p "$magiskdir/$meta"

    cd "$magiskdir"

    cat >"$magiskdir/module.prop" <<EOF
id=turnip
name=💰${MODULE_NAME}${version} Vulkan Driver
version=${NAME_PREFIX}$version
versionCode=$version_code
author=Aurified.Dev
description=💰${MODULE_NAME} is a ${DESCRIPTION} Debug and GPU Cache Disabled.
minApi=29
EOF

    cat >"$magiskdir/$meta/updater-script" <<EOF
#MAGISK
EOF

    cat >"$magiskdir/system.prop" <<EOF
ro.hardware.vulkan=turnip
EOF

    cat >"$magiskdir/customize.sh" <<EOF
#!/system/bin/sh
# Magisk Module Install Script for Turnip Vulkan Driver
# Simplified - No pre-check (files guaranteed by Aurified/Check-sha512 - Magisk)

MODPATH=\$1

# Define paths
TARGET_DIR="\$MODPATH/system/vendor/lib64/hw"
DRIVER_FILE="vulkan.turnip.so"
FULL_PATH="\$TARGET_DIR/\$DRIVER_FILE"

# 1. Create directory structure
mkdir -p "\$TARGET_DIR"

# 2. Set Permissions
set_perm_recursive "\$MODPATH/system" 0 0 0755 0644
set_perm "\$FULL_PATH" 0 0 0644

ui_print "✅ Driver permissions set: \$DRIVER_FILE"

# 3. Create Symlink (CRITICAL)
VULKAN_LOADER="\$MODPATH/system/vendor/lib64/libvulkan.so"

# Remove old symlink/file if exists
if [ -L "\$VULKAN_LOADER" ] || [ -f "\$VULKAN_LOADER" ]; then
    rm -f "\$VULKAN_LOADER"
fi

# Create symlink: libvulkan.so -> vulkan.turnip.so
ln -sf "\$DRIVER_FILE" "\$VULKAN_LOADER"

ui_print "✅ Symlink created: libvulkan.so -> \$DRIVER_FILE"
ui_print "✅ Installation complete. Reboot required."
EOF

    cp "$workdir/vulkan.turnip.so" "$magiskdir/$p1/"

    cd "$magiskdir"
    if ! zip -r "$workdir/turnip_module.zip" ./* >/dev/null 2>&1; then
        echo -e "$red Failed to create Magisk module ZIP! $nocolor"
        exit 1
    fi

    echo -e "$green Magisk module created: $workdir/turnip_module.zip $nocolor"
}

create_backup_package(){
    echo "Creating Version Specific Aurified ADPKG Package and Magisk Module..."

    # Ensure we are in the workdir
    cd "$workdir"

    # Verify the library exists
    if [ ! -f "$workdir/vulkan.turnip.so" ]; then
        echo -e "$red ERROR: vulkan.turnip.so not found! $nocolor"
        exit 1
    fi

    # Get the version (helper reuses the same logic everywhere)
    get_mesa_version

    # Define folder names using the dynamic prefix (date-suffixed for DEV builds)
    backup_folder="Aurified_Turnip_${NAME_PREFIX}${version}.adpkg"
    magisk_backup_folder="Aurified_Turnip_Magisk_Module_${NAME_PREFIX}${version}"

    echo "Creating backup folder: $backup_folder"

    # --- CREATE FOLDERS FIRST ---
    mkdir -p "$backup_folder"
    mkdir -p "$magisk_backup_folder"
    # ------------------------------------------

    # Copy the library
    cp "$workdir/vulkan.turnip.so" "$backup_folder/"

    # Create the meta.json (folder exists now)
    cat > "$backup_folder/meta.json" <<EOF
{
  "schemaVersion": 1,
  "name": "💰${MODULE_NAME}${version}",
  "description": "${NAME_PREFIX}${version} - ${DESCRIPTION} Debug and GPU Cache disabled",
  "author": "Aurified.Dev",
  "packageVersion": "${NAME_PREFIX}${version}",
  "vendor": "Mesa3D",
  "driverVersion": "${version}",
  "minApi": 29,
  "libraryName": "vulkan.turnip.so"
}
EOF

    # Copy the ENTIRE Magisk module directory
    cp -r "$workdir/turnip_module"/* "$magisk_backup_folder/"

    # Zip the ADPKG folder (contents only)
    cd "$backup_folder"
    if zip -r "../$backup_folder.zip" ./*; then
        echo -e "$green ADPKG package created: $workdir/$backup_folder.zip $nocolor"
    else
        echo -e "$red Failed to create ADPKG zip! $nocolor"
    fi
    cd "$workdir"

    # Zip the Magisk Module Backup (contents only)
    cd "$magisk_backup_folder"
    if zip -r "../$magisk_backup_folder.zip" ./*; then
        echo -e "$green Magisk Module Backup created: $workdir/$magisk_backup_folder.zip $nocolor"
    else
        echo -e "$red Failed to create Magisk backup zip! $nocolor"
    fi
    cd "$workdir"

    echo -e "$green Generation process completed! $nocolor"
}

run_all
