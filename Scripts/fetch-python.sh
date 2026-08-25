#!/usr/bin/env bash
#
# Vendors an embedded Python runtime and yt-dlp into the app.
#
# iOS won't run the yt-dlp binary, but it will happily import yt-dlp's
# pure-Python source into an interpreter that shipped inside the app bundle.
# This script assembles that:
#
#   Vendor/Python.xcframework            the interpreter, linked and embedded
#   YTDLPHub/Resources/python-stdlib     the standard library, copied verbatim
#   YTDLPHub/Resources/python-packages   yt-dlp, certifi, and the bridge module
#
# Run it once before the first build, and again whenever you want a newer
# yt-dlp. Everything it produces is gitignored.
#
#   ./Scripts/fetch-python.sh
#   ./Scripts/fetch-python.sh --check      report what is already in place
#
# The layout of the Python-Apple-support release changes between Python
# versions. If extraction fails, check the release page for the current shape
# and set PYTHON_SUPPORT_URL to the tarball you want:
#
#   https://github.com/beeware/Python-Apple-support/releases

set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.13}"
PYTHON_SUPPORT_TAG="${PYTHON_SUPPORT_TAG:-${PYTHON_VERSION}-b11}"
PYTHON_SUPPORT_URL="${PYTHON_SUPPORT_URL:-https://github.com/beeware/Python-Apple-support/releases/download/${PYTHON_SUPPORT_TAG}/Python-${PYTHON_VERSION}-iOS-support.${PYTHON_SUPPORT_TAG##*-}.tar.gz}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="${ROOT}/Vendor"
RESOURCES="${ROOT}/YTDLPHub/Resources"
STDLIB_DEST="${RESOURCES}/python-stdlib"
PACKAGES_DEST="${RESOURCES}/python-packages"
FRAMEWORK_DEST="${VENDOR}/Python.xcframework"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m error:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- status

report_status() {
    local ok=0
    if [[ -d "${FRAMEWORK_DEST}" ]]; then
        say "Python.xcframework present"
    else
        warn "Python.xcframework missing"; ok=1
    fi
    if [[ -d "${STDLIB_DEST}" ]]; then
        say "python-stdlib present ($(du -sh "${STDLIB_DEST}" | cut -f1))"
    else
        warn "python-stdlib missing"; ok=1
    fi
    if [[ -d "${PACKAGES_DEST}/yt_dlp" ]]; then
        local version
        version="$(sed -n 's/^__version__ = .\([^"'"'"']*\).*/\1/p' \
            "${PACKAGES_DEST}/yt_dlp/version.py" 2>/dev/null | head -1)"
        say "yt-dlp ${version:-present} ($(du -sh "${PACKAGES_DEST}" | cut -f1))"
    else
        warn "yt-dlp missing"; ok=1
    fi
    [[ ${ok} -eq 0 ]] && say "Ready to build." || warn "Run this script without --check to fix."
    return ${ok}
}

if [[ "${1:-}" == "--check" ]]; then
    report_status
    exit $?
fi

# ---------------------------------------------------------------- checks

command -v curl    >/dev/null || die "curl is required."
command -v python3 >/dev/null || die "python3 is required to install yt-dlp."
python3 -m pip --version >/dev/null 2>&1 || die "python3 -m pip is required."

# ---------------------------------------------------------------- runtime

