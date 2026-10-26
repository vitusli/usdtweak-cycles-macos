#!/usr/bin/env bash
#
# build.sh – Build usdtweak + Cycles Hydra render delegate on macOS Apple Silicon
#
# Usage:  bash build.sh
#
# Prerequisites: Xcode Command Line Tools, ~30 GB disk space
#
set -euo pipefail

USDTWEAK_BRANCH="${USDTWEAK_BRANCH:-develop}"
BLENDER_BRANCH="${BLENDER_BRANCH:-main}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${ROOT_DIR}/source"
DEPS_DIR="${ROOT_DIR}/deps"
BUILD_DIR="${ROOT_DIR}/build"
PATCHES_DIR="${ROOT_DIR}/patches"

BLENDER_DIR="${DEPS_DIR}/blender"
BLENDER_LIBS="${BLENDER_DIR}/lib/macos_arm64"
CYCLES_BUILD="${BLENDER_DIR}/build_cycles"
COMPAT_DIR="${DEPS_DIR}/conda_usd_compat"

git_lfs() {
    git \
        -c filter.lfs.required=true \
        -c "filter.lfs.clean=git-lfs clean -- %f" \
        -c "filter.lfs.smudge=git-lfs smudge -- %f" \
        -c "filter.lfs.process=git-lfs filter-process" \
        -C "$1" lfs "${@:2}"
}

