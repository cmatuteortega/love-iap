# love-iap's native bridge, built by love-android's lua-modules mechanism
# (app/src/main/cpp/CMakeLists.txt adds every folder under lua-modules/).
#
# A plain shared library, libliap.so, loaded by iap.lua with ffi.load("liap").
# It deliberately links nothing of LÖVE's or LuaJIT's: SDL is reached at run
# time by dlsym (see liap.cpp), so this builds the same against any engine.

add_library(liap SHARED liap.cpp)
target_link_libraries(liap PRIVATE dl)