if [[ -d "${FRAMEWORK_DEST}" ]]; then
    say "Python.xcframework already vendored (delete Vendor/ to refresh)"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP}"' EXIT

    say "Downloading Python ${PYTHON_VERSION} for iOS"
    echo "    ${PYTHON_SUPPORT_URL}"
    curl --fail --location --progress-bar "${PYTHON_SUPPORT_URL}" -o "${TMP}/python.tar.gz" \
        || die "Download failed. Check https://github.com/beeware/Python-Apple-support/releases and set PYTHON_SUPPORT_URL."

    say "Extracting"
    mkdir -p "${TMP}/unpacked"
    tar -xzf "${TMP}/python.tar.gz" -C "${TMP}/unpacked"

    # The tarball's internal layout has moved between releases, so find the
    # pieces rather than assuming where they are.
    FRAMEWORK_SRC="$(find "${TMP}/unpacked" -maxdepth 3 -type d -name 'Python.xcframework' | head -1)"
    [[ -n "${FRAMEWORK_SRC}" ]] || die "No Python.xcframework inside the tarball."

    STDLIB_SRC="$(find "${TMP}/unpacked" -maxdepth 5 -type d -name 'python-stdlib' | head -1)"
    if [[ -z "${STDLIB_SRC}" ]]; then
        # Older layouts ship the stdlib as lib/python3.x inside the device slice.
        STDLIB_SRC="$(find "${FRAMEWORK_SRC}" -maxdepth 4 -type d -name "python${PYTHON_VERSION}" \
            -path '*ios-arm64*' ! -path '*simulator*' | head -1)"
    fi
    [[ -n "${STDLIB_SRC}" ]] || die "Could not locate the standard library in the tarball."

    mkdir -p "${VENDOR}"
    rm -rf "${FRAMEWORK_DEST}"
    cp -R "${FRAMEWORK_SRC}" "${FRAMEWORK_DEST}"

    mkdir -p "${RESOURCES}"
    rm -rf "${STDLIB_DEST}"
    cp -R "${STDLIB_SRC}" "${STDLIB_DEST}"

    say "Trimming the standard library"
    # None of this can run on iOS, and it is a third of the download.
    for unwanted in test tests idlelib tkinter turtledemo lib2to3 ensurepip pydoc_data; do
        rm -rf "${STDLIB_DEST:?}/${unwanted}"
    done
    find "${STDLIB_DEST}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "${STDLIB_DEST}" -name '*.pyc' -delete 2>/dev/null || true

    rm -rf "${TMP}"
    trap - EXIT
fi

# ---------------------------------------------------------------- packages

say "Installing yt-dlp and certifi"
rm -rf "${PACKAGES_DEST}"
mkdir -p "${PACKAGES_DEST}"

# --no-deps keeps optional native extras out; yt-dlp's core needs none of them.
# certifi is not optional here: iOS has no system CA store for OpenSSL to find,
# so without a bundled cert file every HTTPS request fails verification.
python3 -m pip install \
    --quiet \
    --disable-pip-version-check \
    --no-deps \
    --target "${PACKAGES_DEST}" \
    --upgrade \
    yt-dlp certifi \
    || die "pip install failed."

say "Removing self-update support"
# yt-dlp can replace its own executable. That is exactly the "download and run
# new code" behaviour iOS forbids, and it cannot work from a read-only bundle
# anyway, so the module is replaced with a stub that refuses politely.
UPDATE_MODULE="${PACKAGES_DEST}/yt_dlp/update.py"
if [[ -f "${UPDATE_MODULE}" ]]; then
    cat > "${UPDATE_MODULE}" <<'STUB'
"""Self-update, disabled.

The original module downloads and executes a new yt-dlp build. The app bundle
is read-only and iOS does not permit running downloaded code, so every entry
point here is inert. Update yt-dlp by re-running Scripts/fetch-python.sh and
rebuilding the app.
"""

UPDATE_SOURCES = {}
REPOSITORY = None
_INVERSE_UPDATE_SOURCES = {}


class UpdateInfo:
    def __init__(self, *args, **kwargs):
        pass


class Updater:
    def __init__(self, ydl=None, target=None, **kwargs):
        self.ydl = ydl

    @property
    def current_version(self):
        from yt_dlp.version import __version__
        return __version__

    def query_update(self, *args, **kwargs):
        return None

    def update(self, *args, **kwargs):
        return False

    def run(self, *args, **kwargs):
        return False


def run_update(ydl, *args, **kwargs):
    return False


def update_self(*args, **kwargs):
    return False


def is_non_updateable(*args, **kwargs):
    return "This build of yt-dlp is bundled inside an app and cannot update itself."


def detect_variant(*args, **kwargs):
    return "embedded"
STUB
else
    warn "yt_dlp/update.py not found; skipping the self-update stub."
fi

say "Adding the bridge module"
cp "${ROOT}/Scripts/ytdlp_bridge.py" "${PACKAGES_DEST}/ytdlp_bridge.py"

say "Trimming packages"
find "${PACKAGES_DEST}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "${PACKAGES_DEST}" -name '*.pyc' -delete 2>/dev/null || true
rm -rf "${PACKAGES_DEST}"/*.dist-info/RECORD
rm -rf "${PACKAGES_DEST}/bin"

echo
report_status
echo
say "Now open YTDLPHub.xcodeproj and build."
