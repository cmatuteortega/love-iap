#!/usr/bin/env bash
# Adds love-iap to a love-android checkout. Idempotent: running it twice on
# the same tree changes nothing the second time.
#
#   android/install.sh <love-android dir> [play billing version]
#
# Three edits, each one checked, and the script fails loudly when a check does
# not hold -- a love-android bump that moved what it edits should break the
# build here, not ship an APK whose store silently does nothing.
#
# 1. Copies android/love-iap into app/src/main/cpp/lua-modules/, which
#    love-android builds (libliap.so) and whose Java (LoveIap.java) it compiles.
# 2. Adds the Play Billing library to app/build.gradle's dependencies.
# 3. Adds the liap target to the CMake targets gradle builds and packages:
#    a library that only hangs off love_android through add_dependencies is
#    not always bundled into the APK (see the issuetracker link in that file).

set -euo pipefail

LA=${1:?usage: install.sh <love-android dir> [play billing version]}
BILLING=${2:-9.1.0}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GRADLE="$LA/app/build.gradle"
MODULES="$LA/app/src/main/cpp/lua-modules"

[ -f "$GRADLE" ] || { echo "love-iap: $GRADLE not found -- is $LA a love-android checkout?" >&2; exit 1; }
[ -d "$MODULES" ] || { echo "love-iap: $MODULES not found -- this love-android has no lua-modules support" >&2; exit 1; }

# 1. The module
rm -rf "$MODULES/love-iap"
cp -R "$HERE/love-iap" "$MODULES/love-iap"
echo "love-iap: module copied to $MODULES/love-iap"

# 2. Play Billing. Any version already there (from an earlier run with a
#    different version) is replaced rather than duplicated.
# perl rather than sed: GNU and BSD sed disagree on -i and on "first match only".
perl -ni -e 'print unless /com\.android\.billingclient:billing:/' "$GRADLE"
BILLING="$BILLING" perl -0pi -e 's/^dependencies \{\n/dependencies {\n    implementation \x27com.android.billingclient:billing:$ENV{BILLING}\x27\n/m' "$GRADLE"
grep -q "com.android.billingclient:billing:$BILLING" "$GRADLE" \
    || { echo "love-iap: could not add Play Billing to $GRADLE (no top-level 'dependencies {' line?)" >&2; exit 1; }
echo "love-iap: Play Billing $BILLING added to app/build.gradle"

# 3. The CMake target
if grep -q 'targets "love_android"' "$GRADLE"; then
    grep -q '"liap"' "$GRADLE" || perl -pi -e 's/targets "love_android"/targets "love_android", "liap"/' "$GRADLE"
    grep -q 'targets "love_android", "liap"' "$GRADLE" \
        || { echo "love-iap: could not add the liap target to $GRADLE" >&2; exit 1; }
    echo "love-iap: liap added to the CMake targets"
else
    echo "love-iap: no CMake targets line in $GRADLE (ndk-build tree?) -- relying on Android.mk" >&2
fi
