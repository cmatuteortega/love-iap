# The ndk-build twin of CMakeLists.txt. It is here for two reasons:
#
# - love-android's app/build.gradle only reads java.txt (and so only compiles
#   LoveIap.java) for a lua-modules folder that has an Android.mk -- it looks
#   for "CMakeLists.mk", not "CMakeLists.txt". The CMake build still prefers
#   CMakeLists.txt when both exist, so this file is never converted there.
# - Older, ndk-build based love-android trees build from it directly.

LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := liap
LOCAL_SRC_FILES := liap.cpp
LOCAL_LDLIBS := -ldl
include $(BUILD_SHARED_LIBRARY)