# Drop a CMake build dir whose cached SDK no longer exists (e.g. after an
# Xcode / Command Line Tools update removed the old SDK)
drop_stale_cmake_cache() {
    local cache="$1/CMakeCache.txt" sysroot
    [ -f "${cache}" ] || return 0
    sysroot=$(sed -n 's/^CMAKE_OSX_SYSROOT:PATH=//p' "${cache}")
    if [ -n "${sysroot}" ] && [ ! -d "${sysroot}" ]; then
        echo "==> Removing stale CMake cache in $1 (missing SDK ${sysroot}) …"
        rm -rf "$1"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Ensure pixi is installed
# ─────────────────────────────────────────────────────────────────────────────
# Add pixi to PATH for this script (no need to pollute .zshrc)
export PATH="$HOME/.pixi/bin:$PATH"
if ! command -v pixi &>/dev/null; then
    echo "==> Installing pixi …"
    curl -fsSL https://pixi.sh/install.sh | bash
fi
echo "==> pixi $(pixi --version)"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Clone / update usdtweak
# ─────────────────────────────────────────────────────────────────────────────
if [ -d "${SOURCE_DIR}/.git" ]; then
    echo "==> Updating usdtweak source (${USDTWEAK_BRANCH}) …"
    git -C "${SOURCE_DIR}" fetch origin
    git -C "${SOURCE_DIR}" checkout "${USDTWEAK_BRANCH}"
    git -C "${SOURCE_DIR}" pull --ff-only origin "${USDTWEAK_BRANCH}" || true
else
    echo "==> Cloning usdtweak (${USDTWEAK_BRANCH}) …"
    git clone --branch "${USDTWEAK_BRANCH}" https://github.com/cpichard/usdtweak.git "${SOURCE_DIR}"
fi
echo "==> usdtweak commit: $(git -C "${SOURCE_DIR}" rev-parse --short HEAD)"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Patch pixi.toml constraints (upstream may be too tight)
# ─────────────────────────────────────────────────────────────────────────────
cd "${SOURCE_DIR}"

if grep -q 'glfw = ">=3\.5' pixi.toml 2>/dev/null; then
    echo "==> Patching pixi.toml: relaxing glfw constraint …"
    sed -i '' 's/glfw = ">=3\.5\.[0-9]*,<[0-9]*"/glfw = ">=3.4,<4"/' pixi.toml
fi
if grep -q 'openusd = ">=25\.' pixi.toml 2>/dev/null; then
    echo "==> Patching pixi.toml: relaxing openusd constraint …"
    sed -i '' 's/openusd = ">=25\.[0-9.]*,<[0-9]*"/openusd = ">=24,<27"/' pixi.toml
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Build usdtweak via pixi (configure → build → install)
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Installing dependencies via pixi …"
pixi install -e install

# Workaround: CMake install expects lib/python but conda provides lib/python3.XX
PIXI_ENV="${SOURCE_DIR}/.pixi/envs/install"
PIXI_LIB="${PIXI_ENV}/lib"
if [ ! -e "${PIXI_LIB}/python" ]; then
    PYDIR=$(ls -d "${PIXI_LIB}"/python3.* 2>/dev/null | head -1)
    if [ -n "${PYDIR}" ]; then
        echo "==> Creating python symlink: $(basename "${PYDIR}") → python …"
        ln -sf "$(basename "${PYDIR}")" "${PIXI_LIB}/python"
    fi
fi

drop_stale_cmake_cache "${SOURCE_DIR}/.build"

echo "==> Building usdtweak …"
pixi run -e install install

# The install target puts the app in source/build/ (CMAKE_INSTALL_PREFIX=./build)
USDTWEAK_APP="${SOURCE_DIR}/build/usdtweak.app"
if [ ! -d "${USDTWEAK_APP}" ]; then
    echo "ERROR: usdtweak.app not found after build"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Clone Blender + precompiled ARM64 libs (for Cycles dependencies)
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${DEPS_DIR}"

if [ -d "${BLENDER_DIR}/.git" ]; then
    echo "==> Updating Blender (${BLENDER_BRANCH}) …"
    git -C "${BLENDER_DIR}" fetch --depth=1 origin "${BLENDER_BRANCH}"
    # Revert our patches from a previous build so the checkout can proceed
    git -C "${BLENDER_DIR}" checkout -- CMakeLists.txt intern/cycles/ 2>/dev/null || true
    git -C "${BLENDER_DIR}" checkout FETCH_HEAD
else
    echo "==> Cloning Blender (shallow, ${BLENDER_BRANCH}) …"
    git clone --depth=1 --branch "${BLENDER_BRANCH}" \
        https://projects.blender.org/blender/blender.git "${BLENDER_DIR}"
fi
echo "==> Blender commit: $(git -C "${BLENDER_DIR}" rev-parse --short HEAD)"

# We only build Cycles/hdCycles, not the Blender application. Blender's top-level
# CMake still rejects Git-LFS pointer files such as startup.blend unconditionally.
STARTUP_BLEND="${BLENDER_DIR}/release/datafiles/startup.blend"
if [ -f "${STARTUP_BLEND}" ] && [ "$(wc -c < "${STARTUP_BLEND}")" -lt 1024 ]; then
    if command -v git-lfs &>/dev/null; then
        echo "==> Fetching Blender Git LFS assets …"
        git_lfs "${BLENDER_DIR}" pull --include="release/datafiles/startup.blend"
    else
        echo "==> Removing incomplete startup.blend Git LFS pointer (Cycles-only build) …"
        rm -f "${STARTUP_BLEND}"
    fi
fi

if [ -d "${BLENDER_LIBS}" ] && [ ! -d "${BLENDER_LIBS}/.git" ] && [ ! -d "${BLENDER_LIBS}/embree" ]; then
    echo "==> Removing incomplete Blender precompiled libs directory …"
    rm -rf "${BLENDER_LIBS}"
fi

if [ -d "${BLENDER_LIBS}/.git" ]; then
    echo "==> Updating Blender precompiled libs …"
    # Undo the USD wrapper swap from a previous build (step 6) so the pull is clean
    if [ -L "${BLENDER_LIBS}/usd" ]; then
        rm "${BLENDER_LIBS}/usd"
        rm -rf "${BLENDER_LIBS}/usd_orig"
        GIT_LFS_SKIP_SMUDGE=1 git -C "${BLENDER_LIBS}" checkout -- usd
    fi
    # LFS objects are fetched below by `git lfs pull`
    GIT_LFS_SKIP_SMUDGE=1 git \
        -c filter.lfs.required=true \
        -c "filter.lfs.clean=git-lfs clean -- %f" \
        -c "filter.lfs.smudge=git-lfs smudge -- %f" \
        -c "filter.lfs.process=git-lfs filter-process" \
        -C "${BLENDER_LIBS}" pull --ff-only
elif [ -d "${BLENDER_LIBS}" ]; then
    echo "==> Blender precompiled libs directory exists (no .git), skipping clone …"
else
    echo "==> Cloning Blender precompiled ARM64 libs (this may take a while) …"
    mkdir -p "${BLENDER_DIR}/lib"
    git clone --depth=1 \
        https://projects.blender.org/blender/lib-macos_arm64.git "${BLENDER_LIBS}"
fi

if ! command -v git-lfs &>/dev/null; then
    echo "ERROR: git-lfs is required for Blender precompiled libraries. Install it with: brew install git-lfs"
    exit 1
fi
echo "==> Fetching Blender precompiled library Git LFS assets …"
git_lfs "${BLENDER_LIBS}" pull --exclude="usd/**"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Create conda USD compatibility wrapper
#    Blender's build system expects a single libusd_ms.dylib. We create a
#    wrapper that re-exports all individual conda-forge USD libraries.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Creating conda USD compat wrapper …"
mkdir -p "${COMPAT_DIR}/lib" "${COMPAT_DIR}/include"

# Symlink headers
ln -sfn "${PIXI_ENV}/include/pxr" "${COMPAT_DIR}/include/pxr"

# Build re-export wrapper
REEXPORT_FLAGS=""
for lib in "${PIXI_ENV}"/lib/libusd_*.dylib; do
    REEXPORT_FLAGS="${REEXPORT_FLAGS} -Wl,-reexport_library,${lib}"
done

clang++ -dynamiclib -arch arm64 \
    -install_name @rpath/libusd_ms.dylib \
    -o "${COMPAT_DIR}/lib/libusd_ms.dylib" \
    -Wl,-rpath,"${PIXI_ENV}/lib" \
    ${REEXPORT_FLAGS}

echo "==> Created libusd_ms.dylib ($(wc -c < "${COMPAT_DIR}/lib/libusd_ms.dylib") bytes)"

# Replace Blender's USD with our wrapper (backup original first)
if [ -d "${BLENDER_LIBS}/usd" ] && [ ! -L "${BLENDER_LIBS}/usd" ]; then
    echo "==> Backing up Blender's original USD to usd_orig …"
    rm -rf "${BLENDER_LIBS}/usd_orig"
    mv "${BLENDER_LIBS}/usd" "${BLENDER_LIBS}/usd_orig"
fi
ln -sfn "${COMPAT_DIR}" "${BLENDER_LIBS}/usd"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Apply hdCycles patches for USD 26.x compatibility
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Applying hdCycles patches …"
cd "${BLENDER_DIR}"
git checkout -- CMakeLists.txt intern/cycles/hydra/ 2>/dev/null || true
git apply "${PATCHES_DIR}/blender-cycles-profile.patch"
git apply "${PATCHES_DIR}/hdcycles-usd26.patch"
git apply "${PATCHES_DIR}/hdcycles-package-textures.patch"

# ─────────────────────────────────────────────────────────────────────────────
# 8. Configure & build Cycles standalone + hdCycles Hydra delegate
# ─────────────────────────────────────────────────────────────────────────────
# Ensure cmake from pixi env is on PATH
export PATH="${PIXI_ENV}/bin:$PATH"

drop_stale_cmake_cache "${CYCLES_BUILD}"

echo "==> Configuring Cycles build …"
cmake -S "${BLENDER_DIR}" -B "${CYCLES_BUILD}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DWITH_BLENDER=OFF \
    -DWITH_CYCLES_STANDALONE=ON \
    -DWITH_CYCLES_STANDALONE_GUI=OFF \
    -DWITH_CYCLES_HYDRA_RENDER_DELEGATE=ON \
    -DWITH_CYCLES_DEVICE_METAL=ON \
    -DWITH_CYCLES_DEVICE_CUDA=OFF \
    -DWITH_CYCLES_DEVICE_HIP=OFF \
    -DWITH_CYCLES_DEVICE_ONEAPI=OFF \
    -DWITH_CYCLES_OSL=OFF \
    -DWITH_CYCLES_EMBREE=ON \
    -DWITH_USD=ON

echo "==> Building hdCycles …"
cmake --build "${CYCLES_BUILD}" -j"$(sysctl -n hw.ncpu)"

HDCYCLES="${CYCLES_BUILD}/intern/cycles/hydra/hdCycles.dylib"
if [ ! -f "${HDCYCLES}" ]; then
    echo "ERROR: hdCycles.dylib not found after build"
    exit 1
fi
echo "==> Built hdCycles.dylib ($(du -h "${HDCYCLES}" | cut -f1))"

# Metal compiles its kernels at runtime from source; the install step puts
# those sources into ${CYCLES_BUILD}/bin/source
cmake --install "${CYCLES_BUILD}" > /dev/null
CYCLES_KERNEL_SRC="${CYCLES_BUILD}/bin/source"
if [ ! -f "${CYCLES_KERNEL_SRC}/kernel/device/metal/kernel.metal" ]; then
    echo "ERROR: Cycles kernel sources not found after install"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 9. Assemble final app bundle
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Assembling app bundle …"
mkdir -p "${BUILD_DIR}"
rsync -a --delete "${USDTWEAK_APP}" "${BUILD_DIR}/"

APP="${BUILD_DIR}/usdtweak.app"
PLUGIN_DIR="${APP}/Contents/plugin/usd/hdCycles"

mkdir -p "${PLUGIN_DIR}/resources"
cp "${HDCYCLES}" "${PLUGIN_DIR}/"
# hdCycles resolves Cycles paths relative to its resource dir
rsync -a --delete "${CYCLES_KERNEL_SRC}/" "${PLUGIN_DIR}/resources/source/"

cat > "${PLUGIN_DIR}/resources/plugInfo.json" << 'PLUGINFO'
{
    "Plugins": [
        {
            "Info": {
                "Types": {
                    "HdCyclesPlugin": {
                        "bases": ["HdRendererPlugin"],
                        "displayName": "Cycles",
                        "priority": 1
                    }
                }
            },
            "LibraryPath": "hdCycles.dylib",
            "Name": "hdCycles",
            "ResourcePath": "resources",
            "Root": "..",
            "Type": "library"
        }
    ]
}
PLUGINFO

echo ""
echo "=== Build complete ==="
echo "  usdtweak: $(git -C "${SOURCE_DIR}" rev-parse --short HEAD) (${USDTWEAK_BRANCH})"
echo "  Blender:  $(git -C "${BLENDER_DIR}" rev-parse --short HEAD) (${BLENDER_BRANCH})"
echo "  App:      ${APP}"
echo ""
echo "Launch with:"
echo "  PXR_PLUGINPATH_NAME=\"${APP}/Contents/plugin/usd\" CYCLES_DEVICE=METAL open \"${APP}\""
echo ""
echo "Or use: make run"
